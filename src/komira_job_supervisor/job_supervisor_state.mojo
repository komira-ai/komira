# =============================================================================
# komira_job_supervisor/job_supervisor_state.mojo — the job supervisor's run-loop state.
# =============================================================================
#
# The pod-side supervisor's in-loop state. The job supervisor is a SINGLE
# poll-then-heartbeat loop (no concurrent heartbeat and child-wait tasks), so
# the state is a plain
# struct the loop reads / writes directly — no mutex, no watch.
#
#   JobSupervisorPhase    — the four job-supervisor-reported phases (RUNNING / COMPLETED /
#                   FAILED / CANCELLED). These map 1:1 onto the wire `phase`
#                   string the job-manager's heartbeat handler parses
#                   (`_phase_from_wire`), and onto the JobStore FSM target
#                   phases.
#   FailureReport — the forensic payload attached to a FAILED terminal
#                   heartbeat (exit_code / signal / stderr_tail / panic_message /
#                   last_record_offset). Serialized into the proto3-JSON
#                   `failure` sub-object the handler's `_failure_from_json`
#                   parses.
#   JobSupervisorState    — phase + progress + message + Optional[FailureReport] +
#                   cancel_requested. The loop mutates this as the child runs
#                   and the job-manager's heartbeat responses arrive.
#
# ENCAPSULATION + gap6: ordinary owned value structs (String / Optional /
# List[String] / POD Int32). NOT stored in any byte-slab, no UnsafePointer, no
# wildcard origin. Mojo 1.0.0b1.
# =============================================================================


# =============================================================================
# §1 — JobSupervisorPhase — the four job-supervisor-reported phases.
# =============================================================================
struct JobSupervisorPhase(Copyable, Movable, ImplicitlyCopyable):
    """A job-supervisor-reported job phase. Job supervisors only ever report the four
    terminal-ish phases — RUNNING (periodic liveness) + the three terminals
    (COMPLETED / FAILED / CANCELLED). PENDING / ASSIGNED / RECONCILING are
    control-plane-internal and a job supervisor reporting them is a wire validation
    error (the handler raises a 4xx).

    Stored as a small Int tag; `wire_str()` projects the SCREAMING_SNAKE form
    the heartbeat handler's `_phase_from_wire` accepts."""

    var _tag: Int32  # 0=RUNNING 1=COMPLETED 2=FAILED 3=CANCELLED

    @always_inline
    def __init__(out self, tag: Int32):
        self._tag = tag

    @staticmethod
    @always_inline
    def running() -> JobSupervisorPhase:
        return JobSupervisorPhase(Int32(0))

    @staticmethod
    @always_inline
    def completed() -> JobSupervisorPhase:
        return JobSupervisorPhase(Int32(1))

    @staticmethod
    @always_inline
    def failed() -> JobSupervisorPhase:
        return JobSupervisorPhase(Int32(2))

    @staticmethod
    @always_inline
    def cancelled() -> JobSupervisorPhase:
        return JobSupervisorPhase(Int32(3))

    @always_inline
    def __eq__(self, other: JobSupervisorPhase) -> Bool:
        return self._tag == other._tag

    @always_inline
    def __ne__(self, other: JobSupervisorPhase) -> Bool:
        return self._tag != other._tag

    @always_inline
    def is_terminal(self) -> Bool:
        """COMPLETED / FAILED / CANCELLED are terminal — the loop sends one
        last heartbeat and returns."""
        return self._tag != Int32(0)

    def wire_str(self) -> StaticString:
        """The SCREAMING_SNAKE wire token the heartbeat handler accepts."""
        if self._tag == Int32(0):
            return "RUNNING"
        if self._tag == Int32(1):
            return "COMPLETED"
        if self._tag == Int32(2):
            return "FAILED"
        return "CANCELLED"


# =============================================================================
# §2 — FailureReport — the forensic payload on a FAILED terminal heartbeat.
# =============================================================================
struct FailureReport(Movable):
    """The failure forensics attached to a FAILED heartbeat (mirrors the
    supervisor.proto `FailureReport` message + analyze_exit ->
    FailureReport build). All fields are optional EXCEPT the stderr ring, which
    is always present (possibly empty).

      exit_code         — the child's exit code (Some when it exited normally
                          with a non-zero status; None when killed by signal).
      signal            — the terminating signal number (Some when killed by a
                          signal; None when it exited normally).
      stderr_tail       — the last N lines of the child's stderr (the ring),
                          for failure diagnosis.
      panic_message     — the extracted panic line when stderr contains
                          "panic" / "panicked" (Some) else None.
      last_record_offset — reserved for the data-plane's last-processed offset
                          (always None in the MVP — the trivial child doesn't
                          report progress)."""

    var exit_code: Optional[Int32]
    var signal: Optional[Int32]
    var stderr_tail: List[String]
    var panic_message: Optional[String]
    var last_record_offset: Optional[Int64]

    def __init__(
        out self,
        exit_code: Optional[Int32],
        signal: Optional[Int32],
        var stderr_tail: List[String],
        var panic_message: Optional[String],
        last_record_offset: Optional[Int64],
    ):
        self.exit_code = exit_code
        self.signal = signal
        self.stderr_tail = stderr_tail^
        self.panic_message = panic_message^
        self.last_record_offset = last_record_offset

    def copy(self) -> FailureReport:
        """Deep copy (the JSON builder reads this without consuming the loop's
        owned report)."""
        var tail = List[String]()
        for ref l in self.stderr_tail:
            tail.append(l)
        var pm = Optional[String]()
        if self.panic_message:
            pm = Optional[String](self.panic_message.value())
        return FailureReport(
            self.exit_code, self.signal, tail^, pm^, self.last_record_offset
        )


# =============================================================================
# §3 — JobSupervisorState — the loop's working state.
# =============================================================================
struct JobSupervisorState(Movable):
    """The job supervisor's in-loop state. The single poll-then-heartbeat
    loop reads / writes this directly (no mutex — single-threaded MVP).

      phase             — the current job supervisor phase (starts RUNNING).
      progress          — Optional[Int32] progress percent (None in the MVP;
                          the trivial child doesn't report progress).
      message           — Optional[String] human status line.
      failure           — Some only once the child is analyzed as Failed.
      cancel_requested  — set True when a heartbeat response carries
                          {cancel:true}; the loop then terminates the child."""

    var phase: JobSupervisorPhase
    var progress: Optional[Int32]
    var message: Optional[String]
    var failure: Optional[FailureReport]
    var cancel_requested: Bool

    def __init__(out self):
        self.phase = JobSupervisorPhase.running()
        self.progress = Optional[Int32]()
        self.message = Optional[String]()
        self.failure = Optional[FailureReport]()
        self.cancel_requested = False
