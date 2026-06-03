module Survey.Codec exposing
    ( buildCancellationMetadatum
    , buildTimelockedResponseMetadatum
    , decodeAnswersFromPlaintextHex
    , fromMetadatum
    , maxPlaintextSize
    , metaInt
    , metaStr
    , plaintextHexForAnswers
    , responseEnvelope
    , resultApply
    , toMetadatum
    , traverseResults
    )

{-| CIP-179 wire codec: Metadatum <-> domain types, plus the worst-case response
sizing used to pad timelocked ciphertexts. Pure and independent of form/UI state.
-}

import Bytes.Comparable as Bytes exposing (Any, Bytes)
import Cardano.Address exposing (Credential(..))
import Cardano.Metadatum as Metadatum exposing (Metadatum(..))
import Cbor.Decode
import Cbor.Encode
import Integer
import Survey.Types exposing (AnswerItem(..), NumericConstraints, ParsedPayload(..), ResponseAnswers(..), Role, SubmissionMode(..), SurveyDefinition, SurveyQuestion(..), SurveyRef, SurveyResponse, WeightingMode, intToRole, intToWeightingMode, roleToInt, weightingModeToInt)



-- ============================================================
-- ENCODING (SurveyDefinition -> Metadatum)
-- ============================================================


chunkText : String -> List String
chunkText s =
    if String.isEmpty s then
        [ "" ]

    else
        chunkTextByBytes (String.toList s) [] "" 0


{-| Split a string into chunks that each fit within 64 UTF-8 bytes.
Splits at character boundaries to avoid cutting multi-byte chars.
-}
chunkTextByBytes : List Char -> List String -> String -> Int -> List String
chunkTextByBytes chars acc currentChunk currentBytes =
    case chars of
        [] ->
            List.reverse (currentChunk :: acc)

        c :: rest ->
            let
                w =
                    charUtf8Width c
            in
            if currentBytes + w > 64 then
                chunkTextByBytes rest (currentChunk :: acc) (String.fromChar c) w

            else
                chunkTextByBytes rest acc (currentChunk ++ String.fromChar c) (currentBytes + w)


charUtf8Width : Char -> Int
charUtf8Width c =
    let
        code =
            Char.toCode c
    in
    if code <= 0x7F then
        1

    else if code <= 0x07FF then
        2

    else if code <= 0xFFFF then
        3

    else
        4


metaInt : Int -> Metadatum
metaInt n =
    Int (Integer.fromSafeInt n)


metaStr : String -> Metadatum
metaStr s =
    String s


metaBytes : Bytes Any -> Metadatum
metaBytes b =
    Bytes b


chunkedTextToMeta : String -> Metadatum
chunkedTextToMeta s =
    case chunkText s of
        [ single ] ->
            metaStr single

        chunks ->
            List (List.map metaStr chunks)


credentialToMeta : Credential -> Metadatum
credentialToMeta cred =
    case cred of
        VKeyHash hash ->
            List [ metaInt 0, metaBytes (Bytes.toAny hash) ]

        ScriptHash hash ->
            List [ metaInt 1, metaBytes (Bytes.toAny hash) ]


questionToMeta : SurveyQuestion -> Metadatum
questionToMeta q =
    case q of
        SingleChoice { prompt, options } ->
            List
                [ metaInt 0
                , chunkedTextToMeta prompt
                , List (List.map metaStr options)
                ]

        MultiSelect { prompt, options, maxSelections } ->
            List
                [ metaInt 1
                , chunkedTextToMeta prompt
                , List (List.map metaStr options)
                , metaInt maxSelections
                ]

        Ranking { prompt, options, maxRanked } ->
            List
                [ metaInt 2
                , chunkedTextToMeta prompt
                , List (List.map metaStr options)
                , metaInt maxRanked
                ]

        NumericRange { prompt, constraints } ->
            let
                constraintList =
                    [ metaInt constraints.minValue, metaInt constraints.maxValue ]
                        ++ (case constraints.step of
                                Just s ->
                                    [ metaInt s ]

                                Nothing ->
                                    []
                           )
            in
            List
                [ metaInt 3
                , chunkedTextToMeta prompt
                , List constraintList
                ]

        Custom { prompt, schemaUri, schemaHash } ->
            List
                [ metaInt 4
                , chunkedTextToMeta prompt
                , chunkedTextToMeta schemaUri
                , metaBytes schemaHash
                ]


