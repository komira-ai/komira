# =============================================================================
# test_stdin_pipe.mojo -- the child's stdin as a pipe the parent writes:
# ChildSpec.set_stdin_pipe, Supervisor.write_stdin / close_stdin / stdin_fd,
# and the blocking single read, Supervisor.read_blocking.
#
# One claim per `test_` function (TestSuite). What each would catch:
#
#   test_written_bytes_reach_the_child_until_end_of_file
#       every byte written reaches the child's fd 0 unchanged (a tab and a CR
#       included) and the child sees end of file only after
#       close_stdin; a write that stops at a short count, or an end of file
#       that never comes, fails the comparison or the exit code.
#   test_a_conversation_goes_back_and_forth_on_one_child
#       one child, three lines written one at a time, each answer read
#       before the next line is sent: the pipes are live while the child
#       runs, not collected at the end.
#   test_without_a_stdin_pipe_there_is_nothing_to_write_to
#       stdin_fd is -1 and write_stdin returns a negative errno; close_stdin
#       on it is a no-op.
#   test_close_stdin_is_idempotent_and_close_releases_it
#       the descriptor goes to -1 on the first close_stdin, a second is a
#       no-op, and Supervisor.close closes an open one.
#   test_a_spawn_that_fails_leaves_no_stdin
#       a path that does not exist returns a negative errno and no stdin
#       descriptor.
#   test_read_blocking_reports_data_end_of_file_and_error
#       data comes back as text, a drained pipe reports eof, a closed
#       descriptor reports error (not eof, not would_block), and fd -1 is eof.
#   test_a_later_child_does_not_hold_an_earlier_childs_stdin_open
#       child B is spawned while child A's stdin pipe is open; closing A's
#       write end still ends A's input. The write end is close-on-exec, so B
#       does not carry a copy.
#
# Every child is reaped on every path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_supervisor import ChildSpec, Supervisor

comptime _CLOSED_FD = Int32(1000000)  # above any fd limit a test runs with


def _spawned(pid: Int32) raises:
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


def _read_until(mut sup: Supervisor, want: String) raises -> String:
    """Read stdout in blocking chunks until `want` has arrived whole."""
    var acc = String("")
    while not acc.endswith(want):
        var c = sup.read_blocking(sup.stdout_fd())
        if c.eof or c.error:
            raise Error(String("stdout ended before ") + want + String(": ") + acc)
        acc += c.text
    return acc


def test_written_bytes_reach_the_child_until_end_of_file() raises:
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    var payload = String("alpha\tbeta\r\ngamma\n")
    assert_equal(sup.write_stdin(payload), payload.byte_length())
    sup.close_stdin()
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()
    assert_equal(out, payload)
    assert_equal(info.exit_code, 0)


def test_a_conversation_goes_back_and_forth_on_one_child() raises:
    var spec = ChildSpec.shell("while IFS= read -r l; do echo \"got $l\"; done")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    assert_true(sup.write_stdin(String("one\n")) > 0)
    assert_equal(_read_until(sup, String("got one\n")), String("got one\n"))
    assert_true(sup.write_stdin(String("two\n")) > 0)
    assert_equal(_read_until(sup, String("got two\n")), String("got two\n"))
    assert_true(sup.write_stdin(String("three\n")) > 0)
    assert_equal(_read_until(sup, String("got three\n")), String("got three\n"))
    sup.close_stdin()
    assert_equal(sup.drain_pipe(sup.stdout_fd()), String(""))
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, 0)
    sup.close()


def test_without_a_stdin_pipe_there_is_nothing_to_write_to() raises:
    var sup = Supervisor()
    _spawned(sup.spawn(ChildSpec.shell("exit 0")))
    assert_equal(sup.stdin_fd(), Int32(-1))
    assert_true(sup.write_stdin(String("x")) < 0)
    sup.close_stdin()
    assert_equal(sup.stdin_fd(), Int32(-1))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()


def test_close_stdin_is_idempotent_and_close_releases_it() raises:
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    assert_true(sup.stdin_fd() >= Int32(0))
    sup.close_stdin()
    assert_equal(sup.stdin_fd(), Int32(-1))
    sup.close_stdin()
    assert_equal(sup.stdin_fd(), Int32(-1))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()

    var spec2 = ChildSpec.shell("cat")
    spec2.set_stdin_pipe()
    var sup2 = Supervisor()
    _spawned(sup2.spawn(spec2))
    assert_true(sup2.stdin_fd() >= Int32(0))
    sup2.close()
    assert_equal(sup2.stdin_fd(), Int32(-1))
    _ = sup2.wait_exit()


def test_a_spawn_that_fails_leaves_no_stdin() raises:
    var spec = ChildSpec("/nonexistent/komira-stdin-binary")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    assert_true(sup.spawn(spec) < 0)
    assert_equal(sup.stdin_fd(), Int32(-1))
    sup.close()


def test_read_blocking_reports_data_end_of_file_and_error() raises:
    var sup = Supervisor()
    _spawned(sup.spawn(ChildSpec.shell("printf 'abc'")))
    var got = String("")
    var saw_eof = False
    while not saw_eof:
        var c = sup.read_blocking(sup.stdout_fd())
        assert_false(c.error)
        assert_false(c.would_block)
        got += c.text
        saw_eof = c.eof
    assert_equal(got, String("abc"))
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()

    var closed = sup.read_blocking(_CLOSED_FD)
    assert_true(closed.error)
    assert_false(closed.eof)
    assert_false(closed.would_block)
    var none = sup.read_blocking(Int32(-1))
    assert_true(none.eof)
    assert_false(none.error)


def test_a_later_child_does_not_hold_an_earlier_childs_stdin_open() raises:
    var spec_a = ChildSpec.shell("cat")
    spec_a.set_stdin_pipe()
    var a = Supervisor()
    _spawned(a.spawn(spec_a))
    var spec_b = ChildSpec.shell("exec cat")
    spec_b.set_stdin_pipe()
    var b = Supervisor()
    _spawned(b.spawn(spec_b))
    assert_true(a.write_stdin(String("for a\n")) > 0)
    a.close_stdin()
    assert_equal(a.drain_pipe(a.stdout_fd()), String("for a\n"))
    _ = a.drain_pipe(a.stderr_fd())
    assert_equal(a.wait_exit().exit_code, 0)
    a.close()
    b.close_stdin()
    _ = b.drain_pipe(b.stdout_fd())
    _ = b.drain_pipe(b.stderr_fd())
    assert_equal(b.wait_exit().exit_code, 0)
    b.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
