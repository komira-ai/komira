# =============================================================================
# komira_release_channels — THE CLOSED RELEASE-CHANNEL SET.
#
# A channel is an INDEPENDENTLY RELEASABLE lane of a managed app. A release
# ledger is keyed `(app_id, channel)`, and every read and write takes the
# channel as an argument rather than assuming a constant.
#
#   `gamma` — the operator's OWN lane. A build publishes here FIRST; the
#             operator deploys from it and runs the app's end-to-end
#             validation against it before anything reaches a customer.
#   `live`  — the CUSTOMER lane. A version reaches it ONLY by promotion from
#             `gamma`, by digest, so the digest is preserved and the two
#             ledgers can name the SAME bytes.
#
# `version_ordinal` is a PER-`(app, channel)` sequence — gamma publishes every
# build (1,2,3,4,5), live only the promoted subset (1,2,3), so the SAME digest
# carries different ordinals in the two ledgers. That is self-consistent because
# compliance only ever compares ordinals WITHIN one channel; it is also why every
# read path must take the channel it is measuring in.
#
# ⭐ WHY A LEAF PACKAGE. The deploy tool and the control plane both need these
# names. A leaf package lets them share the channel set without either
# depending on the other. New code imports this package.
#
# ⚠ WHERE A CHANNEL'S IMAGES LIVE IS NOT HERE. The mapping from a channel to
# the operator's own registry belongs to the control plane, which derives it
# FROM `release_channels()`.
# =============================================================================


comptime RELEASE_CHANNEL_LIVE: String = "live"
comptime RELEASE_CHANNEL_GAMMA: String = "gamma"


def release_channels() -> List[String]:
    """THE CLOSED CHANNEL SET, enumerated — the ONE list every channel-shaped
    decision iterates.

    WHY THIS EXISTS RATHER THAN A SECOND `or` CHAIN PER CALLER. A channel set
    readable only as a boolean membership test (`is_valid_channel`) cannot
    answer a question about *all* channels at once — "is this repo one of the
    channels?" — so a caller ends up naming ONE channel it knows about. A build
    guard written that way refuses a build pushing to `live` because `live` is
    the public one, and lets a build pushing to `gamma` through, even though a
    build's bytes are equally unvetted for both. Enumerating the set here makes
    the wide rule structural: adding a third channel adds it to this list, and
    every consumer — the validator, the guard, `is_valid_channel` — widens with
    it.

    ORDER IS THE RELEASE ORDER (gamma first, then live), so an error message
    that lists the channels reads in the order a version travels."""
    var out = List[String]()
    out.append(String(RELEASE_CHANNEL_GAMMA))
    out.append(String(RELEASE_CHANNEL_LIVE))
    return out^


def is_valid_channel(name: String) -> Bool:
    """True iff `name` is a known release channel. The channel set is CLOSED —
    a caller that resolves a channel from config / a request body validates it
    here and FAILS CLOSED on an unknown value. An unrecognized channel must never
    fall back to `live`: that would publish an unvetted build to customers.

    Implemented over `release_channels()` rather than its own `or` chain, so the
    membership test and the enumeration cannot come to different opinions about
    what the channel set is."""
    var chans = release_channels()
    for i in range(len(chans)):
        if chans[i] == name:
            return True
    return False