roleWeightingToMeta : List ( Role, WeightingMode ) -> Metadatum
roleWeightingToMeta rws =
    Map
        (List.map
            (\( role, wm ) ->
                ( metaInt (roleToInt role), metaInt (weightingModeToInt wm) )
            )
            rws
        )


{-| Encode the submission mode as a tagged sum: `[0]` for public, or
`[1, chain_hash, round, padding_size]` for timelocked.
-}
submissionModeToMeta : SubmissionMode -> Metadatum
submissionModeToMeta mode =
    case mode of
        Public ->
            List [ metaInt 0 ]

        Timelocked cfg ->
            List
                [ metaInt 1
                , metaBytes cfg.chainHash
                , metaInt cfg.round
                , metaInt cfg.paddingSize
                ]


toMetadatum : SurveyDefinition -> Metadatum
toMetadatum def =
    List
        [ metaInt 0
        , List
            [ List
                [ metaInt def.specVersion
                , credentialToMeta def.owner
                , chunkedTextToMeta def.title
                , chunkedTextToMeta def.description
                , roleWeightingToMeta def.roleWeighting
                , metaInt def.endEpoch
                , submissionModeToMeta def.submissionMode
                , List (List.map questionToMeta def.questions)
                ]
            ]
        ]



-- ============================================================
-- DECODING (Metadatum -> SurveyDefinition)
-- ============================================================


expectInt : Metadatum -> Result String Int
expectInt m =
    case m of
        Int i ->
            Ok (Integer.toInt i)

        _ ->
            Err "Expected integer"


expectStr : Metadatum -> Result String String
expectStr m =
    case m of
        String s ->
            Ok s

        _ ->
            Err "Expected string"


expectList : Metadatum -> Result String (List Metadatum)
expectList m =
    case m of
        List items ->
            Ok items

        _ ->
            Err "Expected list"


expectMap : Metadatum -> Result String (List ( Metadatum, Metadatum ))
expectMap m =
    case m of
        Map pairs ->
            Ok pairs

        _ ->
            Err "Expected map"


expectBytes : Metadatum -> Result String (Bytes Any)
expectBytes m =
    case m of
        Bytes b ->
            Ok b

        _ ->
            Err "Expected bytes"


decodeChunkedText : Metadatum -> Result String String
decodeChunkedText m =
    case m of
        String s ->
            Ok s

        List items ->
            traverseResults expectStr items
                |> Result.map String.concat

        _ ->
            Err "Expected string or list of strings"


traverseResults : (a -> Result e b) -> List a -> Result e (List b)
traverseResults f list =
    List.foldr
        (\item acc ->
            Result.map2 (::) (f item) acc
        )
        (Ok [])
        list


decodeCredential : Metadatum -> Result String Credential
decodeCredential m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ tagM, hashM ] ->
                        Result.map2
                            (\tag hash ->
                                case tag of
                                    0 ->
                                        Ok (VKeyHash (Bytes.fromHexUnchecked (Bytes.toHex hash)))

                                    1 ->
                                        Ok (ScriptHash (Bytes.fromHexUnchecked (Bytes.toHex hash)))

                                    _ ->
                                        Err ("Unknown credential tag: " ++ String.fromInt tag)
                            )
                            (expectInt tagM)
                            (expectBytes hashM)
                            |> Result.andThen identity

                    _ ->
                        Err "Credential must be a 2-element list"
            )


decodeQuestion : Metadatum -> Result String SurveyQuestion
decodeQuestion m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    tagM :: rest ->
                        expectInt tagM
                            |> Result.andThen
                                (\tag ->
                                    case tag of
                                        0 ->
                                            decodeSingleChoice rest

                                        1 ->
                                            decodeMultiSelect rest

                                        2 ->
                                            decodeRanking rest

                                        3 ->
                                            decodeNumericRange rest

                                        4 ->
                                            decodeCustom rest

                                        _ ->
                                            Err ("Unknown question type tag: " ++ String.fromInt tag)
                                )

                    [] ->
                        Err "Question array is empty"
            )


