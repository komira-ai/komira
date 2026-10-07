# =============================================================================
# heartbeat_receiver.mojo -- a stateful komira.job_report.v1 heartbeat
# receiver, served by komira_http_server, for the supervisor's loopback tests
# =============================================================================
#
# The supervisor's peer is not in komira, so the tests supply one: a
# `RequestDispatcher` that decodes every POST body as a `JobHeartbeat`, keeps
# the state of ONE run, and answers each beat with a `JobHeartbeatReply`.
#
# THE STATE MACHINE. The proto fixes what a sender reports (RUNNING while the
# job runs, then exactly one of COMPLETED, FAILED, CANCELLED) and leaves the
# receiver's richer state to the receiver. This one keeps:
#
#   ASSIGNED    the run is expected and no beat has arrived yet;
#   RUNNING     a RUNNING beat arrived;
#   CANCELLING  this receiver answered a RUNNING beat with CANCEL;
#   COMPLETED   terminal: the job exited with status 0 (the proto's meaning of
#               COMPLETED, so the receiver records exit code 0);
#   FAILED      terminal: the beat carries a JobFailure (exit code or signal,
#               the stderr tail, the panic line);
#   CANCELLED   terminal: the job was stopped by this receiver's CANCEL.
#
#   ASSIGNED   --RUNNING-->   RUNNING
#   RUNNING    --RUNNING-->   RUNNING, or CANCELLING when cancel_requested
#   RUNNING    --COMPLETED--> COMPLETED      (also from CANCELLING: the job
#   RUNNING    --FAILED-->    FAILED          may exit before it is stopped)
#   CANCELLING --CANCELLED--> CANCELLED
#
# Every other arrival is a VIOLATION, recorded with its reason and never
# acted on: a beat after a terminal state, a terminal beat before any RUNNING
# beat, a RUNNING beat after CANCEL was sent (the sender ignored it),
# CANCELLED without a CANCEL, FAILED without a JobFailure or RUNNING,
# COMPLETED or CANCELLED with one, UNSPECIFIED or a phase outside the enum
# (whatever the state), another job's id or instance name, a body that does
# not decode, any method but POST or path but `/beat`, and a failed pid or
# first-beat probe (below). The tests assert the violation list empty, so
# each of these is a test failure.
#
# CANCEL: `cancel_after_running_beats = k > 0` flags `cancel_requested` once
# the k-th RUNNING beat is answered (that beat still gets CONTINUE), so the
# NEXT RUNNING beat is the one answered CANCEL. Every other beat is answered
# with `continue_directive` (CONTINUE, or a number this build has no name for,
# which the sender must also read as CONTINUE).
#
# PID PROBE (optional): with `pid_file` set, at the moment it answers CANCEL
# the receiver reads the job's pid from that file (the job writes it, a
# decimal number and a newline) and records whether the process was alive
# then, so a test's "the child is gone after the run" is not satisfied by a
# pid that was never alive. The file may be half written when the probe
# looks, so it waits up to `pid_wait_ms` for a complete line.
#
# FIRST-BEAT PROBE (optional): with `first_beat_gate` set, the receiver
# decides "did the job exist before the first beat was answered" from an
# ORDER of events, not from a wait. When beat 1 arrives, and before it is
# answered, the receiver (1) asks the kernel whether THIS process has any
# SIGCHLD-reporting child (every posix_spawn child), in any state
# (komira_supervisor's `proc_probe_children`:
# `waitid(P_ALL, WEXITED | WNOHANG | WNOWAIT)`, which never reaps), then
# (2) creates the file `first_beat_gate`, then (3) answers.
#
#   * The supervisor runs in this process, and its job is a posix_spawn child
#     of it: the child is in the process table, parented here, by the time
#     the spawn call returns. A supervisor that spawned before sending beat 1
#     (it skipped the initial pre-spawn beat) therefore has a child at (1),
#     however slow the job itself is to start: a violation.
#   * A supervisor that sends beat 1 and awaits its reply before spawning
#     cannot have a child at (1): the spawn happens after (3).
#   * The job script waits for `first_beat_gate` before doing anything else
#     (a loop that never runs when the gate is already there), so when the
#     spawn came first the child cannot exit, and be reaped, before (1) looks.
#     The test also has the job record whether the gate already existed when
#     it started: the job-side record of the same order.
#
# `first_beat_children` keeps what (1) saw (CHILDREN_*). Any child is a
# violation: a running one (CHILDREN_RUNNING) or one that has exited and is
# not yet reaped (CHILDREN_EXITED; the gate makes it unreachable from the
# loopback test). The probe leaves an exited child a zombie, so its owner's
# waitpid(pid) still collects it. Only ECHILD means "no child"; any other
# waitid failure is a violation carrying its errno (CHILDREN_PROBE_FAILED).
#
# THREADING: the receiver is owned by the serve loop, touched only by the
# serving thread while a duet runs, and read by the test after the join.
# Plain owned fields; no pointer, no byte slab.
# =============================================================================

