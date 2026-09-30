# =============================================================================
# tests/test_run_log_reader.mojo — ★ THE RUN-LOG READ VERB, made falsifiable.
# =============================================================================
#
# ── WHAT THIS FILE GUARDS ────────────────────────────────────────────────────
# A failing validate step should return the relevant logs. The alternative is
# a validator that prints
#
#     Read the run's own log stream (.../runs/{r}/logs?after=&limit=)
#     for the failing stage.
#
# — advice for a route that EXISTS, is asserted served, and that no tool called.
#
# This file pins the three behaviours that make the replacement a tool rather
# than a second way to fail, driving the REAL `fetch_run_log_tail` /
# `parse_run_logs_body` / `render_run_log_tail` over a scripted transport:
#
#   §2  RECORDS PRESENT — they are parsed, PAGED to the end of the cursor, and
#       rendered BOUNDED with the truncation SAID OUT LOUD.
#   §3  RECORDS ABSENT  — an empty stream renders as "NO STAGE RECORDS", never as
#       blank space and never as an error. It is an ANSWER.
#   §4  FETCH FAILS     — a raise, a 4xx and an unparseable 200 each produce a
#       tail carrying `fetch_error`. ⛔ NOTHING RAISES OUT, and ⛔ NO RESPONSE
#       BODY IS EVER ECHOED — the second is asserted against a body containing a
#       live-looking grant token.
#
# §5 pins the ALLOW-LIST (a field nobody listed cannot print itself) and §6 the
# anti-livelock arm (a server that never advances its cursor must not hang the
# caller).
#
# Hermetic: a scripted transport + pure functions. No socket, no cloud, no sleep.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_logs import (
    DEFAULT_RUN_PATH_PREFIX,
    RunLogResponse,
    RunLogTail,
    RunLogTransport,
    build_run_logs_path,
    build_run_logs_query,
    build_run_logs_url,
    build_run_status_path,
    fetch_run_log_tail,
    join_url,
    parse_run_logs_body,
    redact_secretish,
    render_run_log_tail,
)


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


# =============================================================================
# §1 — the scripted transport.
#
# It records every URL it was asked for, so the PAGING assertions are about the
# requests actually issued rather than about the answer alone — a reader that
# returned the right records while never sending an `?after=` would pass a
# content-only assertion and fail the operator on the second page.
# =============================================================================
comptime _MODE_OK: Int = 0
comptime _MODE_RAISE: Int = 1
comptime _MODE_STATUS: Int = 2


struct _ScriptedTransport(RunLogTransport, Movable, Deinitable):
    """Answers each successive `get` from a scripted list of bodies, or fails in
    one of the two ways a real transport fails (a raise / a non-200)."""

    var _bodies: List[String]
    var _mode: Int
    var _status: Int
    var _urls: List[String]
    var _calls: Int

    def __init__(
        out self,
        var bodies: List[String],
        mode: Int = _MODE_OK,
        status: Int = 200,
    ):
        self._bodies = bodies^
        self._mode = mode
        self._status = status
        self._urls = List[String]()
        self._calls = 0

    def calls(self) -> Int:
        return self._calls

    def url(self, i: Int) -> String:
        return self._urls[i].copy()

    def get(mut self, url: String) raises -> RunLogResponse:
        self._urls.append(url.copy())
        self._calls += 1
        if self._mode == _MODE_RAISE:
            raise Error(String("dial failed: connection refused"))
        if self._mode == _MODE_STATUS:
            # ⛔ A BODY WITH A LIVE-LOOKING GRANT TOKEN. §4 asserts it never
            # reaches the render.
            return RunLogResponse.of(
                self._status,
                String('{"access_token":"ya29.SUPERSECRETGRANTVALUE"}'),
            )
        var i = self._calls - 1
        if i >= len(self._bodies):
            i = len(self._bodies) - 1
        return RunLogResponse.of(200, self._bodies[i])


def _bodies(var b: List[String]) -> List[String]:
    return b^


def _one(body: String) -> List[String]:
    var l = List[String]()
    l.append(body.copy())
    return l^


comptime _RUN: String = "0192f8aa-1111-7abc-9def-0123456789ab"


