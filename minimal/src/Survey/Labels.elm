module Survey.Labels exposing (definitionsLabel, metadataLabel, responseLabel)

{-| CIP-179 metadata labels. `metadataLabel` is the primary survey namespace
carrying the actual payload; `definitionsLabel` and `responseLabel` are cheap
secondary-index markers used to pre-filter txs via Koios `/tx_by_metalabel`
before downloading full metadata bodies.
-}

import FNV1a
import Survey.Types as ST


{-| Metadata label for CIP-179 surveys.
Using 171717 instead of 17 to avoid collisions during experimentation.
-}
metadataLabel : Int
metadataLabel =
    171717


{-| Survey-directory marker: added to every survey-definition tx and every
cancellation tx (both change what the survey list shows). Querying it via
`/tx_by_metalabel` enumerates the directory without downloading bodies.
-}
definitionsLabel : Int
definitionsLabel =
    1717170


responseLabelBase : Int
responseLabelBase =
    1717000000


{-| Per-survey response index label, added to every response tx for a given
survey. A 2^20-wide band based at `responseLabelBase`: well clear of the
`metadataLabel` / `definitionsLabel` markers and inside the uint32 (5-byte CBOR)
tier, so the wire cost matches the labels already shipped. Collisions between
surveys are false-positive-only (response bodies are validated against the
survey ref), so the band width is a soft knob.
-}
responseLabel : ST.SurveyRef -> Int
responseLabel ref =
    responseLabelBase + modBy 0x00100000 (FNV1a.hash (ref.txHash ++ ":" ++ String.fromInt ref.index))