decodeSingleChoice : List Metadatum -> Result String SurveyQuestion
decodeSingleChoice items =
    case items of
        [ promptM, optionsM ] ->
            Result.map2
                (\prompt options ->
                    SingleChoice { prompt = prompt, options = options }
                )
                (decodeChunkedText promptM)
                (expectList optionsM |> Result.andThen (traverseResults expectStr))

        _ ->
            Err "SingleChoice: expected [prompt, options]"


decodeMultiSelect : List Metadatum -> Result String SurveyQuestion
decodeMultiSelect items =
    case items of
        [ promptM, optionsM, maxM ] ->
            Result.map3
                (\prompt options maxSel ->
                    MultiSelect { prompt = prompt, options = options, maxSelections = maxSel }
                )
                (decodeChunkedText promptM)
                (expectList optionsM |> Result.andThen (traverseResults expectStr))
                (expectInt maxM)

        _ ->
            Err "MultiSelect: expected [prompt, options, maxSelections]"


decodeRanking : List Metadatum -> Result String SurveyQuestion
decodeRanking items =
    case items of
        [ promptM, optionsM, maxM ] ->
            Result.map3
                (\prompt options maxR ->
                    Ranking { prompt = prompt, options = options, maxRanked = maxR }
                )
                (decodeChunkedText promptM)
                (expectList optionsM |> Result.andThen (traverseResults expectStr))
                (expectInt maxM)

        _ ->
            Err "Ranking: expected [prompt, options, maxRanked]"


decodeNumericRange : List Metadatum -> Result String SurveyQuestion
decodeNumericRange items =
    case items of
        [ promptM, constraintsM ] ->
            Result.map2
                (\prompt constraints ->
                    NumericRange { prompt = prompt, constraints = constraints }
                )
                (decodeChunkedText promptM)
                (decodeNumericConstraints constraintsM)

        _ ->
            Err "NumericRange: expected [prompt, constraints]"


decodeNumericConstraints : Metadatum -> Result String NumericConstraints
decodeNumericConstraints m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ minM, maxM ] ->
                        Result.map2
                            (\minV maxV ->
                                { minValue = minV, maxValue = maxV, step = Nothing }
                            )
                            (expectInt minM)
                            (expectInt maxM)

                    [ minM, maxM, stepM ] ->
                        Result.map3
                            (\minV maxV stepV ->
                                { minValue = minV, maxValue = maxV, step = Just stepV }
                            )
                            (expectInt minM)
                            (expectInt maxM)
                            (expectInt stepM)

                    _ ->
                        Err "NumericConstraints: expected 2 or 3 elements"
            )


decodeCustom : List Metadatum -> Result String SurveyQuestion
decodeCustom items =
    case items of
        [ promptM, uriM, hashM ] ->
            Result.map3
                (\prompt uri hash ->
                    Custom { prompt = prompt, schemaUri = uri, schemaHash = hash }
                )
                (decodeChunkedText promptM)
                (decodeChunkedText uriM)
                (expectBytes hashM)

        _ ->
            Err "Custom: expected [prompt, schemaUri, schemaHash]"


decodeRoleWeighting : Metadatum -> Result String (List ( Role, WeightingMode ))
decodeRoleWeighting m =
    expectMap m
        |> Result.andThen
            (traverseResults
                (\( keyM, valM ) ->
                    Result.map2 Tuple.pair
                        (expectInt keyM
                            |> Result.andThen
                                (\n ->
                                    intToRole n
                                        |> Result.fromMaybe ("Unknown role: " ++ String.fromInt n)
                                )
                        )
                        (expectInt valM
                            |> Result.andThen
                                (\n ->
                                    intToWeightingMode n
                                        |> Result.fromMaybe ("Unknown weighting mode: " ++ String.fromInt n)
                                )
                        )
                )
            )


