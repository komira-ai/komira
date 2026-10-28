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
#   test_a_write_to_a_child_that_has_exited_fails_and_we_live
#       a write to a child that is gone returns -EPIPE (not the byte count),
#       twice in a row, and this process is still running afterwards: the
#       default SIGPIPE action does not end it.
#   test_wait_readable_reports_silence_data_and_end_of_file
#       0 for a child that has printed nothing, 1 once it has printed, 1 at end
#       of file; the wait does not consume the data.
#   test_spawn_wiring_survives_a_closed_standard_descriptor
#       with this process's fd 1 closed, so the stdout pipe's read end is handed
#       fd 1, the child still writes its stdout into the pipe and exits 0.
#   test_every_pipe_end_is_close_on_exec_in_the_parent
#       the stdin write end and the stdout and stderr read ends all carry
#       FD_CLOEXEC from the moment the pipe exists, so a spawn on another
#       thread cannot inherit them.
#   test_failed_spawns_leave_no_descriptors_open
#       the count of open descriptors is the same after twenty failed spawns
#       that asked for a stdin pipe.
#   test_a_large_write_reaches_a_child_that_reads_all_of_it
#       1 MiB, many times the pipe capacity, arrives whole: the child counts
#       every byte.
#   test_a_child_that_stops_reading_ends_a_large_write_with_epipe
#       4 MiB to a child that exits after ten bytes: the write returns -EPIPE
#       and this process lives.
#   test_a_write_to_a_gone_child_fails_when_sigpipe_is_ignored
#       with SIGPIPE ignored the write still returns -EPIPE, twice.
#   test_read_blocking_on_a_nonblocking_pipe_reports_would_block
#       an empty descriptor made non-blocking gives would_block, not error.
#   test_spawn_wiring_survives_a_closed_stdin_descriptor
#       with this process's fd 0 closed, the stdin pipe's ends are moved above
#       2 and the child still reads what is written.
#
# Every child is reaped on every path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.ffi import external_call

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


def test_a_write_to_a_child_that_has_exited_fails_and_we_live() raises:
    var spec = ChildSpec.shell("exit 0")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, 0)
    assert_equal(sup.write_stdin(String("late\n")), -32)
    assert_equal(sup.write_stdin(String("later\n")), -32)
    sup.close()


def test_wait_readable_reports_silence_data_and_end_of_file() raises:
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    assert_equal(sup.wait_readable(sup.stdout_fd(), 0), 0)
    assert_true(sup.write_stdin(String("ping\n")) > 0)
    assert_equal(sup.wait_readable(sup.stdout_fd(), -1), 1)
    assert_equal(sup.wait_readable(sup.stdout_fd(), -1), 1)
    assert_equal(_read_until(sup, String("ping\n")), String("ping\n"))
    sup.close_stdin()
    assert_equal(sup.wait_readable(sup.stdout_fd(), -1), 1)
    assert_true(sup.read_blocking(sup.stdout_fd()).eof)
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()


def test_spawn_wiring_survives_a_closed_standard_descriptor() raises:
    var saved = external_call["dup", Int32](Int32(1))
    _ = external_call["close", Int32](Int32(1))
    var spec = ChildSpec.shell("echo hello")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    var out = String("")
    var code = -1
    if pid > Int32(0):
        out = sup.drain_pipe(sup.stdout_fd())
        _ = sup.drain_pipe(sup.stderr_fd())
        code = Int(sup.wait_exit().exit_code)
    sup.close()
    _ = external_call["dup2", Int32](saved, Int32(1))
    _ = external_call["close", Int32](saved)
    _spawned(pid)
    assert_equal(out, String("hello\n"))
    assert_equal(code, 0)


def _open_fd_count() -> Int:
    """How many descriptors below 1024 this process has open (F_GETFD = 1)."""
    var n = 0
    for fd in range(1024):
        if external_call["fcntl", Int32](Int32(fd), Int32(1)) >= Int32(0):
            n += 1
    return n