def _line(seq: Int, step: String, msg: String) -> String:
    return (
        String('{"seq":')
        + String(seq)
        + String(',"ts":17892000000000')
        + String(seq)
        + String(',"level":"info","step":"')
        + step
        + String('","message":"')
        + msg
        + String('"}')
    )


def _page(var lines: String, next_cursor: Int, done: Bool) -> String:
    return (
        String('{"run_id":"')
        + _RUN
        + String('","lines":[')
        + lines
        + String('],"next_cursor":')
        + String(next_cursor)
        + String(',"done":')
        + (String("true") if done else String("false"))
        + String("}")
    )


# =============================================================================
# §2 — RECORDS PRESENT: parsed, paged, and BOUNDED.
# =============================================================================
def test_records_present_are_parsed_paged_and_bounded() raises:
    """The happy path, and every part of it that an operator depends on.

    RED WITHOUT THE READER: there is no `fetch_run_log_tail`, so a caller with a
    failing run has a URL and no records."""
    # Page 1: seq 1..3, not done. Page 2: seq 4..5, done.
    var p1 = _page(
        _line(1, String("build"), String("compiling"))
        + String(",")
        + _line(2, String("build"), String("compiled"))
        + String(",")
        + _line(3, String("stage"), String("pushing image")),
        3,
        False,
    )
    var p2 = _page(
        _line(4, String("deploy"), String("applying"))
        + String(",")
        + _line(5, String("deploy"), String("FAILED: quota exceeded")),
        5,
        True,
    )
    var bl = List[String]()
    bl.append(p1)
    bl.append(p2)
    var t = _ScriptedTransport(bl^)
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)

    assert_true(tail.ok(), "a good read must not carry a fetch_error")
    assert_equal(len(tail.records), 5)
    assert_equal(tail.pages, 2)
    assert_equal(tail.next_cursor, 5)
    assert_true(tail.done, "the route said done; the tail must carry it")
    assert_equal(tail.run_id, _RUN)
    assert_equal(tail.records[4].step, String("deploy"))
    assert_equal(tail.records[4].seq, 5)
    assert_true(
        _contains(tail.records[4].message, String("quota exceeded")),
        "the failing stage's own message must survive the parse",
    )

    # ★ THE PAGING IS ASSERTED ON THE REQUESTS, not just the answer. The second
    # GET must carry the FIRST page's cursor, or the tail is only ever one page
    # deep against a real stream.
    assert_equal(t.calls(), 2)
    assert_false(
        _contains(t.url(0), String("after=")),
        "the first page must not send a cursor (0 = from the start)",
    )
    assert_true(
        _contains(t.url(1), String("after=3")),
        "the second page must send the first page's next_cursor",
    )

    # ── THE RENDER IS BOUNDED, AND SAYS WHAT IT CUT ─────────────────────────
    var full = render_run_log_tail(tail, 5, 400)
    assert_true(_contains(full, String("showing 5 record(s)")), full)
    assert_false(
        _contains(full, String("OLDER record(s) omitted")),
        "nothing was omitted; the report must not claim otherwise",
    )
    assert_true(_contains(full, String("[5] info deploy: FAILED")), full)

    var clipped = render_run_log_tail(tail, 2, 400)
    assert_true(_contains(clipped, String("showing 2 record(s)")), clipped)
    assert_true(
        _contains(clipped, String("3 OLDER record(s) omitted")),
        "★ a truncation that is not stated is a truncated log read as a whole"
        " one: " + clipped,
    )
    # The LAST records are the ones kept — a failing stage's output is at the END.
    assert_true(_contains(clipped, String("[5] info deploy: FAILED")), clipped)
    assert_false(_contains(clipped, String("[1] info build")), clipped)

    # Per-message clipping states its own cut.
    var tight = render_run_log_tail(tail, 5, 8)
    assert_true(_contains(tight, String("message clipped:")), tight)


