# =============================================================================
# kci_logs/tests/test_scripted_log_double.mojo — the two halves of the
#   `ScriptedCloudLogSource` test double that no other test reaches:
#   `share()` and `script_page`.
# =============================================================================
#
#   D1  `share()` gives a SECOND handle over ONE state: after the first handle
#       is moved away (as a validator takes its log source by value), the
#       second still sees every read the moved one served, and a script added
#       through the second answers a read through the moved one.
#   D2  `script_page` hands a scripted FAILED page back verbatim: status,
#       fault, page count, settles and continuation token, and the adapter
#       turns it into a `fetch_error`, not an empty stream.
#   D3  `script_page` keys its page by handle among other scripts: a read of
#       one handle never answers with a neighbour's page, and the fetch bound
#       keeps the LAST entries of a scripted page.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_logs import (
    CloudLogEntry,
    CloudLogPage,
    ScriptedCloudLogSource,
    cloud_log_page_to_run_log_tail,
)


def _entry(text: String) -> CloudLogEntry:
    return CloudLogEntry(String("t"), String("INFO"), text.copy())


def _take(var src: ScriptedCloudLogSource) raises -> Int:
    """Stands in for a subject that takes its log source by value: reads
    through the moved handle and returns how many entries it got."""
    var page = src.read_container_output(String("exec/moved"), 10)
    return len(page.entries)


def test_share_reads_the_aggregate_after_a_move() raises:
    var src = ScriptedCloudLogSource()
    var view = src.share()
    assert_equal(view.call_count(), 0, "no read yet")
    # A script added through the SECOND handle answers the first one.
    var lines = List[String]()
    lines.append(String("one"))
    lines.append(String("two"))
    view.script_text(String("exec/moved"), lines)
    assert_equal(_take(src^), 2, "the moved handle read the shared script")
    assert_equal(view.call_count(), 1, "the read is visible after the move")
    assert_equal(view.last_handle(), String("exec/moved"))
    # A share of a share is still the same state.
    var again = view.share()
    _ = again.read_container_output(String("exec/other"), 10)
    assert_equal(view.call_count(), 2, "a share of a share counts too")
    assert_equal(view.last_handle(), String("exec/other"))


def test_script_page_returns_a_failed_page_verbatim() raises:
    var src = ScriptedCloudLogSource()
    var failed = CloudLogPage.failed(403, String("HTTP 403 from the provider"))
    failed.next_token = String("tok-7")
    failed.pages = 3
    failed.settles = 2
    src.script_page(String("exec/f"), failed^)
    var page = src.read_container_output(String("exec/f"), 10)
    assert_false(page.ok(), "a scripted failure is not an answer")
    assert_equal(page.status, 403)
    assert_equal(page.fault, String("HTTP 403 from the provider"))
    assert_equal(page.next_token, String("tok-7"))
    assert_equal(page.pages, 3)
    assert_equal(page.settles, 2)
    var tail = cloud_log_page_to_run_log_tail(page, String("exec/f"))
    assert_equal(tail.fetch_error, String("HTTP 403 from the provider"))
    assert_false(tail.done, "a failed read is never complete")
    assert_equal(src.call_count(), 1)


def test_script_page_is_keyed_by_handle_and_bounded() raises:
    var src = ScriptedCloudLogSource()
    var lines = List[String]()
    lines.append(String("text-a"))
    src.script_text(String("exec/a"), lines)
    var entries = List[CloudLogEntry]()
    for i in range(5):
        entries.append(_entry(String("b") + String(i)))
    src.script_page(
        String("exec/b"),
        CloudLogPage(entries^, 200, String(""), String(""), 1, 0),
    )
    src.script_page(
        String("exec/c"), CloudLogPage.failed(0, String("dial refused"))
    )
    var b = src.read_container_output(String("exec/b"), 2)
    assert_true(b.ok(), "exec/b is an answer")
    assert_equal(len(b.entries), 2, "bounded to 2")
    assert_equal(b.entries[0].text, String("b3"), "the last two, oldest first")
    assert_equal(b.entries[1].text, String("b4"))
    var a = src.read_container_output(String("exec/a"), 10)
    assert_equal(len(a.entries), 1, "exec/a answers with its own script")
    assert_equal(a.entries[0].text, String("text-a"))
    var c = src.read_container_output(String("exec/c"), 10)
    assert_false(c.ok(), "exec/c answers with its own failed page")
    assert_equal(c.fault, String("dial refused"))
    assert_equal(c.pages, 0, "a refusal that never dialled read no page")
    assert_false(
        cloud_log_page_to_run_log_tail(c, String("exec/c")).done,
        "a failed read with no continuation token is still not complete",
    )


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_share_reads_the_aggregate_after_a_move", test_share_reads_the_aggregate_after_a_move, failed)
    _run("test_script_page_returns_a_failed_page_verbatim", test_script_page_returns_a_failed_page_verbatim, failed)
    _run("test_script_page_is_keyed_by_handle_and_bounded", test_script_page_is_keyed_by_handle_and_bounded, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_scripted_log_double: ALL 3 CASES PASS")
