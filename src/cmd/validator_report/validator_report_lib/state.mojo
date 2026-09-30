# =============================================================================
# validator_report_lib/state.mojo — ★ THE CLOSED ROW-STATE VOCABULARY, and the
#   closed VERSION-SOURCE vocabulary a target's digest is labelled with.
# =============================================================================
#
# ⛔ THIS RECORD IS EVIDENCE, NOT AUTHORIZATION. NOTHING MAY GATE ON IT.
#
# It is written by the party being gated, into a bucket that party can write.
# A stricter reader of a file the gated party writes is a formality, not evidence.
#
# The gate stays where it already is, in the two places the judged run cannot
# write:
#   * the EXIT CODE of the validate DAG, and
#   * the BUILD GRAPH (a test's pass marker is an INPUT to the artifact).
# A promotion gate between environments keys on DIGEST IDENTITY read from both
# environments' own ledgers. It does not read this record and must never learn to.
#
# ⚠ AND THE INVERSION IS THE ONE TO WATCH FOR. This record is strictly MORE
# citable than a gate's stdout, so a durable, queryable, per-target record is
# exactly what somebody will reach for when they want a green light cheaply.
# EVERY field here answers "what did this run OBSERVE". NO field answers "may this
# PROCEED". If you are adding one, you are rebuilding a self-attested pass file
# with better formatting.
#
# ── WHY A FIVE-STATE ENUM AND NOT A `Bool` ───────────────────────────────────
# A row model with `passed: Bool` plus one typed abstention smuggled in as a
# sentinel can only encode three further states in PROSE, recoverable only by
# string-match:
#   * NOT REACHED — `passed=False` with a `"NOT REACHED: "` detail PREFIX. The
#     verdict is right; the REASON is only a substring.
#   * UNREADABLE — "I could not observe the subject" has nowhere to go but
#     `passed`, so a probe without read access manufactures greens for checks
#     that never ran.
#   * NOT RUN — a typed abstention, and typing it here is what keeps the
#     denominator honest.
#
# ⛔ PROMOTING `NOT REACHED` TO A STATE CHANGES NO VERDICT. It stays RED: a row
# that meant to claim and counted as a pass is a vacuous gate. Only the reason
# becomes queryable. That is the whole change.
#
# ⛔ `TIMED_OUT` AND `SKIPPED_BY_REQUEST` ARE DELIBERATELY NOT ROW STATES. They
# are STEP-altitude facts the validate DAG owns (`STEP_PASS/FAIL/SKIPPED`), and a
# validator cannot observe either — a process that was killed writes nothing, and
# a step nobody selected never started. Putting them on the row would let a
# validator claim knowledge it does not have.
#
# NO deps, by construction — pure `String` / `Int` work. Same discipline as
# `validator_rows_lib` and `validator_target_lib`: every validator can take this
# dep for one line without dragging a closure in.
#
# def-based, Mojo 1.0.0b2.
# =============================================================================


# =============================================================================
# §1 — the ROW state vocabulary. CLOSED: `row_state_token` maps anything else to
#      the fail-closed word, never to a pass.
# =============================================================================
comptime ROW_PASSED: Int = 0
"""Ran; the property held."""

comptime ROW_FAILED: Int = 1
"""Ran; the property did not hold."""

comptime ROW_NOT_RUN: Int = 2
"""This leg's contract says the row does not run. It asserts NOTHING and leaves
BOTH sides of the ratio — numerator AND denominator. A leg made ENTIRELY of these
cannot pass at all."""

comptime ROW_NOT_REACHED: Int = 3
"""The row WAS going to claim, and an earlier failure in this leg prevented it.
⛔ COUNTS AS A FAILURE. It is NOT an abstention: the difference between "this leg
does not assert X" and "this leg meant to assert X and could not" is the
difference between a contract and an outage."""

comptime ROW_UNREADABLE: Int = 4
"""The SUBJECT could not be observed — no credential, no permission, the API
refused the read. Neither a pass nor a failure: a RUN-LEVEL fault (exit 3),
because a run that cannot say what it observed cannot support ANY claim about the
deployment, including a negative one."""


