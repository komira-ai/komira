# =============================================================================
# test_slow_dial_phase_breadcrumb.mojo — the per-PHASE dial instrument fires,
#   does not spam, and is WIRED into both dial sites — including the raise arm.
# =============================================================================
#
# ⛔ THE SUBJECT IS A MEASUREMENT, NOT A BOUND, AND THIS FILE DOES NOT PRETEND
# OTHERWISE. Nothing here asserts that a dial is bounded, because after this
# change it still is not: `getaddrinfo(3)` is a blocking libc call with no
# timeout argument and no cancellation. What this gate holds is that a
# wedged process will SAY which phase ate the wall.
#
# ── THE FAILURE THIS SERVES ─────────────────────────────────────────────────
# A service that crash-loops on its startup probe can have each loop "closed"
# by tightening a budget while the wedge moves one call to the right, because
# every one of those budgets binds the DRIVE phase. One outbound call has four phases; the authored
# `request_timeout_us` reaches exactly one:
#
#     DNS getaddrinfo  NOTHING | TCP connect 5s | TLS handshake 30s | drive min(authored,120s)
#
# Connect RAISES at 5s, the handshake RAISES at 30s, the drive RAISES at the
# authored budget — so DNS is the only phase that can absorb a 180s startup
# probe without raising. That elimination is a DEDUCTION; the subject turns it
# into a printed fact.
#
# ── WHY THE EMIT DECISION IS A `Bool`, NOT A STDOUT CAPTURE ─────────────────
# `note_slow_phase` returns whether it emitted, so BOTH directions are
# assertable in-process: the FLOOR (below threshold ⇒ silent — an unconditional
# per-dial line in a 5s serve loop is its own incident) and the CEILING (at and
# above ⇒ it fires). A gate that only asserted the floor would pass on an
# instrument that never fires at all, which is the same shape as the
# terminates-instantly bug a connector wall-clock test has to exclude.
#
# ── WHY GATES 5 AND 6 READ SOURCE TEXT ──────────────────────────────────────
# The two call sites CANNOT be exercised hermetically. The DNS one is a live
# `getaddrinfo` — kept out of a hermetic gate for this exact reason — and the
# TLS one needs a real handshake against a real peer.
#
# ⚠ AND THEY READ CODE, NOT PROSE. The subject files explain this very change
# in comment blocks that name `note_slow_phase` several times; a bare substring
# scan would be satisfied by the EXPLANATION. Comments are cut at the first `#`
# and `"""`-delimited docstrings contribute nothing. Gate 7 pins the reader
# against a file whose only occurrences are in prose.
#
# HERMETIC: pure arithmetic plus two text reads of checked-in
# files declared as test data. No socket, no resolver, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.slow_phase import (
    SLOW_PHASE_DNS,
    SLOW_PHASE_THRESHOLD_MS,
    SLOW_PHASE_TLS_HANDSHAKE,
    elapsed_ms_since,
    note_slow_phase,
    slow_phase_line,
)
from komira_http.client.client import _ip_be_from_host


comptime _CLIENT_SRC: String = "src/komira_http/client/client.mojo"
comptime _TLS_SRC: String = "src/komira_http/client/tls_connector.mojo"
comptime _SELF_SRC: String = (
    "src/komira_http/tests/test_slow_dial_phase_breadcrumb.mojo"
)

comptime _EMIT: String = "note_slow_phase("


# =============================================================================
# The reader — code-only source text.
# =============================================================================
def _count(haystack: String, needle: String) -> Int:
    """Non-overlapping occurrences of `needle` in `haystack`."""
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return 0
    var seen = 0
    var i = 0
    while i + len(n) <= len(h):
        var ok = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                ok = False
                break
        if ok:
            seen += 1
            i += len(n)
        else:
            i += 1
    return seen


