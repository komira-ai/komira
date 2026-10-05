# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_send_cancel.mojo
#   The whole run loop over HTTP, against the komira.job_report.v1 wire: every
#   beat it sends decodes as a JobHeartbeat, a JobHeartbeatReply that says
#   CANCEL stops the job, and one whose directive is unknown does not.
# =============================================================================
#
# `run_job_supervisor` drives the REAL `HttpHeartbeatReporter[NoHeartbeatAuth]`
# at a 127.0.0.1 responder. The responder reads each POST, keeps its body, and
# answers with a `JobHeartbeatReply` this test encoded in advance: one reply
# for the first beats, another from beat `switch_at` on. After the run, the
# kept bodies are decoded as `JobHeartbeat`, so what the supervisor sent is
# asserted from the wire, not from the supervisor's own state.
#
#   * CANCEL from beat 2 on, job `sh -c 'sleep 30'`: the job is stopped, the run
#     returns CANCELLED well before 30 s, the beats decode RUNNING, RUNNING,
#     CANCELLED, and each carries --job-name / --instance-name.
#   * CONTROL: a directive number this build has no name for (7), on every
#     beat, job `sh -c 'sleep 2'`: the job is NOT stopped and ends COMPLETED. Without
#     it, "a reply stops the job" is satisfied by a supervisor that stops on
#     any reply.
#
# ENCAPSULATION: the raw-socket responder and its pthread are this test's own
# FFI boundary; the code under test never exposes a pointer. The thread's box
# holds only fixed-size fields.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_objectstore import InMemoryConditionalStore
from komira_proto_codec import decode_proto, encode_proto

from komira_job_report_proto.job_report import (
    JobDirective,
    JobHeartbeat,
    JobHeartbeatReply,
    JobPhase,
)

from komira_job_supervisor import (
    HttpHeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    run_job_supervisor,
)
from komira_job_supervisor.heartbeat_auth import NoHeartbeatAuth


comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
# setsockopt(2) level/optname are NOT portable: the Linux pair returns EINVAL
# on darwin.
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_REUSEADDR_LINUX: Int32 = Int32(2)
comptime _SO_REUSEADDR_MACOS: Int32 = Int32(0x0004)

comptime _MAX_BEATS: Int = 8
comptime _BODY_CAP: Int = 512
comptime _REPLY_CAP: Int = 16
comptime _REQ_CAP: Int = 4096


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for the C NULL arguments of
    `accept(2)` / `pthread_create(3)` and the thread's return value.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the
    # all-zero (NULL) bit pattern. The NULL is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


@always_inline
def _sol_socket() -> Int32:
    comptime if CompilationTarget.is_macos():
        return _SOL_SOCKET_MACOS
    else:
        return _SOL_SOCKET_LINUX


@always_inline
def _so_reuseaddr() -> Int32:
    comptime if CompilationTarget.is_macos():
        return _SO_REUSEADDR_MACOS
    else:
        return _SO_REUSEADDR_LINUX


