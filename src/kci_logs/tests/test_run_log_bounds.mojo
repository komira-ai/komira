# =============================================================================
# kci_logs/tests/test_run_log_bounds.mojo — the bounds a run-log read and its
#   render apply, and the edges of the path and clip helpers.
# =============================================================================
#
#   B1  `keep_last` (the MEMORY bound) keeps the LAST N records across pages
#       and counts what it dropped, and the render says how many it omitted.
#   B2  the page ceiling: a stream that keeps advancing stops after
#       `max_pages` reads and SAYS it stopped, with the cursor to resume from.
#   B3  `join_url` / `build_run_status_path` edges: empty base, empty path, a
#       path with no leading `/`, an empty prefix (the default `/runs/`), and
#       a prefix with no trailing `/`.
#   B4  `utf8_clip_end` edges: a ceiling at or past the end, zero and negative
#       ceilings, and a ceiling inside a 2-byte character.
#   B5  the quoted redaction shape `"token":"<run>"` stops at the closing
#       quote, so the JSON around it survives.
#   B6  the next-action sentence is EMPTY for the stage stream (it names a
#       container remedy) and non-empty for the container stream.
#   B7  `ScriptedCloudLogSource.last_handle` is EMPTY before any read and
#       names the read handle after one.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_logs import (
    RUN_LOG_STREAM_CONTAINER_STDOUT,
    RunLogResponse,
    RunLogTail,
    RunLogTransport,
    ScriptedCloudLogSource,
    build_run_status_path,
    fetch_run_log_tail,
    join_url,
    redact_secretish,
    render_run_log_tail,
    utf8_clip_end,
)
from kci_logs.run_log_tail import _next_action_sentence


comptime _RUN: String = "01a1c0de-2222-7abc-9def-0123456789ab"


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _line(seq: Int) -> String:
    return (
        String('{"seq":')
        + String(seq)
        + String(',"level":"info","step":"s","message":"m')
        + String(seq)
        + String('"}')
    )


struct _PagedTransport(RunLogTransport, Movable, Deinitable):
    """Page `k` (1-based) holds records `2k-1` and `2k`, cursor `2k`; the page
    numbered `last` says `done`. `last <= 0` never ends."""

    var _calls: Int
    var _last: Int

    def __init__(out self, last: Int):
        self._calls = 0
        self._last = last

    def calls(self) -> Int:
        return self._calls

    def get(mut self, url: String) raises -> RunLogResponse:
        self._calls += 1
        var k = self._calls
        var done = self._last > 0 and k >= self._last
        return RunLogResponse.of(
            200,
            String('{"run_id":"')
            + _RUN
            + String('","lines":[')
            + _line(2 * k - 1)
            + String(",")
            + _line(2 * k)
            + String('],"next_cursor":')
            + String(2 * k)
            + String(',"done":')
            + (String("true") if done else String("false"))
            + String("}"),
        )


def test_keep_last_drops_the_oldest_and_says_so() raises:
    var t = _PagedTransport(2)
    var tail = fetch_run_log_tail[_PagedTransport](
        t, String("https://runs.example"), _RUN, keep_last=3
    )
    assert_true(tail.ok(), tail.fetch_error)
    assert_equal(t.calls(), 2)
    assert_equal(len(tail.records), 3, "only the last 3 are held")
    assert_equal(tail.records[0].seq, 2, "the OLDEST was dropped, not the newest")
    assert_equal(tail.records[2].seq, 4)
    assert_equal(tail.dropped_older, 1)
    var out = render_run_log_tail(tail)
    assert_true(
        _contains(out, String("the LAST of 4 read; 1 OLDER record(s) omitted")),
        out,
    )


def test_the_page_ceiling_stops_and_says_where() raises:
    var t = _PagedTransport(0)
    var tail = fetch_run_log_tail[_PagedTransport](
        t, String("https://runs.example"), _RUN, max_pages=2
    )
    assert_equal(t.calls(), 2, "exactly the ceiling, never one more")
    assert_equal(tail.pages, 2)
    assert_equal(len(tail.records), 4, "what was read is kept")
    assert_false(tail.ok(), "a ceiling stop is not a complete read")
    assert_equal(
        tail.fetch_error,
        String(
            "stopped after the 2-page ceiling with the stream still advancing"
            " (cursor at 4); re-read from `--after 4` for the rest"
        ),
    )


def test_path_helper_edges() raises:
    assert_equal(join_url(String(""), String("/runs/x")), String("/runs/x"))
    assert_equal(join_url(String("https://a.test//"), String("")), String("https://a.test"))
    assert_equal(
        join_url(String("https://a.test"), String("runs/x")), String("https://a.test/runs/x")
    )
    assert_equal(build_run_status_path(String(""), String("id")), String("/runs/id"))
    assert_equal(build_run_status_path(String("/r"), String("id")), String("/r/id"))


def test_clip_end_edges() raises:
    assert_equal(utf8_clip_end(String("abc"), 3), 3, "at the end")
    assert_equal(utf8_clip_end(String("abc"), 9), 3, "past the end")
    assert_equal(utf8_clip_end(String("abc"), 0), 0, "zero")
    assert_equal(utf8_clip_end(String("abc"), -2), 0, "negative")
    assert_equal(utf8_clip_end(String("aé"), 2), 1, "inside a 2-byte char")


def test_quoted_token_redaction_stops_at_the_quote() raises:
    assert_equal(
        redact_secretish(String('{"token":"abc123","x":1}')),
        String('{"token":"[REDACTED]","x":1}'),
    )


def test_next_action_sentence_is_container_only() raises:
    var stage = RunLogTail.empty()
    assert_equal(_next_action_sentence(stage), String(""), "stage stream")
    var container = RunLogTail.empty()
    container.stream_kind = RUN_LOG_STREAM_CONTAINER_STDOUT
    assert_true(
        _next_action_sentence(container).byte_length() > 0, "container stream"
    )


def test_last_handle_before_and_after_a_read() raises:
    var src = ScriptedCloudLogSource()
    assert_equal(src.last_handle(), String(""), "no read yet")
    var lines = List[String]()
    lines.append(String("x"))
    src.script_text(String("exec/1"), lines)
    _ = src.read_container_output(String("exec/1"), 10)
    assert_equal(src.last_handle(), String("exec/1"))


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_keep_last_drops_the_oldest_and_says_so", test_keep_last_drops_the_oldest_and_says_so, failed)
    _run("test_the_page_ceiling_stops_and_says_where", test_the_page_ceiling_stops_and_says_where, failed)
    _run("test_path_helper_edges", test_path_helper_edges, failed)
    _run("test_clip_end_edges", test_clip_end_edges, failed)
    _run("test_quoted_token_redaction_stops_at_the_quote", test_quoted_token_redaction_stops_at_the_quote, failed)
    _run("test_next_action_sentence_is_container_only", test_next_action_sentence_is_container_only, failed)
    _run("test_last_handle_before_and_after_a_read", test_last_handle_before_and_after_a_read, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_run_log_bounds: ALL 7 CASES PASS")