# =============================================================================
# §3 — RECORDS ABSENT: an empty stream is an ANSWER.
# =============================================================================
def test_an_empty_stream_says_no_stage_records() raises:
    """⛔ THE CO-ORDINATION CASE. A producer may write no stage records at all.
    This library is built against the ROUTE CONTRACT, not against what any one
    producer happens to write — so an empty stream must render
    as a sentence, not as blank space and not as a crash."""
    var t = _ScriptedTransport(_one(_page(String(""), 0, False)))
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)

    assert_true(tail.ok(), "an empty stream is a SUCCESS, not a failure")
    assert_true(tail.is_empty(), "and it is empty")
    assert_equal(len(tail.records), 0)
    assert_equal(tail.pages, 1)
    assert_equal(
        t.calls(), 1, "a zero-record page ends the drain — it must not re-poll"
    )

    var out = render_run_log_tail(tail, 40, 400)
    assert_true(_contains(out, String("NO STAGE RECORDS")), out)
    assert_true(_contains(out, _RUN), "it must name the run it read: " + out)
    assert_false(
        _contains(out, String("COULD NOT READ")),
        "★ 'nothing was written' and 'I could not read' are different faults"
        " with different next actions: " + out,
    )


# =============================================================================
# §4 — FETCH FAILS: recorded, never raised, and NEVER echoing the body.
# =============================================================================
def test_a_transport_raise_becomes_a_tail_not_a_raise() raises:
    """⛔ THE ENRICHMENT MUST NOT BECOME THE FAILURE. The caller is already
    reporting something more important."""
    var t = _ScriptedTransport(_one(String("")), _MODE_RAISE)
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)

    assert_false(tail.ok(), "a dial fault must be recorded")
    assert_true(
        _contains(tail.fetch_error, String("transport fault")), tail.fetch_error
    )
    assert_true(
        _contains(tail.fetch_error, String("connection refused")),
        "the transport's own words are the diagnosis: " + tail.fetch_error,
    )
    var out = render_run_log_tail(tail, 40, 400)
    assert_true(_contains(out, String("COULD NOT READ")), out)
    assert_true(
        _contains(out, String("verdict above stands unchanged")),
        "★ the render must say IN BAND that it changed no verdict: " + out,
    )


def test_a_4xx_is_reported_without_echoing_the_body() raises:
    """⛔ NO RESPONSE BODY, EVER. A 4xx on this surface is very often an AUTH
    answer, and auth answers are precisely the bodies that carry material. The
    scripted 403 body here holds a live-SHAPED grant token."""
    var t = _ScriptedTransport(_one(String("")), _MODE_STATUS, 403)
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)

    assert_false(tail.ok())
    assert_true(_contains(tail.fetch_error, String("HTTP 403")), tail.fetch_error)
    assert_true(
        _contains(tail.fetch_error, String("NOT echoed")),
        "the report must SAY it withheld the body: " + tail.fetch_error,
    )
    var out = render_run_log_tail(tail, 40, 400)
    assert_false(
        _contains(out, String("SUPERSECRETGRANTVALUE")),
        "⛔ THE BODY REACHED THE OPERATOR'S TERMINAL: " + out,
    )
    assert_false(_contains(out, String("access_token")), out)


def test_an_unparseable_200_is_reported_without_echoing_the_body() raises:
    """A 200 whose body is not the contract. Same rule: byte counts, not bytes."""
    var t = _ScriptedTransport(
        _one(String('{"run_id":"x","surprise":"ya29.OTHERSECRET"}'))
    )
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)

    assert_false(tail.ok())
    assert_true(
        _contains(tail.fetch_error, String("no `lines` array")), tail.fetch_error
    )
    assert_false(
        _contains(tail.fetch_error, String("OTHERSECRET")),
        "⛔ the unparseable body was echoed: " + tail.fetch_error,
    )


def test_a_cut_short_read_still_shows_what_it_got() raises:
    """A first page that parses and a second that 500s. The records obtained are
    the half that usually explains the failure — they are printed, AND the read
    is reported as partial. Neither half may be silent."""
    var p1 = _page(_line(1, String("build"), String("compiling")), 1, False)
    var bl = List[String]()
    bl.append(p1)
    var t = _ScriptedTransport(bl^)
    # Page 1 parses; the scripted transport then answers the SAME body forever,
    # so drive the partial case directly through the tail value instead.
    var tail = fetch_run_log_tail[_ScriptedTransport](t, String("https://pipeline.example"), _RUN)
    assert_true(tail.ok())
    var partial = tail.copy()
    partial.fetch_error = String("HTTP 503 from /pipelines/runs/x/logs")
    var out = render_run_log_tail(partial, 40, 400)
    assert_true(_contains(out, String("[1] info build: compiling")), out)
    assert_true(_contains(out, String("CUT SHORT")), out)
    assert_true(_contains(out, String("verdict stands unchanged")), out)


