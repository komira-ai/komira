# The session over real pipes: `ProcessTransport` starts /bin/sh running a
# small loop that stands in for DuckDB. It reads the session's stdin a line at
# a time, prints back every `.print` payload, answers `SELECT answer` with a
# one-row JSON array and writes an error line to stderr for a query that starts
# with FAIL. No DuckDB is needed and no duration is checked.
#
# What each test proves:
# - test_a_conversation_over_real_pipes: a timed query, a fetched query with
#   its row, a failing query with its stderr text and a query after it all
#   work on one process, in order, and the process exits 0 when the session
#   closes (its stdin reaches end of file).
# - test_a_binary_that_cannot_start_raises: a path that does not exist is an
#   error from `ProcessTransport`, not a session that hangs.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import BenchClock, DuckDbSession, ProcessTransport


def _stand_in() -> String:
    return String(
    'while IFS= read -r l; do case "$l" in'
    ' ".print "*) echo "${l#.print }";;'
    ' "SELECT answer"*) echo \'[{"answer":42}]\';;'
    ' "FAIL"*) echo "Error: failed" >&2;;'
    " esac; done"
)


def test_a_conversation_over_real_pipes() raises:
    var args = List[String]()
    args.append(String("-c"))
    args.append(_stand_in())
    var s = DuckDbSession[ProcessTransport](
        ProcessTransport(String("/bin/sh"), args), BenchClock.system()
    )
    var timed = s.run_timed(String("SELECT answer"))
    assert_true(timed.ok())
    assert_equal(timed.id, 1)
    var fetched = s.fetch(String("SELECT answer"))
    assert_true(fetched.ok())
    assert_equal(fetched.rows.row_count(), 1)
    assert_equal(fetched.rows.names[0], String("answer"))
    assert_equal(fetched.rows.rows[0][0].i, Int64(42))
    var failed = s.fetch(String("FAIL now"))
    assert_false(failed.ok())
    assert_equal(failed.error, String("Error: failed\n"))
    var after = s.run_timed(String("SELECT answer"))
    assert_true(after.ok())
    assert_equal(after.id, 4)
    assert_equal(s.close(), 0)


def test_a_binary_that_cannot_start_raises() raises:
    var raised = False
    try:
        var t = ProcessTransport(String("/nonexistent/komira-bench-duckdb"), List[String]())
        _ = t.finish()
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