decodeDefinition : Metadatum -> Result String SurveyDefinition
decodeDefinition m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ versionM, ownerM, titleM, descM, rwM, epochM, modeM, questionsM ] ->
                        Ok SurveyDefinition
                            |> resultApply (expectInt versionM)
                            |> resultApply (decodeCredential ownerM)
                            |> resultApply (decodeChunkedText titleM)
                            |> resultApply (decodeChunkedText descM)
                            |> resultApply (decodeRoleWeighting rwM)
                            |> resultApply (expectInt epochM)
                            |> resultApply (decodeSubmissionMode modeM)
                            |> resultApply (expectList questionsM |> Result.andThen (traverseResults decodeQuestion))

                    _ ->
                        Err ("Survey definition (v3): expected 8 fields, got " ++ String.fromInt (List.length items))
            )


{-| Decode the response-mode tagged sum: `[0]` => `Public`,
`[1, chain_hash, round, padding_size]` => `Timelocked`.
-}
decodeSubmissionMode : Metadatum -> Result String SubmissionMode
decodeSubmissionMode modeM =
    expectList modeM
        |> Result.andThen
            (\items ->
                case items of
                    [ tagM ] ->
                        expectInt tagM
                            |> Result.andThen
                                (\tag ->
                                    if tag == 0 then
                                        Ok Public

                                    else
                                        Err ("Submission mode [" ++ String.fromInt tag ++ "]: only tag 0 takes no parameters")
                                )

                    [ tagM, chainHashM, roundM, paddingM ] ->
                        expectInt tagM
                            |> Result.andThen
                                (\tag ->
                                    if tag == 1 then
                                        Result.map3
                                            (\chainHash round padding ->
                                                Timelocked
                                                    { chainHash = chainHash
                                                    , round = round
                                                    , paddingSize = padding
                                                    }
                                            )
                                            (expectBytes chainHashM)
                                            (expectInt roundM)
                                            (expectInt paddingM)

                                    else
                                        Err ("Unknown submission mode tag: " ++ String.fromInt tag)
                                )

                    _ ->
                        Err "Submission mode: expected [0] or [1, chain_hash, round, padding_size]"
            )


resultApply : Result e a -> Result e (a -> b) -> Result e b
resultApply ra rf =
    case ( rf, ra ) of
        ( Ok f, Ok a ) ->
            Ok (f a)

        ( Err e, _ ) ->
            Err e

        ( _, Err e ) ->
            Err e


fromMetadatum : Metadatum -> Result String ParsedPayload
fromMetadatum m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ tagM, contentM ] ->
                        expectInt tagM
                            |> Result.andThen
                                (\tag ->
                                    case tag of
                                        0 ->
                                            expectList contentM
                                                |> Result.andThen (traverseResults decodeDefinition)
                                                |> Result.map ParsedDefinitions

                                        1 ->
                                            expectList contentM
                                                |> Result.andThen (traverseResults decodeResponse)
                                                |> Result.map ParsedResponses

                                        2 ->
                                            expectList contentM
                                                |> Result.andThen (traverseResults decodeSurveyRef)
                                                |> Result.map ParsedCancellations

                                        _ ->
                                            Err ("Unknown CIP-179 tag: " ++ String.fromInt tag)
                                )

                    _ ->
                        Err "CIP-179 payload: expected [tag, content]"
            )


decodeResponse : Metadatum -> Result String SurveyResponse
decodeResponse m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ versionM, refM, roleM, credM, answersM ] ->
                        Ok SurveyResponse
                            |> resultApply (expectInt versionM)
                            |> resultApply (decodeSurveyRef refM)
                            |> resultApply
                                (expectInt roleM
                                    |> Result.andThen
                                        (\n ->
                                            intToRole n
                                                |> Result.fromMaybe ("Unknown role: " ++ String.fromInt n)
                                        )
                                )
                            |> resultApply (decodeCredential credM)
                            |> resultApply (decodeResponseAnswers answersM)

                    _ ->
                        Err ("Survey response (v3): expected 5-element array, got " ++ String.fromInt (List.length items))
            )


decodeSurveyRef : Metadatum -> Result String SurveyRef
decodeSurveyRef m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    [ txIdM, indexM ] ->
                        Result.map2 SurveyRef
                            (expectBytes txIdM |> Result.map (\b -> Bytes.toHex b))
                            (expectInt indexM)

                    _ ->
                        Err "Survey ref: expected [tx_id, index]"
            )