from std.pathlib import Path
from std.time import sleep

from komira_clock import now_ns

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec.types import (
    HTTP_METHOD_POST,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.dispatch import RequestDispatcher
from komira_proto_codec import decode_proto, encode_proto

# Test-only reuse of komira_supervisor's kill(2) wrapper as a liveness probe
# (signal 0) and of its non-reaping waitid(2) child probe as the first-beat
# probe; no foreign function is declared here.
from komira_supervisor.proc_ffi import proc_kill, proc_probe_children

from komira_job_report_proto.job_report import (
    JobDirective,
    JobHeartbeat,
    JobHeartbeatReply,
    JobPhase,
)


comptime RECEIVER_ASSIGNED: Int = 0
comptime RECEIVER_RUNNING: Int = 1
comptime RECEIVER_CANCELLING: Int = 2
comptime RECEIVER_COMPLETED: Int = 3
comptime RECEIVER_FAILED: Int = 4
comptime RECEIVER_CANCELLED: Int = 5

# The reply `receive` returns for a beat it refused to decode: not a
# directive, and answered with HTTP 400 by `dispatch`.
comptime REPLY_REFUSED: Int = -1

comptime BEAT_PATH = "/beat"

# What the first-beat probe saw (module header).
comptime CHILDREN_NOT_PROBED: Int = -1
comptime CHILDREN_NONE: Int = 0
comptime CHILDREN_RUNNING: Int = 1
comptime CHILDREN_EXITED: Int = 2
comptime CHILDREN_PROBE_FAILED: Int = 3


def receiver_state_name(state: Int) -> String:
    if state == RECEIVER_ASSIGNED:
        return String("ASSIGNED")
    if state == RECEIVER_RUNNING:
        return String("RUNNING")
    if state == RECEIVER_CANCELLING:
        return String("CANCELLING")
    if state == RECEIVER_COMPLETED:
        return String("COMPLETED")
    if state == RECEIVER_FAILED:
        return String("FAILED")
    if state == RECEIVER_CANCELLED:
        return String("CANCELLED")
    return String("UNKNOWN(") + String(state) + String(")")


def children_name(children: Int) -> String:
    if children == CHILDREN_NOT_PROBED:
        return String("not probed")
    if children == CHILDREN_NONE:
        return String("no child")
    if children == CHILDREN_RUNNING:
        return String("a running child")
    if children == CHILDREN_EXITED:
        return String("an exited, unreaped child")
    if children == CHILDREN_PROBE_FAILED:
        return String("a failed probe")
    return String("UNKNOWN(") + String(children) + String(")")


def _parse_pid(text: String) raises -> Int:
    """The decimal number at the start of `text` (a pid file's `$$` and its
    newline). Raises when there is none."""
    var bytes = text.as_bytes()
    var n = 0
    var i = 0
    while i < len(bytes) and bytes[i] >= UInt8(ord("0")) and bytes[i] <= UInt8(
        ord("9")
    ):
        n = n * 10 + Int(bytes[i] - UInt8(ord("0")))
        i += 1
    if i == 0:
        raise Error("no pid in the pid file")
    return n


def _is_terminal_phase(phase: Int) -> Bool:
    return (
        phase == JobPhase.JOB_PHASE_COMPLETED
        or phase == JobPhase.JOB_PHASE_FAILED
        or phase == JobPhase.JOB_PHASE_CANCELLED
    )


def _is_terminal(state: Int) -> Bool:
    return (
        state == RECEIVER_COMPLETED
        or state == RECEIVER_FAILED
        or state == RECEIVER_CANCELLED
    )


struct HeartbeatReceiver(RequestDispatcher):
    """One run's heartbeat receiver (module header)."""

    # What the run is expected to be, and the receiver's policy.
    var job_id: String
    var instance_name: String
    var cancel_after_running_beats: Int
    var continue_directive: Int
    var pid_file: String
    var first_beat_gate: String
    var pid_wait_ms: Int

    # The run's state.
    var state: Int
    var history: List[Int]
    var cancel_requested: Bool
    var running_beats: Int

    # What arrived, per beat: the phase number, the directive answered (or
    # REPLY_REFUSED) and the request body's byte length.
    var phases: List[Int]
    var replies: List[Int]
    var body_lens: List[Int]

    # The terminal report.
    var exit_code: Optional[Int32]
    var signal: Optional[Int32]
    var stderr_tail: List[String]
    var terminal_body_len: Int

    # The pid probe (see the module header): -1 when not probed.
    var probed_pid: Int
    var probed_alive: Bool

    # The first-beat probe (see the module header).
    var first_beat_children: Int
    var gate_opened: Bool

    var violations: List[String]

    def __init__(
        out self,
        var job_id: String,
        var instance_name: String,
        cancel_after_running_beats: Int = 0,
        continue_directive: Int = JobDirective.JOB_DIRECTIVE_CONTINUE,
        var pid_file: String = String(""),
        var first_beat_gate: String = String(""),
        pid_wait_ms: Int = 2000,
    ):
        self.job_id = job_id^
        self.instance_name = instance_name^
        self.cancel_after_running_beats = cancel_after_running_beats
        self.continue_directive = continue_directive
        self.pid_file = pid_file^
        self.first_beat_gate = first_beat_gate^
        self.pid_wait_ms = pid_wait_ms
        self.state = RECEIVER_ASSIGNED
        self.history = List[Int]()
        self.history.append(RECEIVER_ASSIGNED)
        self.cancel_requested = False
        self.running_beats = 0
        self.phases = List[Int]()
        self.replies = List[Int]()
        self.body_lens = List[Int]()
        self.exit_code = None
        self.signal = None
        self.stderr_tail = List[String]()
        self.terminal_body_len = -1
        self.probed_pid = -1
        self.probed_alive = False
        self.first_beat_children = CHILDREN_NOT_PROBED
        self.gate_opened = False
        self.violations = List[String]()

    # ---- the state machine ----

    def _enter(mut self, state: Int):
        if state != self.state:
            self.state = state
            self.history.append(state)

    def _violation(mut self, beat: Int, var why: String):
        self.violations.append(
            String("beat ") + String(beat) + String(": ") + why
        )

    def _probe_pid(mut self):
        """Record the job's pid and whether it is alive now (module header).
        A file that holds no complete line within `pid_wait_ms` is a
        violation: the probe was asked for."""
        if self.pid_file.byte_length() == 0:
            return
        var give_up = now_ns() + UInt64(self.pid_wait_ms) * 1_000_000
        while True:
            try:
                var text = Path(self.pid_file).read_text()
                if text.byte_length() > 0 and text.endswith("\n"):
                    self.probed_pid = _parse_pid(text)
                    self.probed_alive = (
                        proc_kill(Int32(self.probed_pid), Int32(0)) == 0
                    )
                    return
            except:
                pass
            if now_ns() >= give_up:
                break
            sleep(Float64(0.01))
        self.violations.append(
            String("pid probe: no complete pid line in ")
            + self.pid_file
            + String(" within ")
            + String(self.pid_wait_ms)
            + String(" ms")
        )

    def _first_beat_probe(mut self, beat: Int):
        """The first-beat probe (module header): look for a child of this
        process, THEN open the gate; the caller answers after both."""
        if self.first_beat_gate.byte_length() == 0:
            return
        try:
            var p = proc_probe_children()
            if not p.any_child:
                # ECHILD: this process has no child at all.
                self.first_beat_children = CHILDREN_NONE
            elif p.exited_pid != Int32(0):
                self.first_beat_children = CHILDREN_EXITED
            else:
                self.first_beat_children = CHILDREN_RUNNING
        except e:
            self.first_beat_children = CHILDREN_PROBE_FAILED
            self._violation(
                beat, String("the first-beat probe failed: ") + String(e)
            )
        if (
            self.first_beat_children != CHILDREN_NONE
            and self.first_beat_children != CHILDREN_PROBE_FAILED
        ):
            self._violation(
                beat,
                String("the first beat arrived after the job was spawned")
                + String(" (this process had ")
                + children_name(self.first_beat_children)
                + String(" before the beat was answered)"),
            )
        try:
            Path(self.first_beat_gate).write_text(String("answered\n"))
            self.gate_opened = True
        except e:
            self._violation(
                beat,
                String("could not open the gate ")
                + self.first_beat_gate
                + String(": ")
                + String(e),
            )

    def describe(self) -> String:
        """Everything this receiver recorded, one item per line, for a
        failing test to print."""
        var s = String("receiver: state ") + receiver_state_name(self.state)
        s += String("\n  history:")
        for i in range(len(self.history)):
            s += String(" ") + receiver_state_name(self.history[i])
        s += String("\n  beats (phase/reply/bytes):")
        for i in range(len(self.phases)):
            s += String(" ") + String(self.phases[i]) + String("/")
            if i < len(self.replies):
                s += String(self.replies[i])
            else:
                s += String("-")
            s += String("/") + String(self.body_lens[i])
        s += String("\n  running_beats ") + String(self.running_beats)
        s += String(", cancel_requested ") + String(self.cancel_requested)
        s += String("\n  first beat: ") + children_name(
            self.first_beat_children
        )
        s += String(", gate opened ") + String(self.gate_opened)
        s += String("\n  pid probe: pid ") + String(self.probed_pid)
        s += String(", alive ") + String(self.probed_alive)
        if self.exit_code:
            s += String("\n  exit code ") + String(self.exit_code.value())
        if self.signal:
            s += String("\n  signal ") + String(self.signal.value())
        s += String("\n  stderr tail lines ") + String(len(self.stderr_tail))
        s += String("\n  violations: ") + String(len(self.violations))
        for v in self.violations:
            s += String("\n    ") + v
        return s^

    def receive(mut self, var body: List[UInt8]) -> Int:
        """Take one beat's body; return the directive number to answer with,
        or REPLY_REFUSED when the body does not decode."""
        var beat = len(self.phases) + 1
        var body_len = len(body)
        if beat == 1:
            # Before anything else, and before the answer (module header).
            self._first_beat_probe(beat)
        var hb: JobHeartbeat
        try:
            hb = decode_proto[JobHeartbeat](body^)
        except e:
            self._violation(beat, String("undecodable body: ") + String(e))
            self.phases.append(-1)
            self.replies.append(REPLY_REFUSED)
            self.body_lens.append(body_len)
            return REPLY_REFUSED

        var phase = hb.phase.value
        self.phases.append(phase)
        self.body_lens.append(body_len)
        if hb.job_id != self.job_id:
            self._violation(beat, String("job_id ") + hb.job_id)
        if hb.instance_name != self.instance_name:
            self._violation(beat, String("instance_name ") + hb.instance_name)

        var reply = self.continue_directive
        if _is_terminal(self.state):
            self._violation(
                beat,
                String("a beat after the terminal state ")
                + receiver_state_name(self.state),
            )
        elif phase == JobPhase.JOB_PHASE_RUNNING:
            if Bool(hb.failure):
                self._violation(beat, String("RUNNING carries a JobFailure"))
            if self.state == RECEIVER_CANCELLING:
                self._violation(
                    beat, String("RUNNING after CANCEL was sent")
                )
            self.running_beats += 1
            if self.cancel_requested:
                reply = JobDirective.JOB_DIRECTIVE_CANCEL
                if self.state != RECEIVER_CANCELLING:
                    self._probe_pid()
                    self._enter(RECEIVER_CANCELLING)
            else:
                self._enter(RECEIVER_RUNNING)
                if (
                    self.cancel_after_running_beats > 0
                    and self.running_beats >= self.cancel_after_running_beats
                ):
                    self.cancel_requested = True
        elif not _is_terminal_phase(phase):
            # UNSPECIFIED, or a number outside the enum.
            self._violation(beat, String("phase ") + String(phase))
        elif self.state == RECEIVER_ASSIGNED:
            self._violation(
                beat,
                String("terminal phase ") + String(phase)
                + String(" before any RUNNING beat"),
            )
        elif phase == JobPhase.JOB_PHASE_COMPLETED:
            if Bool(hb.failure):
                self._violation(beat, String("COMPLETED carries a JobFailure"))
            self.exit_code = Optional[Int32](Int32(0))
            self.terminal_body_len = body_len
            self._enter(RECEIVER_COMPLETED)
        elif phase == JobPhase.JOB_PHASE_FAILED:
            if not hb.failure:
                self._violation(beat, String("FAILED without a JobFailure"))
            else:
                ref f = hb.failure.value()
                self.exit_code = f.exit_code
                self.signal = f.signal
                self.stderr_tail = f.stderr_tail.copy()
            self.terminal_body_len = body_len
            self._enter(RECEIVER_FAILED)
        elif phase == JobPhase.JOB_PHASE_CANCELLED:
            if self.state != RECEIVER_CANCELLING:
                self._violation(beat, String("CANCELLED without a CANCEL"))
            if Bool(hb.failure):
                self._violation(beat, String("CANCELLED carries a JobFailure"))
            self.terminal_body_len = body_len
            self._enter(RECEIVER_CANCELLED)
        self.replies.append(reply)
        return reply

    # ---- HTTP ----

    def admit(mut self, method: HttpMethod, path: String) -> Bool:
        """True for `POST /beat`; anything else is a violation, answered 404
        by `dispatch`."""
        if method.code != HTTP_METHOD_POST or path != BEAT_PATH:
            self.violations.append(
                String("request ") + method.name() + String(" ") + path
            )
            return False
        return True

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        if not self.admit(req.method, req.path):
            return _response(Int32(404), List[UInt8]())
        var body = List[UInt8]()
        swap(body, req.body)
        var directive = self.receive(body^)
        if directive == REPLY_REFUSED:
            return _response(Int32(400), List[UInt8]())
        return _response(
            Int32(200),
            encode_proto[JobHeartbeatReply](
                JobHeartbeatReply(JobDirective(directive))
            ),
        )


def _response(status: Int32, var body: List[UInt8]) -> HttpResponse:
    var resp = HttpResponse(status)
    # `HttpResponse(status)` leaves the framing headers to the caller.
    resp.headers[String("content-type")] = String("application/protobuf")
    resp.headers[String("content-length")] = String(len(body))
    resp.body = body^
    return resp^