# =============================================================================
# §5 — THE ALLOW-LIST, and the redaction under it.
# =============================================================================
def test_a_field_nobody_listed_cannot_print_itself() raises:
    """★ The parse is an ALLOW-LIST over `lines[]` keys. A field an upstream adds
    — here one holding a token — is skipped, so it cannot start appearing in an
    operator's terminal without a deliberate edit to this library."""
    var body = (
        String('{"run_id":"')
        + _RUN
        + String('","lines":[{"seq":1,"ts":1,"level":"info","step":"deploy"')
        + String(',"authorization":"Bearer ya29.LEAKEDFROMANEWFIELD"')
        + String(',"message":"deploy failed"}],"next_cursor":1,"done":true}')
    )
    var tail = parse_run_logs_body(body, _RUN)
    assert_true(tail.ok(), tail.fetch_error)
    assert_equal(len(tail.records), 1)
    assert_equal(tail.records[0].message, String("deploy failed"))
    var out = render_run_log_tail(tail, 40, 400)
    assert_false(
        _contains(out, String("LEAKEDFROMANEWFIELD")),
        "⛔ a non-allow-listed field printed itself: " + out,
    )


def test_a_message_whose_text_looks_like_json_does_not_fool_the_scan() raises:
    """The parse is STRUCTURAL (key/value pairs), not a substring hunt — so a
    message quoting the schema at you is a VALUE and stays one."""
    var body = (
        String('{"run_id":"')
        + _RUN
        + String('","lines":[{"seq":9,"ts":1,"level":"error","step":"deploy"')
        + String(',"message":"upstream said {\\"step\\":\\"build\\"} and died"}]')
        + String(',"next_cursor":9,"done":true}')
    )
    var tail = parse_run_logs_body(body, _RUN)
    assert_true(tail.ok(), tail.fetch_error)
    assert_equal(len(tail.records), 1)
    assert_equal(tail.records[0].step, String("deploy"))
    assert_equal(tail.records[0].seq, 9)
    assert_true(
        _contains(tail.records[0].message, String("and died")),
        tail.records[0].message,
    )


def test_redaction_is_defence_in_depth_over_the_allow_list() raises:
    """A message an upstream writer should never have written. The allow-list is
    the boundary; this is the net under it."""
    var s = redact_secretish(
        String("calling api with Bearer ya29.SECRETVALUE and token=abc123 now")
    )
    assert_false(_contains(s, String("ya29.SECRETVALUE")), s)
    assert_false(_contains(s, String("abc123")), s)
    assert_true(_contains(s, String("[REDACTED]")), s)
    assert_true(
        _contains(s, String("calling api with")),
        "the surrounding diagnostic must survive: " + s,
    )


def test_bug_the_PARSE_does_not_mojibake_a_multibyte_message() raises:
    """⛔ FALSIFIER — the SAME `chr(Int(byte))` defect, one layer EARLIER and on
    the PRIMARY path.

    `_scan_string` is the JSON unescaper every `RunLogRecord` field goes through,
    so a `message` was transcoded on the way IN — already mojibake by the time it
    was stored, before any renderer or redactor could see it.

    A scanner that accumulates `chr(Int(byte))` fails this test: the stored
    `message` becomes `ÃÂ¢ÃÂÃÂ build failed ÃÂ¢ÃÂÃÂ¦` rather than the bytes
    the emitter sent.

    ⚠ THIS IS THE MORE DAMAGING OF THE TWO SITES; the redaction path has its
    own test, and a fix that stops at the first instance of a defect class
    leaves the class live."""
    var msg = String("⛔ build failed — see the ★ stage … now")
    var body = (
        String('{"run_id":"')
        + _RUN
        + String('","lines":[{"seq":4,"ts":1,"level":"error","step":"build"')
        + String(',"message":"')
        + msg
        + String('"}],"next_cursor":4,"done":true}')
    )
    var tail = parse_run_logs_body(body, _RUN)
    assert_true(tail.ok(), tail.fetch_error)
    assert_equal(len(tail.records), 1)
    assert_equal(
        tail.records[0].message,
        msg,
        "a message must survive the JSON scan BYTE FOR BYTE — the scanner"
        " unescapes, it does not transcode",
    )
    # And end to end, through the renderer the operator actually reads.
    assert_true(
        _contains(render_run_log_tail(tail, 40, 400), msg),
        "and it must still be intact after redaction + rendering",
    )