decodeAnswerItem : Metadatum -> Result String AnswerItem
decodeAnswerItem m =
    expectList m
        |> Result.andThen
            (\items ->
                case items of
                    tagM :: rest ->
                        expectInt tagM
                            |> Result.andThen
                                (\tag ->
                                    case ( tag, rest ) of
                                        ( 0, [ qIdxM, optIdxM ] ) ->
                                            Result.map2 AnswerSingleChoice
                                                (expectInt qIdxM)
                                                (expectInt optIdxM)

                                        ( 1, [ qIdxM, selM ] ) ->
                                            Result.map2 AnswerMultiSelect
                                                (expectInt qIdxM)
                                                (expectList selM |> Result.andThen (traverseResults expectInt))

                                        ( 2, [ qIdxM, rankM ] ) ->
                                            Result.map2 AnswerRanking
                                                (expectInt qIdxM)
                                                (expectList rankM |> Result.andThen (traverseResults expectInt))

                                        ( 3, [ qIdxM, valM ] ) ->
                                            Result.map2 AnswerNumeric
                                                (expectInt qIdxM)
                                                (expectInt valM)

                                        ( 4, [ qIdxM, valM ] ) ->
                                            expectInt qIdxM
                                                |> Result.map (\qIdx -> AnswerCustom qIdx valM)

                                        _ ->
                                            Err ("Unknown answer tag/arity: " ++ String.fromInt tag)
                                )

                    [] ->
                        Err "Answer item array is empty"
            )


{-| The response answers field is either a list of answer-item arrays (public)
or a list of byte chunks / a single byte string (timelocked ciphertext). We pick
the shape from the metadatum structure, without needing the survey definition.
-}
decodeResponseAnswers : Metadatum -> Result String ResponseAnswers
decodeResponseAnswers m =
    case m of
        Bytes b ->
            Ok (TimelockedAnswers b)

        List items ->
            if not (List.isEmpty items) && List.all isBytesItem items then
                items
                    |> List.filterMap
                        (\item ->
                            case item of
                                Bytes b ->
                                    Just b

                                _ ->
                                    Nothing
                        )
                    |> List.foldr Bytes.concat Bytes.empty
                    |> TimelockedAnswers
                    |> Ok

            else
                traverseResults decodeAnswerItem items
                    |> Result.map PublicAnswers

        _ ->
            Err "Response answers: expected a list or byte blob"


isBytesItem : Metadatum -> Bool
isBytesItem m =
    case m of
        Bytes _ ->
            True

        _ ->
            False



-- ============================================================
-- RESPONSE ENCODING
-- ============================================================


{-| Wrap encoded answers (plaintext list or ciphertext byte chunks) into the
CIP-179 response envelope `[1, [[ specVersion, [tx,idx], role, cred, answers ]]]`.
The per-response specVersion lets a response be decoded without first resolving
its survey definition.
-}
responseEnvelope : SurveyRef -> Role -> Credential -> Metadatum -> Metadatum
responseEnvelope surveyRef role responder answersMeta =
    List
        [ metaInt 1
        , List
            [ List
                [ metaInt 3
                , List [ metaBytes (Bytes.fromHexUnchecked surveyRef.txHash), metaInt surveyRef.index ]
                , metaInt (roleToInt role)
                , credentialToMeta responder
                , answersMeta
                ]
            ]
        ]


{-| Worst-case CBOR size (bytes) of a fully-answered response for these questions:
every question answered with its largest-encoding answer. Used as the default
padding size so all ciphertexts for a survey share one length and thus leak
nothing about their content.

Estimation rules:

  - Free-text (`Custom`) answers count as the empty string `""`, since their
    length is unbounded.
  - Numeric answers take the wider of the two range bounds (CBOR encodes a
    negative `v` via the magnitude `-1 - v`), capped at the 64-bit form.
  - Choice indices are bounded by the option count; multi-select / ranking lists
    are bounded by their max-selections / max-ranked limit.

-}
maxPlaintextSize : List SurveyQuestion -> Int
maxPlaintextSize questions =
    cborUintWidth (List.length questions)
        + List.sum (List.indexedMap maxAnswerItemSize questions)


