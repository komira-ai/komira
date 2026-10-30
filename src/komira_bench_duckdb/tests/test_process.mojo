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
# - test_a_long_error_text_does_not_stall_the_process: a query whose error text
#   is 300000 bytes (several pipe buffers) comes back whole with its own
#   query, and the next query runs; a stderr that is only read after the end
#   marker would leave the process blocked before it prints the marker.
# - test_a_silent_process_ends_in_an_error_and_can_be_killed: a process that
#   reads its input and never prints raises once the allowed silence passes,
#   later queries are refused, and `kill` ends it.
# - test_a_write_to_a_process_that_has_gone_raises: after the process has
#   exited, sending raises an error and this process carries on.
# - test_a_binary_that_cannot_start_raises: a path that does not exist is an
#   error from `ProcessTransport`, not a session that hangs.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import BenchClock, DuckDbSession, ProcessTransport


def _stand_in() -> String:
    return String(
    'while IFS= read -r l; do case "$l" in'
    ' ".print "*) echo "${l#.print }";;'
    ' "SELECT answer"*) echo \'[{"answer":42}]\';;'
    ' "DESCRIBE SELECT answer"*) echo \'[{"column_name":"answer","column_type":"BIGINT"}]\';;'
    ' "FAIL"*) echo "Error: failed" >&2;;'
    ' "FLOOD"*) head -c 300000 /dev/zero | tr "\\0" e >&2;;'
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
    assert_equal(len(fetched.rows.types), 1)
    assert_equal(fetched.rows.types[0], String("BIGINT"))
    var failed = s.fetch(String("FAIL now"))
    assert_false(failed.ok())
    assert_equal(failed.error, String("Error: failed\n"))
    var after = s.run_timed(String("SELECT answer"))
    assert_true(after.ok())
    assert_equal(after.id, 5)
    assert_equal(s.close(), 0)


def test_a_long_error_text_does_not_stall_the_process() raises:
    var args = List[String]()
    args.append(String("-c"))
    args.append(_stand_in())
    var s = DuckDbSession[ProcessTransport](
        ProcessTransport(String("/bin/sh"), args), BenchClock.system(), 60000
    )
    var flooded = s.run_timed(String("FLOOD"))
    assert_equal(flooded.error.byte_length(), 300000)
    var after = s.fetch(String("SELECT answer"))
    assert_true(after.ok())
    assert_equal(after.rows.rows[0][0].i, Int64(42))
    assert_equal(s.close(), 0)


def test_a_silent_process_ends_in_an_error_and_can_be_killed() raises:
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("cat > /dev/null"))
    var s = DuckDbSession[ProcessTransport](
        ProcessTransport(String("/bin/sh"), args), BenchClock.system(), 100
    )
    var message = String("")
    try:
        _ = s.run_timed(String("SELECT 'never ends"))
    except e:
        message = String(e)
    assert_true(message.find(String("printed nothing for 100 ms")) >= 0)
    var refused = False
    try:
        _ = s.run_timed(String("SELECT 1"))
    except:
        refused = True
    assert_true(refused)
    s.kill()
    _ = s.close()


def test_a_write_to_a_process_that_has_gone_raises() raises:
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("exit 0"))
    var t = ProcessTransport(String("/bin/sh"), args)
    var ended = False
    while not ended:
        ended = t.read_stdout(0).eof
    var raised = False
    try:
        t.send(String("late\n"))
    except:
        raised = True
    assert_true(raised)
    assert_equal(t.finish(), 0)


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