def test_bug_redaction_does_not_mojibake_multibyte_characters() raises:
    """⛔ FALSIFIER — the scrubber must be BYTE-PRESERVING outside the runs it
    redacts.

    THE BUG IT GUARDS: rebuilding the string with `chr(Int(byte))` in `_lower` /
    `_redact_after`. `chr` maps a CODEPOINT to UTF-8, so every raw byte of a
    multi-byte character would be re-encoded as a codepoint of its own — `★`
    (U+2605, `E2 98 85`) would come back as three mojibake characters.
    `render_run_log_tail` puts EVERY run-log message through this function, and
    operator-facing prose is dense with `⛔ ★ — …`.

    FAILS ON THAT BUG: `redact_secretish(String("★"))` would return `Ã¢..`, so
    the equality below would be false.

    ⚠ IT IS SILENT IN THE PLACE THAT MATTERS: the redaction still fires and the
    ASCII around it still reads correctly, so the damage is confined to the
    decorative characters in an operator's terminal during a failed deploy —
    the one output nobody re-reads."""
    # (a) the pure no-op case: nothing to redact, so the input must come back
    #     byte for byte.
    var decorative = String("⛔ step ★ failed — see the run's log … now")
    assert_equal(
        redact_secretish(decorative),
        decorative,
        "a message with NOTHING to redact must be returned unchanged, byte for"
        " byte",
    )

    # (b) and the mixed case: the redaction fires AND the multi-byte text on
    #     either side of it survives intact.
    var mixed = redact_secretish(
        String("⛔ refused — sent Bearer ya29.SECRETVALUE to ★ the edge")
    )
    assert_false(
        _contains(mixed, String("ya29.SECRETVALUE")),
        "CONTROL: the token must still be scrubbed: " + mixed,
    )
    assert_true(
        _contains(mixed, String("⛔ refused — sent Bearer ")),
        "the multi-byte text BEFORE the redaction must survive: " + mixed,
    )
    assert_true(
        _contains(mixed, String(" to ★ the edge")),
        "the multi-byte text AFTER the redaction must survive: " + mixed,
    )


# =============================================================================
# §6 — the shared PATH helpers + anti-livelock.
# =============================================================================
def test_the_shared_path_helpers_compose_the_route() raises:
    """These are the SAME functions every validator and the deploy tool import.
    They live here so no two callers can derive different paths for the same
    run."""
    assert_equal(
        join_url(String("https://pipeline.example/"), String("/pipelines/runs/x")),
        String("https://pipeline.example/pipelines/runs/x"),
    )
    assert_equal(
        build_run_status_path(DEFAULT_RUN_PATH_PREFIX, String("abc")),
        String("/pipelines/runs/abc"),
    )
    assert_equal(
        build_run_logs_path(String("/pipelines/runs"), String("abc")),
        String("/pipelines/runs/abc/logs"),
    )
    assert_equal(build_run_logs_query(0, 0), String(""))
    assert_equal(build_run_logs_query(0, 200), String("?limit=200"))
    assert_equal(build_run_logs_query(7, 200), String("?after=7&limit=200"))
    assert_equal(
        build_run_logs_url(
            String("https://pipeline.example"), DEFAULT_RUN_PATH_PREFIX, String("abc"), 7, 50
        ),
        String("https://pipeline.example/pipelines/runs/abc/logs?after=7&limit=50"),
    )


def test_a_cursor_that_never_advances_cannot_hang_the_caller() raises:
    """★ THE ANTI-LIVELOCK ARM. A peer that keeps answering with records and the
    SAME `next_cursor` would spin a naive cursor loop forever. The drain stops on
    a cursor that did not advance — and this is the arm that makes it safe to
    call this from a failure path that must always return."""
    var stuck = _page(_line(1, String("build"), String("x")), 1, False)
    var t = _ScriptedTransport(_one(stuck))
    var tail = fetch_run_log_tail[_ScriptedTransport](
        t, String("https://pipeline.example"), _RUN, DEFAULT_RUN_PATH_PREFIX, 1
    )
    assert_true(tail.ok(), tail.fetch_error)
    assert_equal(
        t.calls(),
        1,
        "the cursor did not advance past `after=1`; the drain must stop",
    )


