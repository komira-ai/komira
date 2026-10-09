# =============================================================================
# komira_job_supervisor/job_supervisor_state.mojo: the run loop's state.
# =============================================================================
#
# The supervisor is a single poll-then-heartbeat loop, so its state is a plain
# struct the loop reads and writes directly (no mutex).
#
#   JobSupervisorPhase : the four phases a supervisor reports (RUNNING /
#                        COMPLETED / FAILED / CANCELLED), mapped onto the wire
#                        `JobPhase` enum by heartbeat_client.mojo.
#   FailureReport      : the forensics on a FAILED heartbeat (exit_code /
#                        signal / stderr_tail / panic_message).
#   JobSupervisorState : phase + progress + message + Optional[FailureReport] +
#                        cancel_requested.
#
# Owned value structs only; no pointer type, no byte-slab.
# =============================================================================


# =============================================================================
# §1 — JobSupervisorPhase — the four job-supervisor-reported phases.
# =============================================================================
struct JobSupervisorPhase(Copyable, Movable, ImplicitlyCopyable):
    """A phase the supervisor reports: RUNNING (periodic liveness) or one of
    the three terminals (COMPLETED / FAILED / CANCELLED). The wire enum's
    zero value, UNSPECIFIED, is never reported.

    Stored as a small Int tag; `wire_str()` is the SCREAMING_SNAKE name."""

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
        """The SCREAMING_SNAKE name of the phase."""
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
    job_report.proto `JobFailure` message + analyze_exit ->
    FailureReport build). All fields are optional EXCEPT the stderr ring, which
    is always present (possibly empty).

      exit_code         — the child's exit code (Some when it exited normally
                          with a non-zero status; None when killed by signal).
      signal            — the terminating signal number (Some when killed by a
                          signal; None when it exited normally).
      stderr_tail       — the last N lines of the child's stderr (the ring),
                          for failure diagnosis.
      panic_message     — the extracted panic line when stderr contains
                          "panic" / "panicked" (Some) else None."""

    var exit_code: Optional[Int32]
    var signal: Optional[Int32]
    var stderr_tail: List[String]
    var panic_message: Optional[String]

    def __init__(
        out self,
        exit_code: Optional[Int32],
        signal: Optional[Int32],
        var stderr_tail: List[String],
        var panic_message: Optional[String],
    ):
        self.exit_code = exit_code
        self.signal = signal
        self.stderr_tail = stderr_tail^
        self.panic_message = panic_message^

    def copy(self) -> FailureReport:
        """Deep copy (the JSON builder reads this without consuming the loop's
        owned report)."""
        var tail = List[String]()
        for ref l in self.stderr_tail:
            tail.append(l)
        var pm = Optional[String]()
        if self.panic_message:
            pm = Optional[String](self.panic_message.value())
        return FailureReport(self.exit_code, self.signal, tail^, pm^)


# =============================================================================
# §3 — JobSupervisorState — the loop's working state.
# =============================================================================
struct JobSupervisorState(Movable):
    """The supervisor's in-loop state, read and written by the single
    poll-then-heartbeat loop.

      phase             — the current job supervisor phase (starts RUNNING).
      progress          — Optional[Int32] progress percent (None unless set).
      message           — Optional[String] human status line.
      failure           — Some only once the child is analyzed as Failed.
      cancel_requested  — set True when a heartbeat reply asks to cancel;
                          the loop then terminates the child.
      timed_out         — set True when the loop stopped the child for
                          running past --max-runtime-secs (the phase is
                          then FAILED and `message` says why)."""

    var phase: JobSupervisorPhase
    var progress: Optional[Int32]
    var message: Optional[String]
    var failure: Optional[FailureReport]
    var cancel_requested: Bool
    var timed_out: Bool

    def __init__(out self):
        self.phase = JobSupervisorPhase.running()
        self.progress = Optional[Int32]()
        self.message = Optional[String]()
        self.failure = Optional[FailureReport]()
        self.cancel_requested = False
        self.timed_out = False