def row_state_token(state: Int) -> String:
    """The stable wire token for a row state.

    ⛔ FAIL-CLOSED on an unknown ordinal: an ordinal this vocabulary does not
    know renders `UNREADABLE`, never `PASSED`. A record that invents a pass for a
    value it cannot interpret is the fail-quiet shape this whole system exists to
    delete."""
    if state == ROW_PASSED:
        return String("PASSED")
    if state == ROW_FAILED:
        return String("FAILED")
    if state == ROW_NOT_RUN:
        return String("NOT_RUN")
    if state == ROW_NOT_REACHED:
        return String("NOT_REACHED")
    return String("UNREADABLE")


def row_state_is_known(state: Int) -> Bool:
    """True iff `state` is a member of the closed vocabulary. A caller that wants
    to REFUSE an out-of-band ordinal (rather than accept the fail-closed render)
    asks this."""
    return state >= ROW_PASSED and state <= ROW_UNREADABLE


# =============================================================================
# §2 — the VERSION-SOURCE vocabulary. A staged-image ledger can diverge from
#      what is SERVING, in both the repository and the digest.
# =============================================================================
#
# ⇒ `version` ALONE CANNOT ANSWER "what did I validate". The label is REQUIRED,
# and `VERSION_SOURCE_STAGED_LEDGER` may never be presented as the answer on its
# own. This is also why several services running ONE logical image at different
# digests makes per-STEP target attribution the only way to say anything true.

comptime VERSION_SOURCE_LIVE_SERVING: String = "LIVE_SERVING"
"""Read from the target's SERVING container image at validate time. The only
source that answers "what did I validate"."""

comptime VERSION_SOURCE_AUTHORED_MANIFEST: String = "AUTHORED_MANIFEST"
"""The digest this deploy PINNED, from the post-route manifest. Free on
`deploy-and-validate`, zero cloud calls — and a DIFFERENT claim from what is
serving."""

comptime VERSION_SOURCE_STAGED_LEDGER: String = "STAGED_LEDGER"
"""One GET on `staged-image/<app>`. ⛔ IT CAN DIVERGE FROM WHAT IS SERVING (see
above). Carry it only as a separately-labelled second
field, NEVER as `version` alone."""

comptime VERSION_SOURCE_NONE: String = "NONE"
"""There is no digest to name, and `version_note` must say WHY. The live case is
`APP_KIND_SHARED_INFRASTRUCTURE`: it composes no `-svc` node and serves nothing,
yet a validate step can name it. A digest-shaped field is simply WRONG for it,
and an empty string in a digest column reads as "we did not look"."""


def version_source_is_known(source: String) -> Bool:
    """True iff `source` is a member of the closed vocabulary."""
    return (
        source == VERSION_SOURCE_LIVE_SERVING
        or source == VERSION_SOURCE_AUTHORED_MANIFEST
        or source == VERSION_SOURCE_STAGED_LEDGER
        or source == VERSION_SOURCE_NONE
    )


# =============================================================================
# §3 — the TARGET KIND vocabulary. Open on purpose (a new deploy shape must not
#      have to edit this leaf), but the four common ones are named so a reader is
#      not guessing at a free-text column.
# =============================================================================
comptime TARGET_KIND_SERVICE: String = "service"
comptime TARGET_KIND_WEB_CONTENT: String = "web_content"
comptime TARGET_KIND_PROBE: String = "probe"
comptime TARGET_KIND_SHARED_INFRASTRUCTURE: String = "shared_infrastructure"


# =============================================================================
# §4 — the RUN-LEVEL exit codes this library derives. Three-valued, and the
#      precedence is load-bearing.
# =============================================================================
comptime REPORT_EXIT_OK: Int32 = 0
comptime REPORT_EXIT_FAILED: Int32 = 1
comptime REPORT_EXIT_CENSUS_FAULT: Int32 = 3
"""★ A CENSUS FAULT OUTRANKS A FAILED GATE. A run that cannot say WHAT IT RAN
cannot support any claim about the deployment — including a negative one. It is a
distinct code from 1 for the same reason a test runner distinguishes
"accounting violated" (3) from "a test failed" (1)."""
