# =============================================================================
# test_try_pop_any_completion.mojo
# =============================================================================
# Bulk-parallel substrate primitive —
# Reactor.try_pop_any_completion(op_ids) tests. depth=1 + depth=N flow through the SAME primitive; this
# file validates both shapes.
#
# Coverage:
#   * try_pop_any_completion on MOCK backend with empty op_ids → None.
#   * try_pop_any_completion on MOCK backend with non-matching op_ids → None.
#   * try_pop_any_completion on EPOLL backend with NO ready fd → None
#     (no completion to pop).
#   * try_pop_any_completion on EPOLL backend with ONE ready fd in op_ids →
#     Some(Completion).
#   * try_pop_any_completion on EPOLL backend with N ready fds (depth=N
#     bulk-parallel pattern): repeated calls drain all completions in
#     order; the buffer holds non-matches across calls.
#   * try_pop_any_completion + poll_completions interleave: non-matches
#     stashed by try_pop_any_completion are drained by the next
#     poll_completions call (no completions lost).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    Completion,
    OP_PENDING,
    OP_READ,
    OpHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
    Reactor,
)


# Linux socket constants — same as test_reactor_completion_queue_smoke.
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair_unix_stream() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and
    does not retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32, b: UInt8) raises:
    var buf = Array[UInt8, 1](fill=b)
    var w = external_call["send", Int](
        fd, buf.unsafe_ptr(), UInt(1), Int32(0),
    )
    if w != Int(1):
        raise Error("send() failed")


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def test_try_pop_mock_empty_op_ids_returns_none() raises:
    """MOCK backend + empty op_ids: nothing to match, None."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var ids = List[Int64]()
    var c = r.try_pop_any_completion(ids)
    assert_false(c.__bool__())


def test_try_pop_mock_non_matching_op_ids_returns_none() raises:
    """MOCK backend + non-empty op_ids: no fds registered, no kernel events,
    None. Documents that the primitive is non-blocking — it does NOT spin
    or block waiting for completions to arrive."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var ids = List[Int64](capacity=2)
    ids.append(Int64(42))
    ids.append(Int64(99))
    var c = r.try_pop_any_completion(ids)
    assert_false(c.__bool__())


def test_try_pop_epoll_no_ready_fd_returns_none() raises:
    """EPOLL backend with a registered but non-ready fd: try_pop returns
    None (nothing arrived this poll)."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)
        # Slow path: EAGAIN → Pending. No data primed; nothing ready.
        assert_equal(Int(op.state()), Int(OP_PENDING))
        var ids = List[Int64](capacity=1)
        ids.append(op.op_id())
        var c = r.try_pop_any_completion(ids)
        # Non-blocking poll with no event: None.
        assert_false(c.__bool__())
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_pop_epoll_single_match_returns_completion() raises:
    """EPOLL backend, single fd ready and in op_ids: try_pop returns Some.
    This is the depth=1 sugar shape (try_io spin-then-park)."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)
        assert_equal(Int(op.state()), Int(OP_PENDING))
        var op_id = op.op_id()
        # Make sv[0] readable.
        _send_one_byte(sv[1], UInt8(0xAB))
        # Spin a bounded number of times; epoll may not surface
        # readiness on the FIRST non-blocking call right after send
        # (kernel scheduling). Up to 1000 iterations of timeout=0
        # poll is enough on every Linux kernel we test on.
        var ids = List[Int64](capacity=1)
        ids.append(op_id)
        var c = Optional[Completion]()
        var i = 0
        while i < 1000:
            c = r.try_pop_any_completion(ids)
            if c.__bool__():
                break
            i = i + 1
        assert_true(c.__bool__())
        var got = c.value()
        assert_equal(got.op_id, op_id)
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_pop_epoll_bulk_parallel_drains_all() raises:
    """EPOLL backend, multiple fds ready and ALL in op_ids: repeated calls
    drain all completions. This is the depth=N bulk-parallel pattern
    (PrefetchSource.step) where the ring submits N ops and parks on the
    full set; each completion wakes the morsel which then re-enters step."""
    comptime if CompilationTarget.is_linux():
        # Three socketpairs, all primed.
        var sv0 = _socketpair_unix_stream()
        var sv1 = _socketpair_unix_stream()
        var sv2 = _socketpair_unix_stream()

        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var buf0 = Array[UInt8, 64](fill=UInt8(0))
        var buf1 = Array[UInt8, 64](fill=UInt8(0))
        var buf2 = Array[UInt8, 64](fill=UInt8(0))

        var op0 = r.submit(OP_READ, sv0[0], Span[UInt8](buf0))
        var op1 = r.submit(OP_READ, sv1[0], Span[UInt8](buf1))
        var op2 = r.submit(OP_READ, sv2[0], Span[UInt8](buf2))
        # All three pending (no data yet).
        assert_equal(Int(op0.state()), Int(OP_PENDING))
        assert_equal(Int(op1.state()), Int(OP_PENDING))
        assert_equal(Int(op2.state()), Int(OP_PENDING))

        # Prime all three.
        _send_one_byte(sv0[1], UInt8(0xA0))
        _send_one_byte(sv1[1], UInt8(0xA1))
        _send_one_byte(sv2[1], UInt8(0xA2))

        var ids = List[Int64](capacity=3)
        ids.append(op0.op_id())
        ids.append(op1.op_id())
        ids.append(op2.op_id())

        # Drain three completions. Each call returns one completion (any
        # of the three; order is kernel-dependent). Total: three Some,
        # then a None tail.
        var seen0 = False
        var seen1 = False
        var seen2 = False
        var attempts = 0
        while attempts < 3000 and (not seen0 or not seen1 or not seen2):
            var c = r.try_pop_any_completion(ids)
            if c.__bool__():
                var got = c.value()
                if got.op_id == op0.op_id(): seen0 = True
                elif got.op_id == op1.op_id(): seen1 = True
                elif got.op_id == op2.op_id(): seen2 = True
            attempts = attempts + 1
        assert_true(seen0)
        assert_true(seen1)
        assert_true(seen2)

        _close_fd(sv0[0]); _close_fd(sv0[1])
        _close_fd(sv1[0]); _close_fd(sv1[1])
        _close_fd(sv2[0]); _close_fd(sv2[1])


