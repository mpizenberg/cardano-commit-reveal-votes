module Tlock exposing
    ( decrypt
    , encrypt
    , fetchRound
    , formatDuration
    , revealTimeOf
    , roundForDeadline
    )

{-| Drand `tlock` (timelock encryption) bindings for timelocked responses.

The crypto runs in JS (`static/tlock.js`, Drand quicknet) and is reached through
two `elm-concurrent-task` tasks. Payloads cross the channel as lowercase hex.
The quicknet genesis parameters are hardcoded both here and in the JS bundle.

-}

import ConcurrentTask exposing (ConcurrentTask)
import Json.Decode as JD
import Json.Encode as JE



-- QUICKNET CONSTANTS (see static/tlock.js header)


{-| Drand quicknet genesis time, unix seconds.
-}
genesisTime : Int
genesisTime =
    1692803367


{-| Drand quicknet round period, seconds.
-}
period : Int
period =
    3


{-| Round `R` whose signature publishes at (or just after) `deadlineUnix`.
Matches tlock-js `roundAt`: `floor((t - genesis) / period) + 1`.
-}
roundForDeadline : Int -> Int
roundForDeadline deadlineUnix =
    ((deadlineUnix - genesisTime) // period) + 1


{-| Wall-clock unix seconds at which round `R` becomes decryptable.
-}
revealTimeOf : Int -> Int
revealTimeOf round =
    genesisTime + (round - 1) * period


{-| Human-readable duration from a count of seconds, e.g. `3d 4h 5m 6s`.
Only the largest non-zero units are shown; `0s` for non-positive input.
-}
formatDuration : Int -> String
formatDuration totalSeconds =
    if totalSeconds <= 0 then
        "0s"

    else
        let
            days =
                totalSeconds // 86400

            hours =
                modBy 86400 totalSeconds // 3600

            minutes =
                modBy 3600 totalSeconds // 60

            seconds =
                modBy 60 totalSeconds

            parts =
                [ ( days, "d" )
                , ( hours, "h" )
                , ( minutes, "m" )
                , ( seconds, "s" )
                ]
                    |> List.filter (\( value, _ ) -> value > 0)
                    |> List.map (\( value, unit ) -> String.fromInt value ++ unit)
        in
        String.join " " parts



-- TASKS


{-| Encrypt a hex plaintext to round `R`. Local crypto; returns the
armor-stripped age payload as hex.
-}
encrypt : { round : Int, plaintextHex : String } -> ConcurrentTask String { ciphertextHex : String }
encrypt args =
    ConcurrentTask.define
        { function = "tlock:encrypt"
        , expect =
            ConcurrentTask.expectJson
                (JD.map (\h -> { ciphertextHex = h }) (JD.field "ciphertextHex" JD.string))
        , errors = ConcurrentTask.expectThrows identity
        , args =
            JE.object
                [ ( "round", JE.int args.round )
                , ( "plaintextHex", JE.string args.plaintextHex )
                ]
        }


{-| Fetch and verify the Drand beacon for a round. This is the only networked
step of a reveal: fetch once per survey, then reuse the returned `beaconJson` to
decrypt every response locally. Fails (throws JS-side) if the round is not yet
published.
-}
fetchRound : { round : Int } -> ConcurrentTask String { beaconJson : String }
fetchRound args =
    ConcurrentTask.define
        { function = "tlock:fetchRound"
        , expect =
            ConcurrentTask.expectJson
                (JD.map (\b -> { beaconJson = b }) (JD.field "beaconJson" JD.string))
        , errors = ConcurrentTask.expectThrows identity
        , args =
            JE.object
                [ ( "round", JE.int args.round ) ]
        }


{-| Decrypt an armor-stripped age payload (hex) using a `beaconJson` obtained
from `fetchRound`. Pure/offline (no network); the beacon is still verified
locally against the pinned chain info.
-}
decrypt : { ciphertextHex : String, beaconJson : String } -> ConcurrentTask String { plaintextHex : String }
decrypt args =
    ConcurrentTask.define
        { function = "tlock:decrypt"
        , expect =
            ConcurrentTask.expectJson
                (JD.map (\h -> { plaintextHex = h }) (JD.field "plaintextHex" JD.string))
        , errors = ConcurrentTask.expectThrows identity
        , args =
            JE.object
                [ ( "ciphertextHex", JE.string args.ciphertextHex )
                , ( "beaconJson", JE.string args.beaconJson )
                ]
        }