def _is_cloexec(fd: Int32) -> Bool:
    var flags = external_call["fcntl", Int32](fd, Int32(1))  # F_GETFD
    return flags >= Int32(0) and (flags & Int32(1)) == Int32(1)  # FD_CLOEXEC


def _lines(count: Int) -> String:
    """`count` lines of 64 bytes each."""
    var line = String("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n")
    var out = String("")
    for _ in range(count):
        out += line
    return out


def test_every_pipe_end_is_close_on_exec_in_the_parent() raises:
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    var stdin_ok = _is_cloexec(sup.stdin_fd())
    var stdout_ok = _is_cloexec(sup.stdout_fd())
    var stderr_ok = _is_cloexec(sup.stderr_fd())
    sup.close_stdin()
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()
    assert_true(stdin_ok)
    assert_true(stdout_ok)
    assert_true(stderr_ok)


def test_failed_spawns_leave_no_descriptors_open() raises:
    var before = _open_fd_count()
    for _ in range(20):
        var spec = ChildSpec("/nonexistent/komira-stdin-binary")
        spec.set_stdin_pipe()
        var sup = Supervisor()
        assert_true(sup.spawn(spec) < 0)
        sup.close()
    assert_equal(_open_fd_count(), before)


def test_a_large_write_reaches_a_child_that_reads_all_of_it() raises:
    var spec = ChildSpec.shell("wc -c")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    var payload = _lines(16384)  # 1 MiB, far above the pipe capacity
    assert_equal(sup.write_stdin(payload), payload.byte_length())
    sup.close_stdin()
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, 0)
    sup.close()
    assert_equal(String(out.strip()), String("1048576"))


def test_a_child_that_stops_reading_ends_a_large_write_with_epipe() raises:
    var spec = ChildSpec.shell("head -c 10 > /dev/null")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    assert_equal(sup.write_stdin(_lines(65536)), -32)  # 4 MiB
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, 0)
    sup.close()


def test_a_write_to_a_gone_child_fails_when_sigpipe_is_ignored() raises:
    var spec = ChildSpec.shell("exit 0")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    var previous = external_call["signal", Int](Int32(13), Int(1))  # SIG_IGN
    var first = sup.write_stdin(String("late\n"))
    var second = sup.write_stdin(String("later\n"))
    _ = external_call["signal", Int](Int32(13), previous)
    sup.close()
    assert_equal(first, -32)
    assert_equal(second, -32)


def test_read_blocking_on_a_nonblocking_pipe_reports_would_block() raises:
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    assert_equal(sup.set_nonblocking(sup.stdout_fd()), Int32(0))
    var c = sup.read_blocking(sup.stdout_fd())
    assert_true(c.would_block)
    assert_false(c.error)
    assert_false(c.eof)
    sup.close_stdin()
    assert_equal(sup.wait_readable(sup.stdout_fd(), -1), 1)
    assert_true(sup.read_blocking(sup.stdout_fd()).eof)
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()


def test_spawn_wiring_survives_a_closed_stdin_descriptor() raises:
    var saved = external_call["dup", Int32](Int32(0))
    _ = external_call["close", Int32](Int32(0))
    var spec = ChildSpec.shell("cat")
    spec.set_stdin_pipe()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    var out = String("")
    var code = -1
    if pid > Int32(0):
        _ = sup.write_stdin(String("hi\n"))
        sup.close_stdin()
        out = sup.drain_pipe(sup.stdout_fd())
        _ = sup.drain_pipe(sup.stderr_fd())
        code = Int(sup.wait_exit().exit_code)
    sup.close()
    _ = external_call["dup2", Int32](saved, Int32(0))
    _ = external_call["close", Int32](saved)
    _spawned(pid)
    assert_equal(out, String("hi\n"))
    assert_equal(code, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
