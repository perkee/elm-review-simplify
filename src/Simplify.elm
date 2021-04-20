module Simplify exposing (rule)

{-|

@docs rule

-}

import Dict exposing (Dict)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern)
import Elm.Syntax.Range exposing (Range)
import Review.Fix as Fix exposing (Fix)
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (Error, Rule)
import Simplify.Normalize as Normalize


{-| Reports when an operation can be simplified.

    config =
        [ Simplify.rule
        ]


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-review-simplify/example --rules Simplify
```


## Simplifications

Below is the list of all kinds of simplifications this rule applies.


### Booleans

    x || True
    --> True

    x || False
    --> x

    x && True
    --> x

    x && False
    --> False

    not True
    --> False

    x == True
    --> x

    x /= False
    --> x

    anything == anything
    --> True

    anything /= anything
    --> False


### If expressions

    if True then x else y
    --> x

    if False then x else y
    --> y

    if condition then x else x
    --> x

    if condition then True else False
    --> condition

    if condition then False else True
    --> not condition


### Basics functions

    identity x
    --> x

    always x y
    --> x


### Operators

    (++) a b
    --> a ++ b


### Strings

    "a" ++ ""
    --> "a"

    String.isEmpty ""
    --> True

    String.isEmpty "a"
    --> False

    String.concat []
    --> ""

    String.join str []
    --> ""

    String.join "" list
    --> String.concat list

    String.length "abc"
    --> 3

    String.repeat n ""
    --> ""

    String.repeat 0 str
    --> ""

    String.repeat 1 str
    --> str

    String.words ""
    --> []

    String.lines ""
    --> []


### Lists

    a :: []
    --> [ a ]

    a :: [ b ]
    --> [ a, b ]

    [a] ++ list
    --> a :: list

    [] ++ list
    --> list

    [ a, b ] ++ [ c ]
    --> [ a, b, c ]

    [ a, b ] ++ [ c ]
    --> [ a, b, c ]

    List.concat []
    --> []

    List.concat [ [ a, b ], [ c ] ]
    --> [ a, b, c ]

    List.concat [ a, [ 1 ], [ 2 ] ]
    --> List.concat [ a, [ 1, 2 ] ]

    List.concatMap identity x
    --> List.concat list

    List.concatMap identity
    --> List.concat

    List.concatMap (\a -> a) list
    --> List.concat list

    List.concatMap fn [ x ]
    --> fn x

    List.concatMap (always []) list
    --> []

    List.map fn [] -- same for List.filter, List.filterMap, ...
    --> []

    List.map identity list
    --> list

    List.map identity
    --> identity

    List.filter (always True) list
    --> list

    List.filter (\a -> True) list
    --> list

    List.filter (always False) list
    --> []

    List.filter (always True)
    --> identity

    List.filter (always False)
    --> always []

    List.filterMap Just list
    --> list

    List.filterMap (\a -> Just a) list
    --> list

    List.filterMap Just
    --> identity

    List.filterMap (always Nothing) list
    --> []

    List.filterMap (always Nothing)
    --> (always [])

    List.isEmpty []
    --> True

    List.isEmpty [ a ]
    --> False

    List.isEmpty (x :: xs)
    --> False

    List.all fn []
    --> True

    List.all (always True) list
    --> True

    List.any fn []
    --> True

    List.any (always False) list
    --> True

    List.range 6 3
    --> []

    List.length [ a ]
    --> 1

    List.repeat n []
    --> []

    List.repeat 0 str
    --> []

    List.repeat 1 str
    --> str

-}
rule : Rule
rule =
    Rule.newModuleRuleSchemaUsingContextCreator "Simplify" initialContext
        |> Rule.withDeclarationEnterVisitor declarationVisitor
        |> Rule.withExpressionEnterVisitor expressionVisitor
        |> Rule.fromModuleRuleSchema


type alias Context =
    { lookupTable : ModuleNameLookupTable
    , rangesToIgnore : List Range
    }


initialContext : Rule.ContextCreator () Context
initialContext =
    Rule.initContextCreator
        (\lookupTable () ->
            { lookupTable = lookupTable
            , rangesToIgnore = []
            }
        )
        |> Rule.withModuleNameLookupTable


errorForAddingEmptyStrings : Range -> Range -> Error {}
errorForAddingEmptyStrings range rangeToRemove =
    Rule.errorWithFix
        { message = "Unnecessary concatenation with an empty string"
        , details = [ "You should remove the concatenation with the empty string." ]
        }
        range
        [ Fix.removeRange rangeToRemove ]


errorForAddingEmptyLists : Range -> Range -> Error {}
errorForAddingEmptyLists range rangeToRemove =
    Rule.errorWithFix
        { message = "Concatenating with a single list doesn't have any effect"
        , details = [ "You should remove the concatenation with the empty list." ]
        }
        range
        [ Fix.removeRange rangeToRemove ]



-- DECLARATION VISITOR


declarationVisitor : Node a -> Context -> ( List nothing, Context )
declarationVisitor _ context =
    ( [], { context | rangesToIgnore = [] } )



-- EXPRESSION VISITOR


expressionVisitor : Node Expression -> Context -> ( List (Error {}), Context )
expressionVisitor node context =
    if List.member (Node.range node) context.rangesToIgnore then
        ( [], context )

    else
        let
            ( errors, rangesToIgnore ) =
                expressionVisitorHelp node context
        in
        ( errors, { context | rangesToIgnore = rangesToIgnore ++ context.rangesToIgnore } )


expressionVisitorHelp : Node Expression -> Context -> ( List (Error {}), List Range )
expressionVisitorHelp node { lookupTable } =
    case Node.value node of
        --------------------
        -- FUNCTION CALLS --
        --------------------
        Expression.Application ((Node fnRange (Expression.FunctionOrValue _ fnName)) :: firstArg :: restOfArguments) ->
            case
                ModuleNameLookupTable.moduleNameAt lookupTable fnRange
                    |> Maybe.andThen (\moduleName -> Dict.get ( moduleName, fnName ) functionCallChecks)
            of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , fnRange = fnRange
                        , firstArg = firstArg
                        , secondArg = List.head restOfArguments
                        , usingRightPizza = False
                        }
                    , []
                    )

                _ ->
                    ( [], [] )

        -------------------
        -- IF EXPRESSION --
        -------------------
        Expression.IfBlock cond trueBranch falseBranch ->
            case getBoolean lookupTable cond of
                Just True ->
                    ( [ Rule.errorWithFix
                            { message = "The condition will always evaluate to True"
                            , details = [ "The expression can be replaced by what is inside the 'then' branch." ]
                            }
                            (targetIf node)
                            [ Fix.removeRange
                                { start = (Node.range node).start
                                , end = (Node.range trueBranch).start
                                }
                            , Fix.removeRange
                                { start = (Node.range trueBranch).end
                                , end = (Node.range node).end
                                }
                            ]
                      ]
                    , []
                    )

                Just False ->
                    ( [ Rule.errorWithFix
                            { message = "The condition will always evaluate to False"
                            , details = [ "The expression can be replaced by what is inside the 'else' branch." ]
                            }
                            (targetIf node)
                            [ Fix.removeRange
                                { start = (Node.range node).start
                                , end = (Node.range falseBranch).start
                                }
                            ]
                      ]
                    , []
                    )

                Nothing ->
                    case ( getBoolean lookupTable trueBranch, getBoolean lookupTable falseBranch ) of
                        ( Just True, Just False ) ->
                            ( [ Rule.errorWithFix
                                    { message = "The if expression's value is the same as the condition"
                                    , details = [ "The expression can be replaced by the condition." ]
                                    }
                                    (targetIf node)
                                    [ Fix.removeRange
                                        { start = (Node.range node).start
                                        , end = (Node.range cond).start
                                        }
                                    , Fix.removeRange
                                        { start = (Node.range cond).end
                                        , end = (Node.range node).end
                                        }
                                    ]
                              ]
                            , []
                            )

                        ( Just False, Just True ) ->
                            ( [ Rule.errorWithFix
                                    { message = "The if expression's value is the inverse of the condition"
                                    , details = [ "The expression can be replaced by the condition wrapped by `not`." ]
                                    }
                                    (targetIf node)
                                    [ Fix.replaceRangeBy
                                        { start = (Node.range node).start
                                        , end = (Node.range cond).start
                                        }
                                        "not ("
                                    , Fix.replaceRangeBy
                                        { start = (Node.range cond).end
                                        , end = (Node.range node).end
                                        }
                                        ")"
                                    ]
                              ]
                            , []
                            )

                        _ ->
                            if Normalize.areTheSame lookupTable trueBranch falseBranch then
                                ( [ Rule.errorWithFix
                                        { message = "The values in both branches is the same."
                                        , details = [ "The expression can be replaced by the contents of either branch." ]
                                        }
                                        (targetIf node)
                                        [ Fix.removeRange
                                            { start = (Node.range node).start
                                            , end = (Node.range trueBranch).start
                                            }
                                        , Fix.removeRange
                                            { start = (Node.range trueBranch).end
                                            , end = (Node.range node).end
                                            }
                                        ]
                                  ]
                                , []
                                )

                            else
                                ( [], [] )

        -------------------------------------
        --  FULLY APPLIED PREFIX OPERATOR  --
        -------------------------------------
        Expression.Application [ Node.Node operatorRange (Expression.PrefixOperator operator), left, right ] ->
            ( [ Rule.errorWithFix
                    { message = "Use the infix form (a + b) over the prefix form ((+) a b)"
                    , details = [ "The prefix form is generally more unfamiliar to Elm developers, and therefore it is nicer when the infix form is used." ]
                    }
                    operatorRange
                    [ Fix.removeRange { start = operatorRange.start, end = (Node.range left).start }
                    , Fix.insertAt (Node.range right).start (operator ++ " ")
                    ]
              ]
            , []
            )

        ----------
        -- (<|) --
        ----------
        Expression.OperatorApplication "<|" _ (Node fnRange (Expression.FunctionOrValue _ fnName)) firstArg ->
            case
                ModuleNameLookupTable.moduleNameAt lookupTable fnRange
                    |> Maybe.andThen (\moduleName -> Dict.get ( moduleName, fnName ) functionCallChecks)
            of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , fnRange = fnRange
                        , firstArg = firstArg
                        , secondArg = Nothing
                        , usingRightPizza = False
                        }
                    , []
                    )

                _ ->
                    ( [], [] )

        Expression.OperatorApplication "<|" _ (Node applicationRange (Expression.Application ((Node fnRange (Expression.FunctionOrValue _ fnName)) :: firstArg :: []))) secondArgument ->
            case
                ModuleNameLookupTable.moduleNameAt lookupTable fnRange
                    |> Maybe.andThen (\moduleName -> Dict.get ( moduleName, fnName ) functionCallChecks)
            of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , fnRange = fnRange
                        , firstArg = firstArg
                        , secondArg = Just secondArgument
                        , usingRightPizza = False
                        }
                    , [ applicationRange ]
                    )

                _ ->
                    ( [], [] )

        ----------
        -- (|>) --
        ----------
        Expression.OperatorApplication "|>" _ firstArg (Node fnRange (Expression.FunctionOrValue _ fnName)) ->
            case
                ModuleNameLookupTable.moduleNameAt lookupTable fnRange
                    |> Maybe.andThen (\moduleName -> Dict.get ( moduleName, fnName ) functionCallChecks)
            of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , fnRange = fnRange
                        , firstArg = firstArg
                        , secondArg = Nothing
                        , usingRightPizza = True
                        }
                    , []
                    )

                _ ->
                    ( [], [] )

        Expression.OperatorApplication "|>" _ secondArgument (Node applicationRange (Expression.Application ((Node fnRange (Expression.FunctionOrValue _ fnName)) :: firstArg :: []))) ->
            case
                ModuleNameLookupTable.moduleNameAt lookupTable fnRange
                    |> Maybe.andThen (\moduleName -> Dict.get ( moduleName, fnName ) functionCallChecks)
            of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , fnRange = fnRange
                        , firstArg = firstArg
                        , secondArg = Just secondArgument
                        , usingRightPizza = True
                        }
                    , [ applicationRange ]
                    )

                _ ->
                    ( [], [] )

        Expression.OperatorApplication operator _ left right ->
            case Dict.get operator operatorChecks of
                Just checkFn ->
                    ( checkFn
                        { lookupTable = lookupTable
                        , parentRange = Node.range node
                        , left = left
                        , leftRange = Node.range left
                        , right = right
                        , rightRange = Node.range right
                        }
                    , []
                    )

                Nothing ->
                    ( [], [] )

        _ ->
            ( [], [] )


type alias CheckInfo =
    { lookupTable : ModuleNameLookupTable
    , parentRange : Range
    , fnRange : Range
    , firstArg : Node Expression
    , secondArg : Maybe (Node Expression)
    , usingRightPizza : Bool
    }


functionCallChecks : Dict ( ModuleName, String ) (CheckInfo -> List (Error {}))
functionCallChecks =
    Dict.fromList
        [ reportEmptyListSecondArgument ( ( [ "Basics" ], "identity" ), identityChecks )
        , reportEmptyListSecondArgument ( ( [ "Basics" ], "always" ), alwaysChecks )
        , reportEmptyListSecondArgument ( ( [ "Basics" ], "not" ), notChecks )
        , reportEmptyListSecondArgument ( ( [ "List" ], "map" ), mapChecks )
        , reportEmptyListSecondArgument ( ( [ "List" ], "filter" ), filterChecks )
        , reportEmptyListSecondArgument ( ( [ "List" ], "filterMap" ), filterMapChecks )
        , reportEmptyListFirstArgument ( ( [ "List" ], "concat" ), concatChecks )
        , reportEmptyListSecondArgument ( ( [ "List" ], "concatMap" ), concatMapChecks )
        , ( ( [ "String" ], "isEmpty" ), stringIsEmptyChecks )
        , ( ( [ "String" ], "concat" ), stringConcatChecks )
        , ( ( [ "String" ], "join" ), stringJoinChecks )
        , ( ( [ "String" ], "length" ), stringLengthChecks )
        , ( ( [ "String" ], "repeat" ), stringRepeatChecks )
        , ( ( [ "String" ], "words" ), stringWordsChecks )
        , ( ( [ "String" ], "lines" ), stringLinesChecks )
        , ( ( [ "List" ], "isEmpty" ), listIsEmptyChecks )
        , ( ( [ "List" ], "all" ), allChecks )
        , ( ( [ "List" ], "any" ), anyChecks )
        , ( ( [ "List" ], "range" ), rangeChecks )
        , ( ( [ "List" ], "length" ), listLengthChecks )
        , ( ( [ "List" ], "repeat" ), listRepeatChecks )
        ]


type alias OperatorCheckInfo =
    { lookupTable : ModuleNameLookupTable
    , parentRange : Range
    , left : Node Expression
    , leftRange : Range
    , right : Node Expression
    , rightRange : Range
    }


operatorChecks : Dict String (OperatorCheckInfo -> List (Error {}))
operatorChecks =
    Dict.fromList
        [ ( "++", plusplusChecks )
        , ( "::", consChecks )
        , ( "||", orChecks )
        , ( "&&", andChecks )
        , ( "==", equalityChecks True )
        , ( "/=", equalityChecks False )
        ]


plusplusChecks : OperatorCheckInfo -> List (Error {})
plusplusChecks { parentRange, leftRange, rightRange, left, right } =
    case ( Node.value left, Node.value right ) of
        ( Expression.Literal "", _ ) ->
            [ errorForAddingEmptyStrings leftRange
                { start = leftRange.start
                , end = rightRange.start
                }
            ]

        ( _, Expression.Literal "" ) ->
            [ errorForAddingEmptyStrings rightRange
                { start = leftRange.end
                , end = rightRange.end
                }
            ]

        ( Expression.ListExpr [], _ ) ->
            [ errorForAddingEmptyLists leftRange
                { start = leftRange.start
                , end = rightRange.start
                }
            ]

        ( _, Expression.ListExpr [] ) ->
            [ errorForAddingEmptyLists rightRange
                { start = leftRange.end
                , end = rightRange.end
                }
            ]

        ( Expression.ListExpr _, Expression.ListExpr _ ) ->
            [ Rule.errorWithFix
                { message = "Expression could be simplified to be a single List"
                , details = [ "Try moving all the elements into a single list." ]
                }
                parentRange
                [ Fix.replaceRangeBy
                    { start = { row = leftRange.end.row, column = leftRange.end.column - 1 }
                    , end = { row = rightRange.start.row, column = rightRange.start.column + 1 }
                    }
                    ","
                ]
            ]

        ( Expression.ListExpr [ _ ], _ ) ->
            [ Rule.errorWithFix
                { message = "Should use (::) instead of (++)"
                , details = [ "Concatenating a list with a single value is the same as using (::) on the list with the value." ]
                }
                parentRange
                [ Fix.replaceRangeBy
                    { start = leftRange.start
                    , end = { row = leftRange.start.row, column = leftRange.start.column + 1 }
                    }
                    "("
                , Fix.replaceRangeBy
                    { start = { row = leftRange.end.row, column = leftRange.end.column - 1 }
                    , end = rightRange.start
                    }
                    ") :: "
                ]
            ]

        _ ->
            []


consChecks : OperatorCheckInfo -> List (Error {})
consChecks { right, leftRange, rightRange } =
    case Node.value right of
        Expression.ListExpr [] ->
            [ Rule.errorWithFix
                { message = "Element added to the beginning of the list could be included in the list"
                , details = [ "Try moving the element inside the list it is being added to." ]
                }
                leftRange
                [ Fix.insertAt leftRange.start "[ "
                , Fix.replaceRangeBy
                    { start = leftRange.end
                    , end = rightRange.end
                    }
                    " ]"
                ]
            ]

        Expression.ListExpr _ ->
            [ Rule.errorWithFix
                { message = "Element added to the beginning of the list could be included in the list"
                , details = [ "Try moving the element inside the list it is being added to." ]
                }
                leftRange
                [ Fix.insertAt leftRange.start "[ "
                , Fix.replaceRangeBy
                    { start = leftRange.end
                    , end = { row = rightRange.start.row, column = rightRange.start.column + 1 }
                    }
                    ","
                ]
            ]

        _ ->
            []



-- BOOLEAN


notChecks : CheckInfo -> List (Error {})
notChecks { lookupTable, parentRange, firstArg } =
    case getBoolean lookupTable firstArg of
        Just bool ->
            [ Rule.errorWithFix
                { message = "Expression is equal to " ++ boolToString (not bool)
                , details = [ "You can replace the call to `not` by the boolean value directly." ]
                }
                parentRange
                [ Fix.replaceRangeBy parentRange (boolToString (not bool)) ]
            ]

        Nothing ->
            []


orChecks : OperatorCheckInfo -> List (Error {})
orChecks operatorCheckInfo =
    List.concat
        [ or_isLeftSimplifiableError operatorCheckInfo
        , or_isRightSimplifiableError operatorCheckInfo
        ]


or_isLeftSimplifiableError : OperatorCheckInfo -> List (Error {})
or_isLeftSimplifiableError { lookupTable, parentRange, left, leftRange, rightRange } =
    case getBoolean lookupTable left of
        Just True ->
            [ Rule.errorWithFix
                { message = "Condition is always True"
                , details = alwaysSameDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.end
                    , end = rightRange.end
                    }
                ]
            ]

        Just False ->
            [ Rule.errorWithFix
                { message = unnecessaryMessage
                , details = unnecessaryDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.start
                    , end = rightRange.start
                    }
                ]
            ]

        Nothing ->
            []


or_isRightSimplifiableError : OperatorCheckInfo -> List (Error {})
or_isRightSimplifiableError { lookupTable, parentRange, right, leftRange, rightRange } =
    case getBoolean lookupTable right of
        Just True ->
            [ Rule.errorWithFix
                { message = unnecessaryMessage
                , details = unnecessaryDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.start
                    , end = rightRange.start
                    }
                ]
            ]

        Just False ->
            [ Rule.errorWithFix
                { message = unnecessaryMessage
                , details = unnecessaryDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.end
                    , end = rightRange.end
                    }
                ]
            ]

        Nothing ->
            []


andChecks : OperatorCheckInfo -> List (Error {})
andChecks operatorCheckInfo =
    List.concat
        [ and_isLeftSimplifiableError operatorCheckInfo
        , and_isRightSimplifiableError operatorCheckInfo
        ]


and_isLeftSimplifiableError : OperatorCheckInfo -> List (Rule.Error {})
and_isLeftSimplifiableError { lookupTable, parentRange, left, leftRange, rightRange } =
    case getBoolean lookupTable left of
        Just True ->
            [ Rule.errorWithFix
                { message = unnecessaryMessage
                , details = unnecessaryDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.start
                    , end = rightRange.start
                    }
                ]
            ]

        Just False ->
            [ Rule.errorWithFix
                { message = "Condition is always False"
                , details = alwaysSameDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.end
                    , end = rightRange.end
                    }
                ]
            ]

        Nothing ->
            []


and_isRightSimplifiableError : OperatorCheckInfo -> List (Rule.Error {})
and_isRightSimplifiableError { lookupTable, parentRange, leftRange, right, rightRange } =
    case getBoolean lookupTable right of
        Just True ->
            [ Rule.errorWithFix
                { message = unnecessaryMessage
                , details = unnecessaryDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.end
                    , end = rightRange.end
                    }
                ]
            ]

        Just False ->
            [ Rule.errorWithFix
                { message = "Condition is always False"
                , details = alwaysSameDetails
                }
                parentRange
                [ Fix.removeRange
                    { start = leftRange.start
                    , end = rightRange.start
                    }
                ]
            ]

        Nothing ->
            []



-- EQUALITY


equalityChecks : Bool -> OperatorCheckInfo -> List (Error {})
equalityChecks isEqual { lookupTable, parentRange, left, right, leftRange, rightRange } =
    if getBoolean lookupTable right == Just isEqual then
        [ Rule.errorWithFix
            { message = "Unnecessary comparison with boolean"
            , details = [ "The result of the expression will be the same with or without the comparison." ]
            }
            parentRange
            [ Fix.removeRange { start = leftRange.end, end = rightRange.end } ]
        ]

    else if getBoolean lookupTable left == Just isEqual then
        [ Rule.errorWithFix
            { message = "Unnecessary comparison with boolean"
            , details = [ "The result of the expression will be the same with or without the comparison." ]
            }
            parentRange
            [ Fix.removeRange { start = leftRange.start, end = rightRange.start } ]
        ]

    else if Normalize.areTheSame lookupTable left right then
        [ Rule.errorWithFix
            { message = "Condition is always " ++ boolToString isEqual
            , details = sameThingOnBothSidesDetails isEqual
            }
            parentRange
            [ Fix.replaceRangeBy parentRange (boolToString isEqual)
            ]
        ]

    else
        []


alwaysSameDetails : List String
alwaysSameDetails =
    [ "This condition will always result in the same value. You may have hardcoded a value or mistyped a condition."
    ]


unnecessaryMessage : String
unnecessaryMessage =
    "Part of the expression is unnecessary"


unnecessaryDetails : List String
unnecessaryDetails =
    [ "A part of this condition is unnecessary. You can remove it and it would not impact the behavior of the program."
    ]


sameThingOnBothSidesDetails : Bool -> List String
sameThingOnBothSidesDetails computedResult =
    let
        computedResultString : String
        computedResultString =
            if computedResult then
                "True"

            else
                "False"
    in
    [ "The value on the left and on the right are the same. Therefore we can determine that the expression will always be " ++ computedResultString ++ "."
    ]



-- IF EXPRESSIONS


targetIf : Node a -> Range
targetIf node =
    let
        { start } =
            Node.range node
    in
    { start = start
    , end = { start | column = start.column + 2 }
    }



-- BASICS


identityChecks : CheckInfo -> List (Error {})
identityChecks { parentRange, fnRange, firstArg, usingRightPizza } =
    [ Rule.errorWithFix
        { message = "`identity` should be removed"
        , details = [ "`identity` can be a useful function to be passed as arguments to other functions, but calling it manually with an argument is the same thing as writing the argument on its own." ]
        }
        fnRange
        [ if usingRightPizza then
            Fix.removeRange { start = (Node.range firstArg).end, end = parentRange.end }

          else
            Fix.removeRange { start = fnRange.start, end = (Node.range firstArg).start }
        ]
    ]


alwaysChecks : CheckInfo -> List (Error {})
alwaysChecks { fnRange, firstArg, secondArg, usingRightPizza } =
    case secondArg of
        Just (Node secondArgRange _) ->
            [ Rule.errorWithFix
                { message = "Expression can be replaced by the first argument to `always`"
                , details = [ "REPLACEME" ]
                }
                fnRange
                (if usingRightPizza then
                    [ Fix.removeRange { start = secondArgRange.start, end = (Node.range firstArg).start }
                    ]

                 else
                    [ Fix.removeRange { start = fnRange.start, end = (Node.range firstArg).start }
                    , Fix.removeRange { start = (Node.range firstArg).end, end = secondArgRange.end }
                    ]
                )
            ]

        Nothing ->
            []


reportEmptyListSecondArgument : ( ( ModuleName, String ), CheckInfo -> List (Error {}) ) -> ( ( ModuleName, String ), CheckInfo -> List (Error {}) )
reportEmptyListSecondArgument ( ( moduleName, name ), function ) =
    ( ( moduleName, name )
    , \checkInfo ->
        case checkInfo.secondArg of
            Just (Node _ (Expression.ListExpr [])) ->
                [ Rule.errorWithFix
                    { message = "Using " ++ String.join "." moduleName ++ "." ++ name ++ " on an empty list will result in a empty list"
                    , details = [ "You can replace this call by an empty list" ]
                    }
                    checkInfo.fnRange
                    [ Fix.replaceRangeBy checkInfo.parentRange "[]" ]
                ]

            _ ->
                function checkInfo
    )


reportEmptyListFirstArgument : ( ( ModuleName, String ), CheckInfo -> List (Error {}) ) -> ( ( ModuleName, String ), CheckInfo -> List (Error {}) )
reportEmptyListFirstArgument ( ( moduleName, name ), function ) =
    ( ( moduleName, name )
    , \checkInfo ->
        case checkInfo.firstArg of
            Node _ (Expression.ListExpr []) ->
                [ Rule.errorWithFix
                    { message = "Using " ++ String.join "." moduleName ++ "." ++ name ++ " on an empty list will result in a empty list"
                    , details = [ "You can replace this call by an empty list" ]
                    }
                    checkInfo.fnRange
                    [ Fix.replaceRangeBy checkInfo.parentRange "[]" ]
                ]

            _ ->
                function checkInfo
    )



-- STRING


stringIsEmptyChecks : CheckInfo -> List (Error {})
stringIsEmptyChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.Literal str ->
            let
                replacementValue : String
                replacementValue =
                    boolToString (str == "")
            in
            [ Rule.errorWithFix
                { message = "The call to String.isEmpty will result in " ++ replacementValue
                , details = [ "You can replace this call by " ++ replacementValue ++ "." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange replacementValue ]
            ]

        _ ->
            []


stringConcatChecks : CheckInfo -> List (Error {})
stringConcatChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.ListExpr [] ->
            [ Rule.errorWithFix
                { message = "Using String.concat on an empty list will result in a empty string"
                , details = [ "You can replace this call by an empty string" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "\"\"" ]
            ]

        _ ->
            []


stringWordsChecks : CheckInfo -> List (Error {})
stringWordsChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.Literal "" ->
            [ Rule.errorWithFix
                { message = "Using String.words on an empty string will result in a empty list"
                , details = [ "You can replace this call by an empty list" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "[]" ]
            ]

        _ ->
            []


stringLinesChecks : CheckInfo -> List (Error {})
stringLinesChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.Literal "" ->
            [ Rule.errorWithFix
                { message = "Using String.lines on an empty string will result in a empty list"
                , details = [ "You can replace this call by an empty list" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "[]" ]
            ]

        _ ->
            []


stringJoinChecks : CheckInfo -> List (Error {})
stringJoinChecks { parentRange, fnRange, firstArg, secondArg } =
    case secondArg of
        Just (Node _ (Expression.ListExpr [])) ->
            [ Rule.errorWithFix
                { message = "Using String.join on an empty list will result in a empty string"
                , details = [ "You can replace this call by an empty string" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "\"\"" ]
            ]

        _ ->
            case Node.value firstArg of
                Expression.Literal "" ->
                    [ Rule.errorWithFix
                        { message = "Use String.concat instead"
                        , details = [ "Using String.join with an empty separator is the same as using String.concat." ]
                        }
                        fnRange
                        [ Fix.replaceRangeBy { start = fnRange.start, end = (Node.range firstArg).end } "String.concat" ]
                    ]

                _ ->
                    []


stringLengthChecks : CheckInfo -> List (Error {})
stringLengthChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.Literal str ->
            [ Rule.errorWithFix
                { message = "The length of the string is " ++ String.fromInt (String.length str)
                , details = [ "The length of the string can be determined by looking at the code." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange (String.fromInt (String.length str)) ]
            ]

        _ ->
            []


stringRepeatChecks : CheckInfo -> List (Error {})
stringRepeatChecks { parentRange, fnRange, firstArg, secondArg } =
    case secondArg of
        Just (Node _ (Expression.Literal "")) ->
            [ Rule.errorWithFix
                { message = "Using String.repeat with an empty string will result in a empty string"
                , details = [ "You can replace this call by an empty string" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "\"\"" ]
            ]

        _ ->
            case getIntValue firstArg of
                Just intValue ->
                    if intValue == 1 then
                        [ Rule.errorWithFix
                            { message = "String.repeat 1 won't do anything"
                            , details = [ "Using String.repeat with 1 will result in the second argument." ]
                            }
                            fnRange
                            [ Fix.removeRange { start = fnRange.start, end = (Node.range firstArg).end } ]
                        ]

                    else if intValue < 1 then
                        [ Rule.errorWithFix
                            { message = "String.repeat will result in an empty string"
                            , details = [ "Using String.repeat with a number less than 1 will result in an empty string. You can replace this call by an empty string." ]
                            }
                            fnRange
                            [ Fix.replaceRangeBy parentRange "\"\"" ]
                        ]

                    else
                        []

                _ ->
                    []



-- LIST FUNCTIONS


concatChecks : CheckInfo -> List (Error {})
concatChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.ListExpr list ->
            case list of
                [ Node elementRange _ ] ->
                    [ Rule.errorWithFix
                        { message = "Unnecessary use of List.concat on a list with 1 element"
                        , details = [ "The value of the operation will be the element itself. You should replace this expression by that." ]
                        }
                        parentRange
                        [ Fix.removeRange { start = parentRange.start, end = elementRange.start }
                        , Fix.removeRange { start = elementRange.end, end = parentRange.end }
                        ]
                    ]

                (firstListElement :: restOfListElements) as args ->
                    if List.all isListLiteral list then
                        [ Rule.errorWithFix
                            { message = "Expression could be simplified to be a single List"
                            , details = [ "Try moving all the elements into a single list." ]
                            }
                            parentRange
                            (Fix.removeRange fnRange
                                :: List.concatMap removeBoundariesFix args
                            )
                        ]

                    else
                        case findConsecutiveListLiterals firstListElement restOfListElements of
                            [] ->
                                []

                            fixes ->
                                [ Rule.errorWithFix
                                    { message = "Consecutive literal lists should be merged"
                                    , details = [ "Try moving all the elements from consecutive list literals so that they form a single list." ]
                                    }
                                    fnRange
                                    fixes
                                ]

                _ ->
                    []

        _ ->
            []


findConsecutiveListLiterals : Node Expression -> List (Node Expression) -> List Fix
findConsecutiveListLiterals firstListElement restOfListElements =
    case ( firstListElement, restOfListElements ) of
        ( Node firstRange (Expression.ListExpr _), ((Node secondRange (Expression.ListExpr _)) as second) :: rest ) ->
            Fix.replaceRangeBy
                { start = { row = firstRange.end.row, column = firstRange.end.column - 1 }
                , end = { row = secondRange.start.row, column = secondRange.start.column + 1 }
                }
                ", "
                :: findConsecutiveListLiterals second rest

        ( _, x :: xs ) ->
            findConsecutiveListLiterals x xs

        _ ->
            []


concatMapChecks : CheckInfo -> List (Error {})
concatMapChecks { lookupTable, parentRange, fnRange, firstArg, secondArg, usingRightPizza } =
    if isIdentity lookupTable firstArg then
        [ Rule.errorWithFix
            { message = "Using List.concatMap with an identity function is the same as using List.concat"
            , details = [ "You can replace this call by List.concat" ]
            }
            fnRange
            [ Fix.replaceRangeBy { start = fnRange.start, end = (Node.range firstArg).end } "List.concat" ]
        ]

    else if isAlwaysEmptyList lookupTable firstArg then
        [ Rule.errorWithFix
            { message = "List.concatMap will result in on an empty list"
            , details = [ "You can replace this call by an empty list" ]
            }
            fnRange
            (replaceByEmptyListFix parentRange secondArg)
        ]

    else
        case secondArg of
            Just (Node listRange (Expression.ListExpr [ Node singleElementRange _ ])) ->
                [ Rule.errorWithFix
                    { message = "Using List.concatMap on an element with a single item is the same as calling the function directly on that lone element."
                    , details = [ "You can replace this call by a call to the function directly" ]
                    }
                    fnRange
                    (if usingRightPizza then
                        [ Fix.replaceRangeBy { start = listRange.start, end = singleElementRange.start } "("
                        , Fix.replaceRangeBy { start = singleElementRange.end, end = listRange.end } ")"
                        , Fix.removeRange fnRange
                        ]

                     else
                        [ Fix.removeRange fnRange
                        , Fix.replaceRangeBy { start = listRange.start, end = singleElementRange.start } "("
                        , Fix.replaceRangeBy { start = singleElementRange.end, end = listRange.end } ")"
                        ]
                    )
                ]

            _ ->
                []


mapChecks : CheckInfo -> List (Error {})
mapChecks ({ lookupTable, fnRange, firstArg } as checkInfo) =
    if isIdentity lookupTable firstArg then
        [ Rule.errorWithFix
            { message = "Using List.map with an identity function is the same as not using List.map"
            , details = [ "You can remove this call and replace it by the list itself" ]
            }
            fnRange
            (noopFix checkInfo)
        ]

    else
        []


listIsEmptyChecks : CheckInfo -> List (Error {})
listIsEmptyChecks { parentRange, fnRange, firstArg } =
    case Node.value (removeParens firstArg) of
        Expression.ListExpr list ->
            if List.isEmpty list then
                [ Rule.errorWithFix
                    { message = "The call to List.isEmpty will result in True"
                    , details = [ "You can replace this call by True." ]
                    }
                    fnRange
                    [ Fix.replaceRangeBy parentRange "True" ]
                ]

            else
                [ Rule.errorWithFix
                    { message = "The call to List.isEmpty will result in False"
                    , details = [ "You can replace this call by False." ]
                    }
                    fnRange
                    [ Fix.replaceRangeBy parentRange "False" ]
                ]

        Expression.OperatorApplication "::" _ _ _ ->
            [ Rule.errorWithFix
                { message = "The call to List.isEmpty will result in False"
                , details = [ "You can replace this call by False." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "False" ]
            ]

        _ ->
            []


allChecks : CheckInfo -> List (Error {})
allChecks { lookupTable, parentRange, fnRange, firstArg, secondArg } =
    case Maybe.map (removeParens >> Node.value) secondArg of
        Just (Expression.ListExpr []) ->
            [ Rule.errorWithFix
                { message = "The call to List.all will result in True"
                , details = [ "You can replace this call by True." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "True" ]
            ]

        _ ->
            case isAlwaysBoolean lookupTable firstArg of
                Just True ->
                    [ Rule.errorWithFix
                        { message = "The call to List.all will result in True"
                        , details = [ "You can replace this call by True." ]
                        }
                        fnRange
                        (replaceByBoolFix parentRange secondArg True)
                    ]

                _ ->
                    []


anyChecks : CheckInfo -> List (Error {})
anyChecks { lookupTable, parentRange, fnRange, firstArg, secondArg } =
    case Maybe.map (removeParens >> Node.value) secondArg of
        Just (Expression.ListExpr []) ->
            [ Rule.errorWithFix
                { message = "The call to List.any will result in False"
                , details = [ "You can replace this call by False." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "False" ]
            ]

        _ ->
            case isAlwaysBoolean lookupTable firstArg of
                Just False ->
                    [ Rule.errorWithFix
                        { message = "The call to List.any will result in False"
                        , details = [ "You can replace this call by False." ]
                        }
                        fnRange
                        (replaceByBoolFix parentRange secondArg False)
                    ]

                _ ->
                    []


filterChecks : CheckInfo -> List (Error {})
filterChecks ({ lookupTable, parentRange, fnRange, firstArg, secondArg } as checkInfo) =
    case isAlwaysBoolean lookupTable firstArg of
        Just True ->
            [ Rule.errorWithFix
                { message = "Using List.filter with a function that will always return True is the same as not using List.filter"
                , details = [ "You can remove this call and replace it by the list itself" ]
                }
                fnRange
                (noopFix checkInfo)
            ]

        Just False ->
            [ Rule.errorWithFix
                { message = "Using List.filter with a function that will always return False will result in an empty list"
                , details = [ "You can remove this call and replace it by an empty list" ]
                }
                fnRange
                (replaceByEmptyListFix parentRange secondArg)
            ]

        Nothing ->
            []


filterMapChecks : CheckInfo -> List (Error {})
filterMapChecks ({ lookupTable, parentRange, fnRange, firstArg, secondArg } as checkInfo) =
    case isAlwaysMaybe lookupTable firstArg of
        Just (Just ()) ->
            [ Rule.errorWithFix
                { message = "Using List.filterMap with a function that will always return Just is the same as not using List.filter"
                , details = [ "You can remove this call and replace it by the list itself" ]
                }
                fnRange
                (noopFix checkInfo)
            ]

        Just Nothing ->
            [ Rule.errorWithFix
                { message = "Using List.filterMap with a function that will always return Nothing will result in an empty list"
                , details = [ "You can remove this call and replace it by an empty list" ]
                }
                fnRange
                (replaceByEmptyListFix parentRange secondArg)
            ]

        Nothing ->
            []


rangeChecks : CheckInfo -> List (Error {})
rangeChecks { parentRange, fnRange, firstArg, secondArg } =
    case Maybe.map2 Tuple.pair (getIntValue firstArg) (Maybe.andThen getIntValue secondArg) of
        Just ( first, second ) ->
            if first > second then
                [ Rule.errorWithFix
                    { message = "The call to List.range will result in []"
                    , details = [ "The second argument to List.range is bigger than the first one, therefore you can replace this list by an empty slist." ]
                    }
                    fnRange
                    (replaceByEmptyListFix parentRange secondArg)
                ]

            else
                []

        Nothing ->
            []


listLengthChecks : CheckInfo -> List (Error {})
listLengthChecks { parentRange, fnRange, firstArg } =
    case Node.value firstArg of
        Expression.ListExpr list ->
            [ Rule.errorWithFix
                { message = "The length of the list is " ++ String.fromInt (List.length list)
                , details = [ "The length of the list can be determined by looking at the code." ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange (String.fromInt (List.length list)) ]
            ]

        _ ->
            []


listRepeatChecks : CheckInfo -> List (Error {})
listRepeatChecks { parentRange, fnRange, firstArg, secondArg } =
    case secondArg of
        Just (Node _ (Expression.ListExpr [])) ->
            [ Rule.errorWithFix
                { message = "Using List.repeat with an empty list will result in a empty list"
                , details = [ "You can replace this call by an empty list" ]
                }
                fnRange
                [ Fix.replaceRangeBy parentRange "[]" ]
            ]

        _ ->
            case getIntValue firstArg of
                Just intValue ->
                    if intValue == 1 then
                        [ Rule.errorWithFix
                            { message = "List.repeat 1 won't do anything"
                            , details = [ "Using List.repeat with 1 will result in the second argument." ]
                            }
                            fnRange
                            [ Fix.removeRange { start = fnRange.start, end = (Node.range firstArg).end } ]
                        ]

                    else if intValue < 1 then
                        [ Rule.errorWithFix
                            { message = "List.repeat will result in an empty list"
                            , details = [ "Using List.repeat with a number less than 1 will result in an empty list. You can replace this call by an empty list." ]
                            }
                            fnRange
                            [ Fix.replaceRangeBy parentRange "[]" ]
                        ]

                    else
                        []

                _ ->
                    []


getIntValue : Node Expression -> Maybe Int
getIntValue node =
    case Node.value (removeParens node) of
        Expression.Integer n ->
            Just n

        Expression.Hex n ->
            Just n

        Expression.Negation expr ->
            Maybe.map negate (getIntValue expr)

        _ ->
            Nothing



-- FIX HELPERS


removeBoundariesFix : Node a -> List Fix
removeBoundariesFix node =
    let
        { start, end } =
            Node.range node
    in
    [ Fix.removeRange
        { start = { row = start.row, column = start.column }
        , end = { row = start.row, column = start.column + 1 }
        }
    , Fix.removeRange
        { start = { row = end.row, column = end.column - 1 }
        , end = { row = end.row, column = end.column }
        }
    ]


noopFix : CheckInfo -> List Fix
noopFix { fnRange, parentRange, secondArg, usingRightPizza } =
    [ case secondArg of
        Just listArg ->
            if usingRightPizza then
                Fix.removeRange { start = (Node.range listArg).end, end = parentRange.end }

            else
                Fix.removeRange { start = fnRange.start, end = (Node.range listArg).start }

        Nothing ->
            Fix.replaceRangeBy parentRange "identity"
    ]


replaceByEmptyListFix : Range -> Maybe a -> List Fix
replaceByEmptyListFix parentRange secondArg =
    [ case secondArg of
        Just _ ->
            Fix.replaceRangeBy parentRange "[]"

        Nothing ->
            Fix.replaceRangeBy parentRange "(always [])"
    ]


replaceByBoolFix : Range -> Maybe a -> Bool -> List Fix
replaceByBoolFix parentRange secondArg replacementValue =
    [ case secondArg of
        Just _ ->
            Fix.replaceRangeBy parentRange (boolToString replacementValue)

        Nothing ->
            Fix.replaceRangeBy parentRange ("(always " ++ boolToString replacementValue ++ ")")
    ]


boolToString : Bool -> String
boolToString bool =
    if bool then
        "True"

    else
        "False"



-- MATCHERS


isIdentity : ModuleNameLookupTable -> Node Expression -> Bool
isIdentity lookupTable baseNode =
    let
        node : Node Expression
        node =
            removeParens baseNode
    in
    case Node.value node of
        Expression.FunctionOrValue _ "identity" ->
            ModuleNameLookupTable.moduleNameFor lookupTable node == Just [ "Basics" ]

        Expression.LambdaExpression { args, expression } ->
            case args of
                arg :: [] ->
                    case getVarPattern arg of
                        Just patternName ->
                            case getExpressionName expression of
                                Just expressionName ->
                                    patternName == expressionName

                                _ ->
                                    False

                        _ ->
                            False

                _ ->
                    False

        _ ->
            False


getVarPattern : Node Pattern -> Maybe String
getVarPattern node =
    case Node.value node of
        Pattern.VarPattern name ->
            Just name

        Pattern.ParenthesizedPattern pattern ->
            getVarPattern pattern

        _ ->
            Nothing


getExpressionName : Node Expression -> Maybe String
getExpressionName node =
    case Node.value (removeParens node) of
        Expression.FunctionOrValue [] name ->
            Just name

        _ ->
            Nothing


isListLiteral : Node Expression -> Bool
isListLiteral node =
    case Node.value node of
        Expression.ListExpr _ ->
            True

        _ ->
            False


removeParens : Node Expression -> Node Expression
removeParens node =
    case Node.value node of
        Expression.ParenthesizedExpression expr ->
            removeParens expr

        _ ->
            node


isAlwaysBoolean : ModuleNameLookupTable -> Node Expression -> Maybe Bool
isAlwaysBoolean lookupTable node =
    case Node.value (removeParens node) of
        Expression.Application ((Node alwaysRange (Expression.FunctionOrValue _ "always")) :: boolean :: []) ->
            case ModuleNameLookupTable.moduleNameAt lookupTable alwaysRange of
                Just [ "Basics" ] ->
                    getBoolean lookupTable boolean

                _ ->
                    Nothing

        Expression.LambdaExpression { expression } ->
            getBoolean lookupTable expression

        _ ->
            Nothing


getBoolean : ModuleNameLookupTable -> Node Expression -> Maybe Bool
getBoolean lookupTable baseNode =
    let
        node : Node Expression
        node =
            removeParens baseNode
    in
    case Node.value node of
        Expression.FunctionOrValue _ "True" ->
            case ModuleNameLookupTable.moduleNameFor lookupTable node of
                Just [ "Basics" ] ->
                    Just True

                _ ->
                    Nothing

        Expression.FunctionOrValue _ "False" ->
            case ModuleNameLookupTable.moduleNameFor lookupTable node of
                Just [ "Basics" ] ->
                    Just False

                _ ->
                    Nothing

        _ ->
            Nothing


isAlwaysMaybe : ModuleNameLookupTable -> Node Expression -> Maybe (Maybe ())
isAlwaysMaybe lookupTable baseNode =
    let
        node : Node Expression
        node =
            removeParens baseNode
    in
    case Node.value node of
        Expression.FunctionOrValue _ "Just" ->
            case ModuleNameLookupTable.moduleNameFor lookupTable node of
                Just [ "Maybe" ] ->
                    Just (Just ())

                _ ->
                    Nothing

        Expression.Application ((Node alwaysRange (Expression.FunctionOrValue _ "always")) :: value :: []) ->
            case ModuleNameLookupTable.moduleNameAt lookupTable alwaysRange of
                Just [ "Basics" ] ->
                    getMaybeValue lookupTable value

                _ ->
                    Nothing

        Expression.LambdaExpression { args, expression } ->
            case Node.value expression of
                Expression.Application ((Node justRange (Expression.FunctionOrValue _ "Just")) :: (Node _ (Expression.FunctionOrValue [] justArgName)) :: []) ->
                    case ModuleNameLookupTable.moduleNameAt lookupTable justRange of
                        Just [ "Maybe" ] ->
                            case args of
                                (Node _ (Pattern.VarPattern lambdaArgName)) :: [] ->
                                    if lambdaArgName == justArgName then
                                        Just (Just ())

                                    else
                                        Nothing

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Expression.FunctionOrValue _ "Nothing" ->
                    case ModuleNameLookupTable.moduleNameFor lookupTable expression of
                        Just [ "Maybe" ] ->
                            Just Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


getMaybeValue : ModuleNameLookupTable -> Node Expression -> Maybe (Maybe ())
getMaybeValue lookupTable baseNode =
    let
        node : Node Expression
        node =
            removeParens baseNode
    in
    case Node.value node of
        Expression.FunctionOrValue _ "Just" ->
            case ModuleNameLookupTable.moduleNameFor lookupTable node of
                Just [ "Maybe" ] ->
                    Just (Just ())

                _ ->
                    Nothing

        Expression.FunctionOrValue _ "Nothing" ->
            case ModuleNameLookupTable.moduleNameFor lookupTable node of
                Just [ "Maybe" ] ->
                    Just Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


isAlwaysEmptyList : ModuleNameLookupTable -> Node Expression -> Bool
isAlwaysEmptyList lookupTable node =
    case Node.value (removeParens node) of
        Expression.Application ((Node alwaysRange (Expression.FunctionOrValue _ "always")) :: alwaysValue :: []) ->
            case ModuleNameLookupTable.moduleNameAt lookupTable alwaysRange of
                Just [ "Basics" ] ->
                    isEmptyList alwaysValue

                _ ->
                    False

        Expression.LambdaExpression { expression } ->
            isEmptyList expression

        _ ->
            False


isEmptyList : Node Expression -> Bool
isEmptyList node =
    case Node.value (removeParens node) of
        Expression.ListExpr [] ->
            True

        _ ->
            False