def _cut_trailing_comment(line: String) raises -> String:
    """Everything before the first `#`.

    ⚠ NOT quote-aware, and it does not need to be — but say why. A `#` inside a
    string literal is cut as though it opened a comment; the error direction is
    the safe one, because cutting EARLY can only DROP text and every assertion
    that text feeds is a POSITIVE one. An offender cannot hide behind it: code
    precedes its own trailing comment."""
    var parts = line.split(String("#"))
    return String(parts[0])


def _code_text(text: String) raises -> String:
    """`text` with comment tails and `\"\"\"`-delimited docstrings removed."""
    var rows = text.split(String("\n"))
    var out = String("")
    var in_doc = False
    for i in range(len(rows)):
        var raw = String(rows[i])
        var triples = _count(raw, String('"""'))
        if in_doc:
            if triples > 0 and triples % 2 == 1:
                in_doc = False
            continue
        if triples > 0:
            if triples % 2 == 1:
                in_doc = True
            continue
        out += _cut_trailing_comment(raw) + String("\n")
    return out^


def _read_source(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


# =============================================================================
# Gate 1 ★ — the FLOOR. Below the threshold the instrument is SILENT.
# =============================================================================
def test_below_threshold_is_silent() raises:
    print("-- test_below_threshold_is_silent --")
    assert_false(
        note_slow_phase(SLOW_PHASE_DNS, String("h"), Int64(0)),
        (
            "a 0ms phase emitted a breadcrumb. These two call sites are in the"
            " closure of essentially every binary in the tree, including serve"
            " loops that dial on a 5s tick; an unconditional per-dial line is"
            " its own incident."
        ),
    )
    assert_false(
        note_slow_phase(
            SLOW_PHASE_TLS_HANDSHAKE,
            String("h"),
            SLOW_PHASE_THRESHOLD_MS - Int64(1),
        ),
        (
            "a phase one millisecond UNDER the threshold emitted. The"
            " comparison is `>=` on the threshold, so threshold-1 is silent."
        ),
    )
    print("    [OK] silent at 0ms and at threshold-1")


# =============================================================================
# Gate 2 ★ — the CEILING. At and above the threshold it FIRES.
# =============================================================================
def test_at_and_above_threshold_fires() raises:
    print("-- test_at_and_above_threshold_fires --")
    assert_true(
        note_slow_phase(
            SLOW_PHASE_DNS, String("oauth2.googleapis.com"),
            SLOW_PHASE_THRESHOLD_MS,
        ),
        (
            "a phase landing EXACTLY on the threshold did not emit. An"
            " instrument that never fires passes every no-spam assertion and"
            " reports nothing when the wedge recurs — that is the failure this"
            " gate exists to exclude."
        ),
    )
    assert_true(
        note_slow_phase(
            SLOW_PHASE_DNS, String("oauth2.googleapis.com"), Int64(31_004)
        ),
        "a 31-second DNS resolve — the whole point of the change — was silent.",
    )
    print("    [OK] fires at threshold and at 31s")


# =============================================================================
# Gate 3 ★ — ONE wire format, and the two phases are DISTINGUISHABLE.
# =============================================================================
def test_line_format_is_scrapeable() raises:
    print("-- test_line_format_is_scrapeable --")
    var line = slow_phase_line(
        SLOW_PHASE_DNS, String("oauth2.googleapis.com"), Int64(31_004)
    )
    assert_equal(
        line,
        String("SLOW DIAL phase=dns host=oauth2.googleapis.com ms=31004"),
        (
            "the breadcrumb's wire format changed. It is scraped out of Cloud"
            " Run logs by hand during an outage; if you change it, change it"
            " deliberately and update this literal."
        ),
    )
    var tls = slow_phase_line(
        SLOW_PHASE_TLS_HANDSHAKE, String("run.googleapis.com"), Int64(1_500)
    )
    assert_equal(
        tls,
        String("SLOW DIAL phase=tls-handshake host=run.googleapis.com ms=1500"),
    )
    assert_true(
        SLOW_PHASE_DNS != SLOW_PHASE_TLS_HANDSHAKE,
        (
            "the two phase tags are the same string, so a log line cannot say"
            " WHICH phase was slow — which is the entire question."
        ),
    )
    print("    [OK] " + line)


# =============================================================================
# Gate 4 ★ — the elapsed arithmetic, including a clock that goes BACKWARDS.
# =============================================================================
def test_elapsed_ms_arithmetic() raises:
    print("-- test_elapsed_ms_arithmetic --")
    assert_equal(
        elapsed_ms_since(Int64(0), Int64(1_000_000)), Int64(1),
        "1e6 ns is one millisecond.",
    )
    assert_equal(
        elapsed_ms_since(Int64(5_000_000), Int64(31_004_999_999)),
        Int64(30_999),
        "sub-millisecond remainder truncates; it does not round or overflow.",
    )
    assert_equal(
        elapsed_ms_since(Int64(999_999), Int64(1_000_000)), Int64(0),
        "a sub-millisecond phase is 0ms, not 1ms.",
    )
    # ⭐ THE CLAMP. `now_ns` is CLOCK_MONOTONIC / CLOCK_UPTIME_RAW so this
    # should not happen — but the two reads are taken at different call sites
    # and an unsigned wrap would turn a small negative into a giant positive,
    # i.e. a fabricated "SLOW DIAL ms=18446744073709" in the middle of an
    # outage. The clamp makes that unreachable.
    assert_equal(
        elapsed_ms_since(Int64(2_000_000_000), Int64(1_000_000_000)),
        Int64(0),
        (
            "a backwards clock produced a nonzero elapsed. A fabricated giant"
            " duration during an outage is worse than no instrument."
        ),
    )
    print("    [OK] exact, truncating, and clamped")


# =============================================================================
# Gate 5 ★★ — WIRING: the DNS site reports on BOTH arms, success AND raise.
# =============================================================================
def test_dns_site_is_wired_on_both_arms() raises:
    print("-- test_dns_site_is_wired_on_both_arms --")
    var code = _code_text(_read_source(_CLIENT_SRC))
    var emits = _count(code, _EMIT)
    assert_true(
        emits >= 2,
        (
            String("`_ip_be_from_host` must report the DNS phase on BOTH arms")
            + String(" — the resolve that SUCCEEDS slowly and the one that")
            + String(" RAISES slowly. A 30s NXDOMAIN is wedge evidence too, and")
            + String(" it is invisible if the breadcrumb is conditional on")
            + String(" success. Found ")
            + String(emits)
            + String(" call(s) to `")
            + _EMIT
            + String("` in the CODE of ")
            + _CLIENT_SRC
            + String(" (comments and docstrings excluded).")
        ),
    )
    assert_true(
        code.find(String("raise resolve_err")) >= 0,
        (
            "the DNS breadcrumb's `except` arm no longer RE-RAISES. Swallowing"
            " a resolve failure to emit a breadcrumb turns an instrument into a"
            " correctness defect: every caller would see a bogus ip_be of 0."
        ),
    )
    print("    [OK] " + String(emits) + " emit site(s) + the re-raise")


# =============================================================================
# Gate 6 ★★ — WIRING: the TLS handshake's SUCCESS arm reports.
# =============================================================================
def test_tls_handshake_done_arm_is_wired() raises:
    print("-- test_tls_handshake_done_arm_is_wired --")
    var code = _code_text(_read_source(_TLS_SRC))
    var emits = _count(code, _EMIT)
    assert_true(
        emits >= 1,
        (
            String("the TLS handshake's DONE arm does not report its wall.")
            + String(" The GIVE-UP arm already carries `elapsed_ms` inside")
            + String(" `_handshake_deadline_error`; the arm that COMPLETES was")
            + String(" the dark one, so a handshake finishing after 28 seconds")
            + String(" was indistinguishable from one finishing in 30ms.")
            + String(" Found ")
            + String(emits)
            + String(" in the CODE of ")
            + _TLS_SRC
        ),
    )
    print("    [OK] " + String(emits) + " emit site(s) in the DONE arm")


# =============================================================================
# Gate 7 ★★ — THE READER READS CODE, NOT PROSE.
# =============================================================================
def test_the_reader_reads_code_and_not_prose() raises:
    print("-- test_the_reader_reads_code_and_not_prose --")
    # This file's own header NAMES `note_slow_phase(` in prose several times and
    # its helpers' docstrings do too. If the reader counted prose, gates 5 and 6
    # would be satisfiable by a comment — so assert on a subject whose ONLY
    # occurrences are in comments and docstrings, and require ZERO.
    #
    # ⚠ THE SENTINEL IS ASSEMBLED FROM TWO HALVES AT RUNTIME, DELIBERATELY. A
    # literal `String("PROSE_ONLY" "_SENTINEL")` spelled whole would itself be
    # CODE, so the joined token would appear in the code text and the zero
    # assertion below could never hold — the gate would be red for a reason
    # that has nothing to do with the reader. Split, it occurs whole ONLY in
    # this file's prose.
    var raw = _read_source(_SELF_SRC)
    var sentinel = String("PROSE_ONLY") + String("_SENTINEL")
    assert_true(
        _count(raw, sentinel) >= 2,
        (
            "the sentinel this gate needs is not in this file's prose any more."
            " Gate 7 is then vacuous — it would pass over a reader that counts"
            " comments. Restore the two prose mentions below."
        ),
    )
    # PROSE_ONLY_SENTINEL appears here in a comment and in the docstring below,
    # and NOWHERE in this file's code.
    assert_equal(
        _count(_code_text(raw), sentinel),
        0,
        (
            "the reader counted a token that occurs ONLY in comments and"
            " docstrings. Gates 5 and 6 are then satisfiable by an explanation"
            " instead of a call, which is exactly how a text gate quietly stops"
            " measuring — the subject files explain this change in comment"
            " blocks that name the emitter several times."
        ),
    )
    print("    [OK] comments and docstrings contribute nothing")


def _prose_only_docstring_probe() -> Int:
    """PROSE_ONLY_SENTINEL lives in this docstring so gate 7 covers the
    docstring arm of the reader as well as the comment arm."""
    return 0


# =============================================================================
# Gate 8 ★ — the IP-LITERAL fast path is UNPERTURBED and still never resolves.
# =============================================================================
def test_ip_literal_fast_path_unperturbed() raises:
    print("-- test_ip_literal_fast_path_unperturbed --")
    # The instrument was added INSIDE the DNS fallback, strictly after the
    # literal fast path returns — so a literal must still cost no resolver call
    # and no breadcrumb. Values are the little-endian view of the octets, the
    # same convention `_ip_be_from_host`'s own docstring states.
    assert_equal(
        _ip_be_from_host(String("127.0.0.1"), UInt16(443)),
        UInt32(0x0100007F),
        "the dotted-quad literal fast path changed behaviour.",
    )
    assert_equal(
        _ip_be_from_host(String("localhost"), UInt16(443)),
        UInt32(0x0100007F),
        "the `localhost` alias fast path changed behaviour.",
    )
    var raised = False
    try:
        var _bad = _ip_be_from_host(String("999.1.1.1"), UInt16(443))
    except:
        raised = True
    assert_true(
        raised,
        (
            "a MALFORMED literal stopped raising. The instrument's try/except"
            " wraps only the resolve; a malformed literal is classified BEFORE"
            " it and must still raise rather than fall through to getaddrinfo."
        ),
    )
    print("    [OK] literal fast path intact, malformed literal still raises")


def main() raises:
    print("test_slow_dial_phase_breadcrumb")
    test_below_threshold_is_silent()
    test_at_and_above_threshold_fires()
    test_line_format_is_scrapeable()
    test_elapsed_ms_arithmetic()
    test_dns_site_is_wired_on_both_arms()
    test_tls_handshake_done_arm_is_wired()
    test_the_reader_reads_code_and_not_prose()
    test_ip_literal_fast_path_unperturbed()
    print("test_slow_dial_phase_breadcrumb: ALL PASS")
