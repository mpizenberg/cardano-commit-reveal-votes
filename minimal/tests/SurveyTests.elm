module SurveyTests exposing (suite)

{-| Checks that `Survey.Codec.maxPlaintextSize` is a correct upper bound on the
actual CBOR size of a response.

The actual size comes from the real CBOR encoder (`Cbor.Encode` +
`Metadatum.toCbor`), exactly as `Survey.Codec.plaintextHexForAnswers` produces
it, so these tests independently validate the hand-rolled width arithmetic
(`cborUintWidth` / `cborIntWidth`) in `Survey.Codec`.

-}

import Bytes.Comparable as Bytes
import Cardano.Metadatum as Metadatum exposing (Metadatum(..))
import Cbor.Encode
import Expect
import Fuzz exposing (Fuzzer)
import Integer
import Survey.Codec exposing (maxPlaintextSize)
import Survey.Types exposing (SurveyQuestion(..))
import Test exposing (Test, describe, fuzz, test)


suite : Test
suite =
    describe "maxPlaintextSize"
        [ test "empty survey is just the empty CBOR array (1 byte)" <|
            \_ ->
                let
                    questions =
                        []
                in
                actualWidth (maximalResponse questions)
                    |> Expect.equal (maxPlaintextSize questions)
        , test "tight for a typical small survey (one of each bounded type)" <|
            \_ ->
                let
                    questions =
                        [ singleChoice 4
                        , multiSelect 5 3
                        , ranking 4 4
                        , numeric 0 100
                        , custom
                        ]
                in
                actualWidth (maximalResponse questions)
                    |> Expect.equal (maxPlaintextSize questions)
        , test "negative and wide numerics are counted at full width" <|
            \_ ->
                let
                    questions =
                        [ numeric -1000000 5
                        , numeric 0 70000
                        , numeric -23 23
                        ]
                in
                actualWidth (maximalResponse questions)
                    |> Expect.equal (maxPlaintextSize questions)
        , test "large option counts: the estimate is a safe upper bound" <|
            \_ ->
                -- 300 options straddles the 1-byte/2-byte CBOR int boundary, so
                -- the per-index over-count makes the estimate loose but never low.
                let
                    questions =
                        [ multiSelect 300 10, ranking 300 10 ]
                in
                actualWidth (maximalResponse questions)
                    |> Expect.atMost (maxPlaintextSize questions)
        , test "a non-empty free-text answer can exceed the estimate (documented limitation)" <|
            \_ ->
                let
                    questions =
                        [ custom ]

                    longText =
                        String.repeat 100 "x"

                    response =
                        [ List [ metaInt 4, metaInt 0, String longText ] ]
                in
                actualWidth response
                    |> Expect.greaterThan (maxPlaintextSize questions)
        , fuzz (Fuzz.list questionFuzzer) "a maximal response never exceeds the estimate" <|
            \questions ->
                actualWidth (maximalResponse questions)
                    |> Expect.atMost (maxPlaintextSize questions)
        ]



-- ACTUAL ENCODED SIZE (mirrors Survey.plaintextHexForAnswers)


actualWidth : List Metadatum -> Int
actualWidth answers =
    metaWidth (List answers)


metaWidth : Metadatum -> Int
metaWidth m =
    Cbor.Encode.encode (Metadatum.toCbor m)
        |> Bytes.fromBytes
        |> Bytes.width



-- MAXIMAL RESPONSE: the largest-encoding answer for each question


maximalResponse : List SurveyQuestion -> List Metadatum
maximalResponse questions =
    List.indexedMap maximalAnswer questions


maximalAnswer : Int -> SurveyQuestion -> Metadatum
maximalAnswer qIdx question =
    case question of
        SingleChoice { options } ->
            List [ metaInt 0, metaInt qIdx, metaInt (Basics.max 0 (List.length options - 1)) ]

        MultiSelect { options, maxSelections } ->
            List [ metaInt 1, metaInt qIdx, List (largestIndices (List.length options) maxSelections) ]

        Ranking { options, maxRanked } ->
            List [ metaInt 2, metaInt qIdx, List (largestIndices (List.length options) maxRanked) ]

        NumericRange { constraints } ->
            -- Pick whichever bound the real encoder makes wider, so the response
            -- is genuinely maximal.
            let
                v =
                    if metaWidth (metaInt constraints.minValue) >= metaWidth (metaInt constraints.maxValue) then
                        constraints.minValue

                    else
                        constraints.maxValue
            in
            List [ metaInt 3, metaInt qIdx, metaInt v ]

        Custom _ ->
            List [ metaInt 4, metaInt qIdx, String "" ]


largestIndices : Int -> Int -> List Metadatum
largestIndices optionCount limit =
    let
        count =
            Basics.min limit optionCount
    in
    List.range (optionCount - count) (optionCount - 1)
        |> List.map metaInt


metaInt : Int -> Metadatum
metaInt n =
    Int (Integer.fromSafeInt n)



-- QUESTION BUILDERS / FUZZERS


singleChoice : Int -> SurveyQuestion
singleChoice optionCount =
    SingleChoice { prompt = "", options = optionList optionCount }


multiSelect : Int -> Int -> SurveyQuestion
multiSelect optionCount maxSelections =
    MultiSelect { prompt = "", options = optionList optionCount, maxSelections = maxSelections }


ranking : Int -> Int -> SurveyQuestion
ranking optionCount maxRanked =
    Ranking { prompt = "", options = optionList optionCount, maxRanked = maxRanked }


numeric : Int -> Int -> SurveyQuestion
numeric minValue maxValue =
    NumericRange { prompt = "", constraints = { minValue = minValue, maxValue = maxValue, step = Nothing } }


custom : SurveyQuestion
custom =
    Custom { prompt = "", schemaUri = "x", schemaHash = Bytes.fromHexUnchecked "" }


optionList : Int -> List String
optionList n =
    List.repeat n "x"


questionFuzzer : Fuzzer SurveyQuestion
questionFuzzer =
    Fuzz.oneOf
        [ Fuzz.map singleChoice (Fuzz.intRange 1 60)
        , Fuzz.map2 multiSelect (Fuzz.intRange 1 60) (Fuzz.intRange 1 60)
        , Fuzz.map2 ranking (Fuzz.intRange 1 60) (Fuzz.intRange 1 60)
        , Fuzz.map2 numeric (Fuzz.intRange -2000000 2000000) (Fuzz.intRange -2000000 2000000)
        , Fuzz.constant custom
        ]