{-| Worst-case CBOR size of one answer item `[tag, qIdx, value]`.
-}
maxAnswerItemSize : Int -> SurveyQuestion -> Int
maxAnswerItemSize qIdx question =
    let
        valueWidth =
            case question of
                SingleChoice { options } ->
                    cborUintWidth (Basics.max 0 (List.length options - 1))

                MultiSelect { options, maxSelections } ->
                    cborChoiceListWidth (List.length options) maxSelections

                Ranking { options, maxRanked } ->
                    cborChoiceListWidth (List.length options) maxRanked

                NumericRange { constraints } ->
                    Basics.max
                        (cborIntWidth constraints.minValue)
                        (cborIntWidth constraints.maxValue)

                Custom _ ->
                    1
    in
    -- 1 (array-3 header) + 1 (tag, always < 24) + qIdx + value
    2 + cborUintWidth qIdx + valueWidth


{-| Worst-case CBOR size of a list of choice indices: at most `limit` indices,
each no larger than `optionCount - 1`.
-}
cborChoiceListWidth : Int -> Int -> Int
cborChoiceListWidth optionCount limit =
    let
        count =
            Basics.min limit optionCount
    in
    cborUintWidth count + count * cborUintWidth (Basics.max 0 (optionCount - 1))


{-| Bytes to CBOR-encode a non-negative integer (also the header width for array
and string lengths). Capped at the 64-bit form (9 bytes).
-}
cborUintWidth : Int -> Int
cborUintWidth n =
    if n < 24 then
        1

    else if n < 256 then
        2

    else if n < 65536 then
        3

    else if n < 4294967296 then
        5

    else
        9


{-| Bytes to CBOR-encode a possibly-negative integer. A negative `v` encodes the
magnitude `-1 - v`. Capped at the 64-bit form (9 bytes).
-}
cborIntWidth : Int -> Int
cborIntWidth v =
    if v >= 0 then
        cborUintWidth v

    else
        cborUintWidth (negate v - 1)


{-| CBOR-encode the answer list and zero-pad it up to `paddingSize` bytes, ready
for `tlock` encryption. Returns lowercase hex. Larger-than-`paddingSize` answer
sets are not truncated (they simply yield a longer ciphertext).
-}
plaintextHexForAnswers : Int -> List Metadatum -> String
plaintextHexForAnswers paddingSize encodedAnswers =
    let
        cbor =
            Bytes.fromBytes (Cbor.Encode.encode (Metadatum.toCbor (List encodedAnswers)))

        padNeeded =
            Basics.max 0 (paddingSize - Bytes.width cbor)

        padding =
            Bytes.fromU8 (List.repeat padNeeded 0)
    in
    Bytes.toHex (Bytes.concat cbor padding)


{-| Build a timelocked response metadatum, embedding the ciphertext (the
armor-stripped age payload) as a list of ≤64-byte byte chunks.
-}
buildTimelockedResponseMetadatum : SurveyRef -> Role -> Credential -> Bytes Any -> Metadatum
buildTimelockedResponseMetadatum surveyRef role responder ciphertext =
    responseEnvelope surveyRef
        role
        responder
        (List (List.map metaBytes (Bytes.chunksOf 64 ciphertext)))


{-| Decode the answer items from a decrypted, zero-padded CBOR plaintext (hex).
Trailing padding is ignored: the CBOR array self-delimits.
-}
decodeAnswersFromPlaintextHex : String -> Result String (List AnswerItem)
decodeAnswersFromPlaintextHex hex =
    case Bytes.fromHex hex of
        Nothing ->
            Err "Invalid plaintext hex"

        Just b ->
            case Cbor.Decode.decode Metadatum.fromCbor (Bytes.toBytes b) of
                Just (List items) ->
                    traverseResults decodeAnswerItem items

                Just _ ->
                    Err "Decrypted CBOR is not an answer array"

                Nothing ->
                    Err "Failed to CBOR-decode the decrypted response"


buildCancellationMetadatum : SurveyRef -> Metadatum
buildCancellationMetadatum ref =
    List
        [ metaInt 2
        , List
            [ List [ metaBytes (Bytes.fromHexUnchecked ref.txHash), metaInt ref.index ]
            ]
        ]