def test_a_clip_that_lands_mid_codepoint_does_not_ABORT_the_process() raises:
    """★ A CLIP MID-CODEPOINT MUST NOT ABORT THE PROCESS.

    A `_clip` that truncates with `s[byte=0:max_bytes]` hits that slice's
    ASSERT that its end is a UTF-8 codepoint boundary. Log lines are full of
    multi-byte characters, so a message longer than the ceiling whose boundary
    lands INSIDE one aborts the process:

        Assert Error: String slice ends on, 400 which is not a codepoint
        boundary.  ->  the process dies on signal 4.

    ⛔ WHY THIS IS NOT A COSMETIC BUG. A caller whose ephemeral runner DEPLOYS
    an app and DELETES it at the end can abort between those two, and a killed
    process runs no destructor — so the run leaves a live service behind. A
    render helper takes down the teardown.

    ⚠ IT IS ALSO INTERMITTENT: two executions of the SAME binary differ,
    depending on whether their log messages happen to straddle the ceiling.
    Whether this aborts is a property of the upstream text, not of our code
    path.

    RED ON THAT BUG: this test ABORTS the whole test binary (signal 4), so it
    does not report a failure — it takes every test after it with it."""
    # 5 ASCII bytes then repeated 3-byte characters, so byte 6 is the SECOND byte
    # of a codepoint — the exact shape that aborts.
    var msg = String("xxxxx")
    for _ in range(8):
        msg += String("⛔")
    var bl = List[String]()
    bl.append(_page(_line(1, String("deploy"), msg), 1, True))
    var t = _ScriptedTransport(bl^)
    var tail = fetch_run_log_tail[_ScriptedTransport](
        t, String("https://pipeline.example"), _RUN
    )
    assert_equal(len(tail.records), 1, "the fixture must parse")

    var out = render_run_log_tail(tail, 40, 6)
    assert_true(
        _contains(out, String("message clipped:")),
        "the clip must still STATE that it cut — a silent clip is a truncated"
        " stack trace that reads like a complete one: " + out,
    )
    # ★ IT CLIPS SHORT RATHER THAN MID-CHARACTER: the kept head is the longest
    # whole-codepoint prefix within the ceiling, so the ASCII run survives and no
    # partial character is ever emitted.
    assert_true(
        _contains(out, String("xxxxx")),
        "the whole-codepoint prefix within the ceiling must survive: " + out,
    )
    assert_true(
        _contains(out, String("more byte(s)")),
        "the clip must report how much it cut: " + out,
    )

    # A boundary that is ALREADY legal must be untouched by the repair — the
    # regression direction a naive "always walk back one" would break.
    var ascii_only = List[String]()
    ascii_only.append(
        _page(_line(1, String("deploy"), String("abcdefghij")), 1, True)
    )
    var t2 = _ScriptedTransport(ascii_only^)
    var tail2 = fetch_run_log_tail[_ScriptedTransport](
        t2, String("https://pipeline.example"), _RUN
    )
    var out2 = render_run_log_tail(tail2, 40, 4)
    assert_true(
        _contains(out2, String("abcd")),
        "an ASCII clip at a legal boundary must keep exactly its 4 bytes: "
        + out2,
    )


def main() raises:
    test_records_present_are_parsed_paged_and_bounded()
    test_a_clip_that_lands_mid_codepoint_does_not_ABORT_the_process()
    test_an_empty_stream_says_no_stage_records()
    test_a_transport_raise_becomes_a_tail_not_a_raise()
    test_a_4xx_is_reported_without_echoing_the_body()
    test_an_unparseable_200_is_reported_without_echoing_the_body()
    test_a_cut_short_read_still_shows_what_it_got()
    test_a_field_nobody_listed_cannot_print_itself()
    test_a_message_whose_text_looks_like_json_does_not_fool_the_scan()
    test_redaction_is_defence_in_depth_over_the_allow_list()
    test_bug_the_PARSE_does_not_mojibake_a_multibyte_message()
    test_bug_redaction_does_not_mojibake_multibyte_characters()
    test_the_shared_path_helpers_compose_the_route()
    test_a_cursor_that_never_advances_cannot_hang_the_caller()
    print("PASS test_run_log_reader")