def _server_listen() raises -> Int32:
    """socket + SO_REUSEADDR + bind(127.0.0.1:0) + listen. Port 0: the kernel
    picks a free port, so concurrent copies of this test cannot collide."""
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("test: socket() failed")
    # SAFETY: `optval` is a stack local; setsockopt(2) reads 4 bytes out of it
    # synchronously and retains nothing.
    var optval = Array[Int32, 1](fill=Int32(1))
    var src = external_call["setsockopt", Int32](
        fd, _sol_socket(), _so_reuseaddr(), optval.unsafe_ptr(), UInt32(4)
    )
    if src < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: setsockopt(SO_REUSEADDR) failed on this platform")
    var addr = _build_sockaddr_in_loopback(UInt16(0))
    # SAFETY: `addr` is a stack local; bind(2) reads 16 bytes synchronously.
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["bind", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: bind() failed")
    rc = external_call["listen", Int32](fd, Int32(8))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: listen() failed")
    return fd


def _bound_port(fd: Int32) raises -> UInt16:
    """`getsockname(fd)` -> the port the kernel actually bound.

    # SAFETY: FFI boundary; `sa`/`len_buf` are stack locals the kernel writes
    # synchronously and retains neither.
    """
    var sa = Array[UInt8, 16](fill=UInt8(0))
    var len_buf = Array[UInt32, 1](fill=UInt32(16))
    var rc = external_call["getsockname", Int32](
        fd, sa.unsafe_ptr(), len_buf.unsafe_ptr()
    )
    if rc < Int32(0):
        raise Error("test: getsockname() failed")
    return UInt16(Int(sa[2]) << 8 | Int(sa[3]))


def _poll_readable(fd: Int32, timeout_ms: Int32) -> Bool:
    """`poll(2)` one fd for POLLIN, bounded. `struct pollfd` is `{int fd; short
    events; short revents}`, packed as two Int32 on a little-endian host."""
    var pfd = List[Int32]()
    pfd.append(fd)
    pfd.append(Int32(1))  # events = POLLIN
    var rc = external_call["poll", Int32](
        pfd.unsafe_ptr(), UInt64(1), timeout_ms
    )
    if rc <= Int32(0):
        return False
    var revents = (pfd[1] >> 16) & Int32(0xFFFF)
    return (revents & Int32(1)) != Int32(0)


def _head_end(buf: List[UInt8]) -> Int:
    """The index just past `\\r\\n\\r\\n`, or -1."""
    for i in range(len(buf) - 3):
        if (
            buf[i] == UInt8(0x0D)
            and buf[i + 1] == UInt8(0x0A)
            and buf[i + 2] == UInt8(0x0D)
            and buf[i + 3] == UInt8(0x0A)
        ):
            return i + 4
    return -1


def _content_length(buf: List[UInt8], head_end: Int) -> Int:
    """The `Content-Length` value in the head, or 0."""
    var head = String("")
    for i in range(head_end):
        var b = buf[i]
        head += chr(Int(b)) if b < UInt8(0x80) else String("?")
    head = head.lower()
    var at = head.find(String("\r\ncontent-length:"))
    if at < 0:
        return 0
    var i = at + String("\r\ncontent-length:").byte_length()
    var bytes = head.as_bytes()
    while i < len(bytes) and bytes[i] == UInt8(ord(" ")):
        i += 1
    var n = 0
    while i < len(bytes) and bytes[i] >= UInt8(ord("0")) and bytes[i] <= UInt8(
        ord("9")
    ):
        n = n * 10 + Int(bytes[i] - UInt8(ord("0")))
        i += 1
    return n


struct _Responder(Movable):
    """The responder thread's box. In: the listening fd, the two replies and
    the beat number the second one starts at. Out: the number of beats answered
    and the first `_MAX_BEATS` bodies.

    Fixed-size fields only: a `List` field would be a heap-owning field
    crossing a thread boundary through a raw box (the gap6 shape)."""

    var listen_fd: Int32
    var switch_at: Int32
    var first_reply: Array[UInt8, _REPLY_CAP]
    var first_len: Int32
    var then_reply: Array[UInt8, _REPLY_CAP]
    var then_len: Int32
    var beats: Int32
    var bodies: Array[UInt8, _MAX_BEATS * _BODY_CAP]
    var body_lens: Array[Int32, _MAX_BEATS]

    def __init__(
        out self,
        listen_fd: Int32,
        switch_at: Int32,
        first: List[UInt8],
        then: List[UInt8],
    ):
        self.listen_fd = listen_fd
        self.switch_at = switch_at
        self.first_reply = Array[UInt8, _REPLY_CAP](fill=UInt8(0))
        self.then_reply = Array[UInt8, _REPLY_CAP](fill=UInt8(0))
        for i in range(len(first)):
            self.first_reply[i] = first[i]
        for i in range(len(then)):
            self.then_reply[i] = then[i]
        self.first_len = Int32(len(first))
        self.then_len = Int32(len(then))
        self.beats = Int32(0)
        self.bodies = Array[UInt8, _MAX_BEATS * _BODY_CAP](fill=UInt8(0))
        self.body_lens = Array[Int32, _MAX_BEATS](fill=Int32(0))


def _send_all(fd: Int32, var data: List[UInt8]):
    """send(2) until every byte is written or the peer is gone. A partial
    write re-sends the unsent tail as its own buffer (no pointer arithmetic)."""
    while len(data) > 0:
        var n = external_call["send", Int64](
            fd, data.unsafe_ptr(), UInt64(len(data)), Int32(0)
        )
        if n <= Int64(0):
            return
        var rest = List[UInt8]()
        for i in range(Int(n), len(data)):
            rest.append(data[i])
        data = rest^


def _responder_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """pthread start_routine: answer every beat until a connection sends
    nothing (the test's stop signal) or none arrives for 30 s. Every beat is
    answered and counted; the first `_MAX_BEATS` bodies are kept. (A responder
    that stopped accepting would leave a beat waiting on the client's request
    timeout instead of failing the test.)

    SAFETY (FFI carve-out): `arg` is the `_Responder*` the spawner
    heap-allocated; the spawner owns the box and joins before reading or
    reclaiming it, and pthread_join is a full barrier for every write below."""
    var job = arg.bitcast[_Responder]()
    while True:
        if not _poll_readable(job[].listen_fd, Int32(30000)):
            break
        var conn = external_call["accept", Int32](
            job[].listen_fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        if conn < Int32(0):
            break
        # Read one whole request: the head, then Content-Length body bytes.
        var req = List[UInt8]()
        var chunk = List[UInt8]()
        chunk.resize(unsafe_uninit_length=_REQ_CAP)
        var done = False
        while not done and len(req) < _REQ_CAP:
            if not _poll_readable(conn, Int32(10000)):
                break
            var n = external_call["recv", Int64](
                conn, chunk.unsafe_ptr(), UInt64(_REQ_CAP), Int32(0)
            )
            if n <= Int64(0):
                break
            for i in range(Int(n)):
                req.append(chunk[i])
            var he = _head_end(req)
            if he >= 0 and len(req) >= he + _content_length(req, he):
                done = True
        if len(req) == 0:
            # The stop signal: connected and sent nothing.
            _ = external_call["close", Int32](conn)
            break
        var beat = Int(job[].beats)
        var he = _head_end(req)
        if beat < _MAX_BEATS and he >= 0:
            var blen = min(len(req) - he, _BODY_CAP)
            for i in range(blen):
                job[].bodies[beat * _BODY_CAP + i] = req[he + i]
            job[].body_lens[beat] = Int32(blen)
        job[].beats = Int32(beat + 1)

        var use_then = Int(job[].switch_at) > 0 and beat + 1 >= Int(
            job[].switch_at
        )
        var body = List[UInt8]()
        if use_then:
            for i in range(Int(job[].then_len)):
                body.append(job[].then_reply[i])
        else:
            for i in range(Int(job[].first_len)):
                body.append(job[].first_reply[i])
        var resp = List[UInt8]()
        resp.extend(
            (
                String("HTTP/1.1 200 OK\r\nContent-Type: application/protobuf")
                + String("\r\nContent-Length: ")
                + String(len(body))
                + String("\r\nConnection: close\r\n\r\n")
            ).as_bytes()
        )
        resp.extend(body^)
        _send_all(conn, resp^)
        _ = external_call["close", Int32](conn)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _stop_responder(port: UInt16):
    """Connect and hang up without sending: the responder's stop signal."""
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        return
    var addr = _build_sockaddr_in_loopback(port)
    # SAFETY: `addr` is a stack local; connect(2) reads 16 bytes synchronously.
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    _ = external_call["connect", Int32](fd, addr_ptr, UInt32(16))
    _ = external_call["close", Int32](fd)


def _reply(directive: Int) raises -> List[UInt8]:
    return encode_proto[JobHeartbeatReply](
        JobHeartbeatReply(JobDirective(directive))
    )


def _now_ms() -> Int:
    var ts = Array[Int64, 2](fill=Int64(0))
    # SAFETY: `ts` is a stack local the kernel writes synchronously
    # (CLOCK_MONOTONIC = 1 on Linux).
    _ = external_call["clock_gettime", Int32](Int32(1), ts.unsafe_ptr())
    return Int(ts[0]) * 1000 + Int(ts[1]) // 1_000_000


struct _Run(Movable):
    """One run as seen from both ends: the phase `run_job_supervisor`
    returned, its wall time, and, per beat the responder kept, the fields its
    body decodes to as a `JobHeartbeat`."""

    var phase: JobSupervisorPhase
    var wall_ms: Int
    var answered: Int
    var phases: List[Int]
    var job_ids: List[String]
    var instance_names: List[String]

    def __init__(out self, phase: JobSupervisorPhase, wall_ms: Int, answered: Int):
        self.phase = phase
        self.wall_ms = wall_ms
        self.answered = answered
        self.phases = List[Int]()
        self.job_ids = List[String]()
        self.instance_names = List[String]()


def _run_against_responder(
    var argv: List[String], first: List[UInt8], then: List[UInt8], switch_at: Int
) raises -> _Run:
    var listen_fd = _server_listen()
    var port = _bound_port(listen_fd)

    var raw = alloc[_Responder](1)
    UnsafePointer(to=raw[]).unsafe_write(
        _Responder(listen_fd, Int32(switch_at), first, then)
    )
    var entry = _responder_entry
    var tid: UInt64 = UInt64(0)
    var raw_arg = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var rc = external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        entry,
        raw_arg,
    )
    if rc != Int32(0):
        var fallback = OwnedPointer[_Responder](unsafe_from_raw_pointer=raw)
        _ = fallback^
        _ = external_call["close", Int32](listen_fd)
        raise Error("test: pthread_create failed for the loopback responder")

    var url = String("http://127.0.0.1:") + String(port) + String("/beat")
    var cfg = JobSupervisorConfig(
        String("job-send-cancel"),
        String("instance-send-cancel"),
        String("/bin/sh"),
        argv^,
        url,
        heartbeat_interval_secs=1,
    )
    var started = _now_ms()
    var phase = JobSupervisorPhase.running()
    try:
        phase = run_job_supervisor[
            HttpHeartbeatReporter[NoHeartbeatAuth], InMemoryConditionalStore
        ](
            cfg^,
            HttpHeartbeatReporter[NoHeartbeatAuth](url, NoHeartbeatAuth()),
            None,
            None,
        )
    except e:
        _stop_responder(port)
        var rv: UInt64 = UInt64(0)
        _ = external_call["pthread_join", Int32](
            tid, UnsafePointer(to=rv).bitcast[UInt8]()
        )
        _ = external_call["close", Int32](listen_fd)
        var owned = OwnedPointer[_Responder](unsafe_from_raw_pointer=raw)
        _ = owned^
        raise e^
    var wall = _now_ms() - started

    _stop_responder(port)
    var retval: UInt64 = UInt64(0)
    _ = external_call["pthread_join", Int32](
        tid, UnsafePointer(to=retval).bitcast[UInt8]()
    )
    _ = external_call["close", Int32](listen_fd)
    var answered = Int(raw[].beats)
    var bodies = List[List[UInt8]]()
    for b in range(min(answered, _MAX_BEATS)):
        var body = List[UInt8]()
        for i in range(Int(raw[].body_lens[b])):
            body.append(raw[].bodies[b * _BODY_CAP + i])
        bodies.append(body^)
    var owned = OwnedPointer[_Responder](unsafe_from_raw_pointer=raw)
    _ = owned^

    var run = _Run(phase, wall, answered)
    for i in range(len(bodies)):
        var hb = decode_proto[JobHeartbeat](bodies[i].copy())
        run.phases.append(hb.phase.value)
        run.job_ids.append(hb.job_id)
        run.instance_names.append(hb.instance_name)
    return run^


def test_a_cancel_reply_stops_the_job() raises:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(String("sleep 30"))
    var run = _run_against_responder(
        argv^,
        _reply(JobDirective.JOB_DIRECTIVE_CONTINUE),
        _reply(JobDirective.JOB_DIRECTIVE_CANCEL),
        2,
    )
    assert_true(
        run.phase == JobSupervisorPhase.cancelled(),
        "a CANCEL reply -> CANCELLED, got " + String(run.phase.wire_str()),
    )
    assert_true(
        run.wall_ms < 20000,
        "the job was stopped, not waited out: " + String(run.wall_ms) + " ms",
    )
    assert_equal(
        run.answered, 3, "beats: initial RUNNING, RUNNING (answered CANCEL), CANCELLED"
    )
    var n = len(run.phases)
    assert_equal(run.phases[0], JobPhase.JOB_PHASE_RUNNING, "beat 1")
    assert_equal(run.phases[1], JobPhase.JOB_PHASE_RUNNING, "beat 2")
    assert_equal(run.phases[n - 1], JobPhase.JOB_PHASE_CANCELLED, "last beat")
    for i in range(n):
        assert_equal(run.job_ids[i], String("job-send-cancel"), "job_id")
        assert_equal(
            run.instance_names[i], String("instance-send-cancel"), "instance_name"
        )
    print("  test_a_cancel_reply_stops_the_job: PASS")


def test_an_unknown_directive_does_not_stop_the_job() raises:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(String("sleep 2"))
    var unknown = _reply(7)
    var run = _run_against_responder(argv^, unknown, unknown, 0)
    assert_true(
        run.phase == JobSupervisorPhase.completed(),
        "an unknown directive is not CANCEL: the job ran to COMPLETED, got "
        + String(run.phase.wire_str()),
    )
    var n = len(run.phases)
    assert_true(n >= 3, "beats were answered while the job ran: " + String(n))
    assert_equal(run.phases[n - 1], JobPhase.JOB_PHASE_COMPLETED, "last beat")
    print("  test_an_unknown_directive_does_not_stop_the_job: PASS")


def main() raises:
    print("test_heartbeat_send_cancel:")
    test_a_cancel_reply_stops_the_job()
    test_an_unknown_directive_does_not_stop_the_job()
    print("test_heartbeat_send_cancel: ALL PASS")
