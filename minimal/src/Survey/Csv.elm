module Survey.Csv exposing (buildCsv)

{-| CSV export of survey responses. Pure: the caller supplies `revealedItems`,
which yields a response's answers (public directly, timelocked only once
revealed), so this module needs no app state.
-}

import Bytes.Comparable as Bytes
import Cardano.Metadatum as Metadatum
import Integer
import Survey.Types as ST


{-| One row per (deduplicated) response: responder, role, then one cell per
question. Choice answers use option labels; ranking uses "a > b > c"; numeric the
value; custom a compact text/hex. Not-yet-revealed timelocked responses export
"encrypted" for every question cell.
-}
buildCsv : (ST.OnchainResponse -> Maybe (List ST.AnswerItem)) -> ST.OnchainSurvey -> List ST.OnchainResponse -> String
buildCsv revealedItems survey deduped =
    let
        questions =
            survey.definition.questions

        header =
            "responder" :: "role" :: List.map questionPromptOf questions

        row resp =
            ST.credentialToHex resp.response.responder
                :: ST.roleToString resp.response.role
                :: answerCells revealedItems questions resp
    in
    String.join "\u{000D}\n" (csvRow header :: List.map (row >> csvRow) deduped)


answerCells : (ST.OnchainResponse -> Maybe (List ST.AnswerItem)) -> List ST.SurveyQuestion -> ST.OnchainResponse -> List String
answerCells revealedItems questions resp =
    case revealedItems resp of
        Just items ->
            List.indexedMap (\qIdx q -> cellValue q (findAnswer qIdx items)) questions

        Nothing ->
            List.map (\_ -> "encrypted") questions


findAnswer : Int -> List ST.AnswerItem -> Maybe ST.AnswerItem
findAnswer qIdx items =
    List.head (List.filter (\it -> answerQuestionIndex it == qIdx) items)


answerQuestionIndex : ST.AnswerItem -> Int
answerQuestionIndex item =
    case item of
        ST.AnswerSingleChoice q _ ->
            q

        ST.AnswerMultiSelect q _ ->
            q

        ST.AnswerRanking q _ ->
            q

        ST.AnswerNumeric q _ ->
            q

        ST.AnswerCustom q _ ->
            q


cellValue : ST.SurveyQuestion -> Maybe ST.AnswerItem -> String
cellValue question maybeItem =
    case maybeItem of
        Nothing ->
            ""

        Just (ST.AnswerSingleChoice _ o) ->
            optionLabel question o

        Just (ST.AnswerMultiSelect _ os) ->
            String.join "; " (List.map (optionLabel question) os)

        Just (ST.AnswerRanking _ os) ->
            String.join " > " (List.map (optionLabel question) os)

        Just (ST.AnswerNumeric _ v) ->
            String.fromInt v

        Just (ST.AnswerCustom _ meta) ->
            customCellValue meta


optionLabel : ST.SurveyQuestion -> Int -> String
optionLabel question optIdx =
    let
        options =
            case question of
                ST.SingleChoice r ->
                    r.options

                ST.MultiSelect r ->
                    r.options

                ST.Ranking r ->
                    r.options

                _ ->
                    []
    in
    List.head (List.drop optIdx options) |> Maybe.withDefault (String.fromInt optIdx)


questionPromptOf : ST.SurveyQuestion -> String
questionPromptOf question =
    case question of
        ST.SingleChoice r ->
            r.prompt

        ST.MultiSelect r ->
            r.prompt

        ST.Ranking r ->
            r.prompt

        ST.NumericRange r ->
            r.prompt

        ST.Custom r ->
            r.prompt


customCellValue : Metadatum.Metadatum -> String
customCellValue meta =
    case meta of
        Metadatum.String s ->
            s

        Metadatum.Bytes b ->
            "0x" ++ Bytes.toHex (Bytes.toAny b)

        Metadatum.Int i ->
            String.fromInt (Integer.toInt i)

        _ ->
            "(custom)"


csvRow : List String -> String
csvRow fields =
    String.join "," (List.map csvField fields)


csvField : String -> String
csvField s =
    if String.contains "," s || String.contains "\"" s || String.contains "\n" s || String.contains "\u{000D}" s then
        "\"" ++ String.replace "\"" "\"\"" s ++ "\""

    else
        s
