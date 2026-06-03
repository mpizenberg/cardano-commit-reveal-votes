module Survey.Results exposing
    ( dedupLatestResponses
    , multiSelectCounts
    , responseKey
    , singleChoiceCounts
    )

{-| Pure aggregation over on-chain responses: filtering per survey, deduplicating
to the latest response per identity, grouping by survey, and per-option tallies.
-}

import Dict exposing (Dict)
import Survey.Types as ST


{-| Keep the latest response per identity tuple `(role, credential)` for one
survey. Order-independent: latest is resolved from each tx's `absolute_slot`,
tie-broken by `responseIndex`. This does not depend on the
unspecified row order of the `/tx_metadata` response. The spec's full chain order
is `(slot, txIndexInBlock, responseIndex)`; we don't fetch `txIndexInBlock`, so
two responses in the same slot from different txs are only tie-broken weakly.
-}
dedupLatestResponses : Dict String Int -> List ST.OnchainResponse -> List ST.OnchainResponse
dedupLatestResponses txSlot responses =
    let
        key r =
            ST.roleToString r.response.role ++ "|" ++ ST.credentialToHex r.response.responder

        -- Larger tuple = more recent: higher absolute slot, then higher responseIndex.
        recency r =
            ( Dict.get r.txHash txSlot |> Maybe.withDefault 0, r.responseIndex )
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


{-| Unique key for a timelocked response's decryption state: the submitting Tx
hash plus the response's position within that Tx's response list. (Responder
credential is not unique — one Tx may carry responses for several surveys.)
-}
responseKey : ST.OnchainResponse -> String
responseKey resp =
    resp.txHash ++ ":" ++ String.fromInt resp.responseIndex


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