def test_try_pop_non_match_buffer_drained_by_poll_completions() raises:
    """EPOLL backend: try_pop_any_completion with op_ids that DON'T match
    a ready fd: the completion is stashed; the next poll_completions call
    surfaces it (no loss). This is the buffer-prepend invariant — non-
    matches don't get dropped on the floor.

    Setup: two socketpairs sv0, sv1; we register both, then call
    try_pop_any_completion with op_ids = [op1] (asking only for sv1).
    sv0 fires first; try_pop returns None (not a match) but stashes the
    completion. Then poll_completions surfaces both: the buffered op0 +
    the live op1.
    """
    comptime if CompilationTarget.is_linux():
        var sv0 = _socketpair_unix_stream()
        var sv1 = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var buf0 = Array[UInt8, 64](fill=UInt8(0))
        var buf1 = Array[UInt8, 64](fill=UInt8(0))
        var op0 = r.submit(OP_READ, sv0[0], Span[UInt8](buf0))
        var op1 = r.submit(OP_READ, sv1[0], Span[UInt8](buf1))
        var op_id_0 = op0.op_id()
        var op_id_1 = op1.op_id()

        # Prime sv0 ONLY. sv1 stays empty.
        _send_one_byte(sv0[1], UInt8(0xB0))

        # Ask try_pop only for op_id_1 — sv0's completion is a non-match.
        var ids_only_1 = List[Int64](capacity=1)
        ids_only_1.append(op_id_1)
        var attempts = 0
        var saw_match = Optional[Completion]()
        # We do up to 1000 polls. On each poll, sv0's completion is a
        # non-match and gets buffered. sv1 never fires. So saw_match
        # stays None across the loop.
        while attempts < 1000:
            var c = r.try_pop_any_completion(ids_only_1)
            if c.__bool__():
                saw_match = c
                break
            attempts = attempts + 1
        # We never matched op_id_1 because sv1 was never primed.
        assert_false(saw_match.__bool__())

        # Now drain ALL via poll_completions. The buffered op0 entry must
        # appear in the returned list (proving it was stashed, not lost).
        var completions = r.poll_completions(timeout_us=Int32(0))
        var saw_op0 = False
        for i in range(len(completions)):
            if completions[i].op_id == op_id_0:
                saw_op0 = True
        assert_true(saw_op0)

        _close_fd(sv0[0]); _close_fd(sv0[1])
        _close_fd(sv1[0]); _close_fd(sv1[1])


def main() raises:
    test_try_pop_mock_empty_op_ids_returns_none()
    test_try_pop_mock_non_matching_op_ids_returns_none()
    test_try_pop_epoll_no_ready_fd_returns_none()
    test_try_pop_epoll_single_match_returns_completion()
    test_try_pop_epoll_bulk_parallel_drains_all()
    test_try_pop_non_match_buffer_drained_by_poll_completions()
    print("PASS komira_async.reactor.try_pop_any_completion (bulk-parallel substrate)")
