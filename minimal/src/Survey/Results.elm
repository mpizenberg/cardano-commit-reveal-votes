module Survey.Results exposing
    ( ResponseGroup
    , ballotKey
    , dedupLatestResponses
    , groupResponsesBySurvey
    , multiSelectCounts
    , responsesForSurvey
    , singleChoiceCounts
    )

{-| Pure aggregation over on-chain responses: filtering per survey, deduplicating
to the latest ballot per identity, grouping by survey, and per-option tallies.
-}

import Dict exposing (Dict)
import Survey.Types as ST


responsesForSurvey : ST.OnchainSurvey -> List ST.OnchainResponse -> List ST.OnchainResponse
responsesForSurvey survey responses =
    List.filter
        (\r -> r.response.surveyRef.txHash == survey.txHash && r.response.surveyRef.index == survey.index)
        responses


{-| Keep the latest response per identity tuple `(role, credential)` for one
survey. Order-independent: latest is resolved from each tx's `absolute_slot`,
tie-broken by `ballotIndex` (responseIndex). This does not depend on the
unspecified row order of the `/tx_metadata` response. The spec's full chain order
is `(slot, txIndexInBlock, responseIndex)`; we don't fetch `txIndexInBlock`, so
two responses in the same slot from different txs are only tie-broken weakly.
-}
dedupLatestResponses : Dict String Int -> List ST.OnchainResponse -> List ST.OnchainResponse
dedupLatestResponses txSlot responses =
    let
        key r =
            ST.roleToString r.response.role ++ "|" ++ ST.credentialToHex r.response.responder

        -- Larger tuple = more recent: higher absolute slot, then higher ballotIndex.
        recency r =
            ( Dict.get r.txHash txSlot |> Maybe.withDefault 0, r.ballotIndex )
    in
    List.foldl
        (\r acc ->
            Dict.update (key r)
                (\existing ->
                    case existing of
                        Just e ->
                            if recency r > recency e then
                                Just r

                            else
                                Just e

                        Nothing ->
                            Just r
                )
                acc
        )
        Dict.empty
        responses
        |> Dict.values


type alias ResponseGroup =
    { survey : Maybe ST.OnchainSurvey
    , surveyRef : ST.SurveyRef
    , responses : List ST.OnchainResponse
    }


groupResponsesBySurvey : List ST.OnchainSurvey -> List ST.OnchainResponse -> List ResponseGroup
groupResponsesBySurvey surveys responses =
    let
        refKey ref =
            ref.txHash ++ ":" ++ String.fromInt ref.index

        surveyDict =
            List.map (\s -> ( s.txHash ++ ":" ++ String.fromInt s.index, s )) surveys
                |> Dict.fromList
    in
    List.foldl
        (\resp acc ->
            let
                key =
                    refKey resp.response.surveyRef
            in
            Dict.update key
                (\existing ->
                    case existing of
                        Just group ->
                            Just { group | responses = group.responses ++ [ resp ] }

                        Nothing ->
                            Just
                                { survey = Dict.get key surveyDict
                                , surveyRef = resp.response.surveyRef
                                , responses = [ resp ]
                                }
                )
                acc
        )
        Dict.empty
        responses
        |> Dict.values


{-| Unique key for a timelocked ballot's decryption state: the submitting Tx
hash plus the ballot's position within that Tx's ballot list. (Responder
credential is not unique — one Tx may carry ballots for several surveys.)
-}
ballotKey : ST.OnchainResponse -> String
ballotKey resp =
    resp.txHash ++ ":" ++ String.fromInt resp.ballotIndex


singleChoiceCounts : Int -> List String -> List ST.AnswerItem -> List Int
singleChoiceCounts qIdx options items =
    let
        selected =
            List.filterMap
                (\it ->
                    case it of
                        ST.AnswerSingleChoice q o ->
                            if q == qIdx then
                                Just o

                            else
                                Nothing

                        _ ->
                            Nothing
                )
                items
    in
    List.indexedMap (\optIdx _ -> List.length (List.filter ((==) optIdx) selected)) options


multiSelectCounts : Int -> List String -> List ST.AnswerItem -> List Int
multiSelectCounts qIdx options items =
    let
        selected =
            List.concatMap
                (\it ->
                    case it of
                        ST.AnswerMultiSelect q os ->
                            if q == qIdx then
                                os

                            else
                                []

                        _ ->
                            []
                )
                items
    in
    List.indexedMap (\optIdx _ -> List.length (List.filter ((==) optIdx) selected)) options
