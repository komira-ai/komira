# =============================================================================
# komira_job_supervisor/job_supervisor.mojo: the supervisor run loop.
# =============================================================================
#
# Spawn the job, heartbeat while it runs, act on a cancel, and when it exits
# classify the result and send one terminal heartbeat.
#
# LIFECYCLE (`run_job_supervisor`):
#   0. with --binary-key: fetch the binary from the binary store (boot.mojo).
#   1. an initial RUNNING heartbeat.
#   2. spawn the job (komira_supervisor's Supervisor + ChildSpec), unless a
#      stop signal arrived during 0 or 1: then the job is CANCELLED without
#      being started, and the run goes to 4.
#   3. loop, every --heartbeat-interval-secs:
#        a. drain stdout/stderr without blocking (stderr into the forensics
#           ring, stdout into the logs.txt capture and the live stream);
#        b. poll the child for exit; if it exited, go to 4;
#        c. a RUNNING heartbeat; if the reply asks to cancel, terminate the
#           child (SIGTERM, a 5 s grace, SIGKILL) and go to 4.
#      With --max-runtime-secs, every pass of the loop (once a second) also
#      checks the time since the spawn, on the monotonic clock; past the
#      limit the child is terminated the same way as on a cancel, and the
#      job is FAILED with a message naming the limit.
#      Every pass also takes the stop latch: a SIGTERM or SIGINT sent to the
#      supervisor (a platform stopping the container whose PID 1 it is) is
#      forwarded to the job's process group, with the same grace and
#      SIGKILL, and the job is CANCELLED.
#   4. classify the exit (exit 0 -> COMPLETED; a cancel or a stop signal ->
#      CANCELLED; past the maximum runtime -> FAILED with the timeout
#      message; anything else -> FAILED with a FailureReport), send the
#      terminal heartbeat (retried within a budget: finalize_heartbeat), and
#      with a log store write logs.txt (and crash_report.json on FAILED).
#
# PID 1 (`run_job_supervisor`, before anything else): the SIGTERM/SIGINT
# handler is installed (komira_supervisor.pid1; without one the kernel drops
# both for a namespace's init), and the supervisor makes itself the reaper of
# orphans (PID 1 is already; otherwise a Linux child subreaper). The job is
# spawned leading its own process group with every signal at its default
# action, so every stop (a CANCEL reply, the maximum runtime, a stop signal)
# reaches the job's descendants too, and the job does not inherit a signal the
# supervisor ignores. Each pass of the loop collects exited orphans
# (`Supervisor.reap_orphans`), so a descendant the job left behind does not
# stay a zombie. The supervisor therefore assumes it owns every child of its
# process.
#
# WHAT THE EMBEDDING BINARY SUPPLIES: the configuration (flags), a
# `HeartbeatReporter` R (`HttpHeartbeatReporter[A]` ships, with
# `NoHeartbeatAuth`), and optionally the two object stores S, any
# komira_objectstore `ConditionalWriteStore` (s3_store.mojo builds S3 ones).
#
# `JobSupervisor[R, S]` exposes the lifecycle as stepping methods
# (spawn_child / do_heartbeat / poll_and_drain / analyze_exit /
# finalize_heartbeat) so a test can drive one step at a time;
# `run_job_supervisor` composes them into the blocking loop.
#
# The Supervisor encapsulates every fd, pipe and pid; this file sees typed
# scalars and Strings. No pointer type crosses a boundary.
# =============================================================================

from std.ffi import external_call

from komira_clock import now_ns
from komira_supervisor.supervisor import (
    Supervisor,
    ChildSpec,
    ExitInfo,
)
from komira_supervisor.pid1 import (
    adopt_orphans,
    install_stop_signal_handler,
    take_stop_signal,
)
from komira_supervisor.proc_ffi import SIGINT, SIGTERM


# =============================================================================
# §0: _sleep_secs. `usleep`, not std's time.sleep: komira_async's reactor
# declares its own `nanosleep`, and a second declaration with another
# signature fails to legalize.
# =============================================================================
def _sleep_secs(secs: Int):
    """Sleep `secs` whole seconds via usleep (microsecond granularity). A
    caught stop signal ends the sleep early (the handler has no SA_RESTART)."""
    if secs <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(secs * 1_000_000))


def _sleep_ms(ms: Int):
    """Sleep `ms` milliseconds via usleep."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


# The terminal beat's retry budget (finalize_heartbeat). A platform that stops
# the container gives PID 1 a fixed window after its SIGTERM before SIGKILL,
# and the job's own grace (5 s) comes out of that window first. Grace plus
# budget is 20 s: on a platform whose window is shorter, the later retries are
# cut off by the platform's SIGKILL (the first send comes right after the
# grace).
comptime TERMINAL_BEAT_BUDGET_MS: Int = 15_000
comptime TERMINAL_BEAT_FIRST_DELAY_MS: Int = 250
comptime TERMINAL_BEAT_MAX_DELAY_MS: Int = 2_000
comptime TERMINAL_BEAT_MAX_ATTEMPTS: Int = 8

from komira_objectstore.store import ConditionalWriteStore

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import (
    JobSupervisorPhase,
    JobSupervisorState,
    FailureReport,
)
from komira_job_supervisor.boot import download_binary
from komira_job_supervisor.heartbeat_client import (
    SupervisorHeartbeat,
    HeartbeatOutcome,
    HeartbeatReporter,
    terminal_beat_retryable,
)
from komira_job_supervisor.upload import upload_crash_report, upload_logs
from komira_job_supervisor.log_streamer import LogStreamSink

import komira_log as log
from komira_log import ArgStr


# =============================================================================
# §1: stderr ring helpers.
# =============================================================================
def _split_lines(text: String) -> List[String]:
    """Split captured stderr text into lines (on '\\n'), dropping a trailing
    empty line. The supervisor keeps the last N for failure forensics."""
    var lines = List[String]()
    var cur = String("")
    var bytes = text.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(0x0A):  # newline
            lines.append(cur)
            cur = String("")
        else:
            cur += chr(Int(c))
    if cur.byte_length() > 0:
        lines.append(cur)
    return lines^


def _detect_panic(lines: List[String]) -> Optional[String]:
    """Scan the stderr ring for a panic line. Returns the first line containing
    "panic" / "panicked"."""
    for ref l in lines:
        var lb = l.as_bytes()
        # case-insensitive-ish substring scan for "panic".
        var needle = String("panic").as_bytes()
        var hn = len(lb)
        var nn = len(needle)
        var i = 0
        while i + nn <= hn:
            var matched = True
            var j = 0
            while j < nn:
                var hc = lb[i + j]
                # lowercase the haystack char.
                if hc >= UInt8(0x41) and hc <= UInt8(0x5A):
                    hc = hc + UInt8(0x20)
                if hc != needle[j]:
                    matched = False
                    break
                j += 1
            if matched:
                return Optional[String](l)
            i += 1
    return Optional[String]()


# =============================================================================
# §2: JobSupervisor, the lifecycle as stepping methods.
# =============================================================================
struct JobSupervisor[
    R: HeartbeatReporter,
    S: ConditionalWriteStore,
](Movable):
    """The supervisor for ONE job: its config, its heartbeat reporter `R`,
    the optional log store `S`, the run state, the spawned child and the
    captured output (module header)."""

    var config: JobSupervisorConfig
    var reporter: Self.R
    var log_store: Optional[Self.S]
    var state: JobSupervisorState
    var supervisor: Supervisor
    var stderr_ring: List[String]
    var stdout_ring: List[String]
    var spawned: Bool
    var child_exited: Bool
    var exit_info: ExitInfo
    # The monotonic instant (komira_clock.now_ns) of the spawn; the maximum
    # runtime counts from here.
    var spawned_at_ns: UInt64

    # Non-blocking reads arrive in chunks that do not align on lines, so each
    # stream keeps a partial-line accumulator. The stdout byte budget bounds
    # the in-memory capture and flags truncation.
    var stdout_partial: String
    var stderr_partial: String
    var stdout_bytes: Int
    var stdout_truncated: Bool
    var capture_nonblocking: Bool

    # The live stdout stream; engaged iff a log store was supplied.
    var log_sink: LogStreamSink

    def __init__(
        out self,
        var config: JobSupervisorConfig,
        var reporter: Self.R,
        var log_store: Optional[Self.S],
    ):
        var sink = LogStreamSink.disabled()
        if log_store:
            sink = LogStreamSink(
                String(config.log_prefix),
                config.log_chunk_bytes,
                config.log_flush_secs * 1000,  # secs -> ms
                True,
            )
        self.config = config^
        self.reporter = reporter^
        self.log_store = log_store^
        self.state = JobSupervisorState()
        self.supervisor = Supervisor()
        self.stderr_ring = List[String]()
        self.stdout_ring = List[String]()
        self.spawned = False
        self.child_exited = False
        self.exit_info = ExitInfo(Int32(-1), Int32(-1), Int32(-1))
        self.spawned_at_ns = UInt64(0)
        self.stdout_partial = String("")
        self.stderr_partial = String("")
        self.stdout_bytes = 0
        self.stdout_truncated = False
        self.capture_nonblocking = False
        self.log_sink = sink^

    # ---- a heartbeat value from the current state ----

    def _make_heartbeat(self, phase: JobSupervisorPhase) -> SupervisorHeartbeat:
        """Build a SupervisorHeartbeat for `phase` from the current config +
        state. A FAILED phase carries the failure forensics."""
        var failure = Optional[FailureReport]()
        if phase == JobSupervisorPhase.failed() and self.state.failure:
            failure = Optional[FailureReport](self.state.failure.value().copy())
        var msg = Optional[String]()
        if self.state.message:
            msg = Optional[String](self.state.message.value())
        return SupervisorHeartbeat(
            String(self.config.job_name),
            phase,
            String(self.config.instance_name),
            self.state.progress,
            msg^,
            failure^,
        )

    # ---- step: spawn the child ----

    def spawn_child(mut self) raises:
        """Spawn the job from config: `binary_download_path` (which is
        `job_binary_path` unless a fetched binary was written elsewhere) with
        `job_argv`."""
        var spec = ChildSpec(String(self.config.binary_download_path))
        for ref a in self.config.job_argv:
            spec.with_arg(a)
        self.spawn_child_spec(spec^)

    def spawn_child_spec(mut self, var spec: ChildSpec) raises:
        """Spawn an explicit ChildSpec (a test can pass ChildSpec.shell),
        leading its own process group with every signal at its default action
        (module header). Raises if the spawn fails."""
        spec.set_own_process_group()
        spec.set_default_signals()
        var pid = self.supervisor.spawn(spec)
        if pid <= Int32(0):
            raise Error(
                String("job supervisor: spawn failed for job ")
                + self.config.job_name
                + String(" (rc=")
                + String(Int(pid))
                + String(")")
            )
        self.spawned = True
        self.spawned_at_ns = now_ns()
        # Non-blocking capture pipes, so every loop iteration can drain what
        # is ready without parking the loop. Without this a chatty child fills
        # the ~64 KiB pipe buffer, blocks on write() and never exits.
        _ = self.supervisor.set_nonblocking(self.supervisor.stdout_fd())
        _ = self.supervisor.set_nonblocking(self.supervisor.stderr_fd())
        self.capture_nonblocking = True

    # ---- the live stdout stream ----

    def _flush_stream_to_eof(mut self):
        """On exit, write the final partial chunk (best-effort)."""
        if not self.log_sink.enabled:
            return
        if self.log_store:
            ref st = self.log_store.value()
            self.log_sink.flush_final[Self.S](st)

    def _tick_stream_timer(mut self):
        """A time-based flush opportunity, so a quiet but non-empty chunk is
        written on the interval even when no new stdout arrives."""
        if not self.log_sink.enabled:
            return
        if self.log_store:
            ref st = self.log_store.value()
            self.log_sink.maybe_flush[Self.S](st)

    # ---- step: send one heartbeat for the current RUNNING state ----

    def do_heartbeat(mut self) -> HeartbeatOutcome:
        """Report one RUNNING heartbeat. A reply asking to cancel sets
        cancel_requested (see act_on_cancel). Best-effort: a failure is an
        outcome, never a raise."""
        var hb = self._make_heartbeat(JobSupervisorPhase.running())
        var outcome = self.reporter.report(hb)
        if outcome.ok and outcome.cancel:
            self.state.cancel_requested = True
        return outcome

    # ---- step: act on a cancel request (terminate the child) ----

    def act_on_cancel(mut self, grace_ms: Int):
        """If a heartbeat reply asked to cancel, SIGTERM -> grace -> SIGKILL
        the child and mark the job CANCELLED. A no-op if the child already
        exited."""
        if not self.state.cancel_requested:
            return
        if self.child_exited:
            return
        self.exit_info = self.supervisor.terminate_with(SIGTERM, grace_ms, True)
        self.child_exited = True
        self.state.phase = JobSupervisorPhase.cancelled()

    # ---- step: act on a stop signal sent to the supervisor ----

    def act_on_stop_signal(mut self, grace_ms: Int) -> Bool:
        """Take the stop latch (komira_supervisor.pid1). With a SIGTERM or
        SIGINT caught: forward THAT signal to the job's process group, then
        `grace_ms` and SIGKILL as on a cancel, and the job is CANCELLED with a
        message naming the signal. Returns True iff a stop signal was taken.
        A signal taken before the spawn (during the fetch or the first beat)
        makes the job CANCELLED without starting it; the caller must not
        spawn it then. A signal taken after the child already exited leaves
        its result as it is (the job finished first) and still returns True,
        so the loop ends."""
        var sig = take_stop_signal()
        if sig == Int32(0):
            return False
        var name = String("SIGTERM")
        if sig == SIGINT:
            name = String("SIGINT")
        log.info["job supervisor: {} received; stopping job {}", "komira_job_supervisor"](
            ArgStr(name), ArgStr(self.config.job_name)
        )
        if not self.spawned:
            self.state.phase = JobSupervisorPhase.cancelled()
            self.state.message = Optional[String](
                String("the supervisor received ")
                + name
                + String("; the job was not started")
            )
            return True
        if self.child_exited:
            return True
        self._incremental_drain()
        self.exit_info = self.supervisor.terminate_with(sig, grace_ms, True)
        self.child_exited = True
        self._flush_stream_to_eof()
        self.state.phase = JobSupervisorPhase.cancelled()
        self.state.message = Optional[String](
            String("the supervisor received ")
            + name
            + String("; the job was stopped")
        )
        return True

    # ---- step: collect exited orphans ----

    def reap_orphans(mut self) -> Int:
        """Collect every exited child of this process except the job itself
        (module header: PID 1). Returns how many."""
        if not self.spawned:
            return 0
        return self.supervisor.reap_orphans()

    # ---- step: enforce the maximum runtime ----

    def enforce_max_runtime(mut self, now: UInt64, grace_ms: Int) -> Bool:
        """Stop the job if it has run `max_runtime_secs` or longer at the
        monotonic instant `now` (komira_clock.now_ns; a parameter so a test
        can step past the limit without waiting). Past the limit: SIGTERM ->
        `grace_ms` -> SIGKILL, as on a cancel, then FAILED with a message
        naming the limit and the FailureReport of the stopped child. Returns
        True iff it stopped the job. A no-op with no limit, before the spawn
        and after the child exited."""
        var limit = self.config.max_runtime_secs
        if limit <= 0 or not self.spawned or self.child_exited:
            return False
        if now < self.spawned_at_ns:
            return False
        var ran_ns = now - self.spawned_at_ns
        if ran_ns < UInt64(limit) * UInt64(1_000_000_000):
            return False
        # What is ready now is kept; no blocking drain after the stop, as on
        # a cancel (a process the job left behind may hold the pipes open).
        self._incremental_drain()
        self.exit_info = self.supervisor.terminate_with(SIGTERM, grace_ms, True)
        self.child_exited = True
        self._flush_stream_to_eof()
        self.state.timed_out = True
        self.state.message = Optional[String](
            String("max runtime of ")
            + String(limit)
            + String(" s exceeded; the job was stopped")
        )
        self._record_failure()
        return True

    # ---- step: incremental drain + poll the child for exit ----

    def poll_and_drain(mut self):
        """Incrementally drain BOTH capture pipes (non-blocking) AND poll the
        child for exit. This is the deadlock fix: every call drains whatever
        stdout/stderr is ready RIGHT NOW so the pipe never fills (a child that
        writes more than a pipe buffer before exiting never blocks on write()).

        Order matters: drain FIRST (relieve any pipe pressure so a blocked
        write() can complete and the child can reach exit), THEN try_wait. On
        observed exit, do a FINAL drain to EOF to capture the tail the child
        wrote between the last poll and exit. Sets child_exited + exit_info.

        Every call, the job's exit or not, also collects exited orphans
        (`reap_orphans`)."""
        _ = self.reap_orphans()
        if self.child_exited:
            return
        # 1. Relieve pipe pressure now (non-blocking — never parks the loop).
        self._incremental_drain()
        # 2. Poll for exit.
        var r = self.supervisor.try_wait()
        if r.collected:
            # waitid names one exited child at a time and stops at the job's
            # own; with the job collected, the zombies behind it are next.
            _ = self.reap_orphans()
            self.child_exited = True
            self.exit_info = ExitInfo.from_reap(r)
            # 3. FINAL drain to EOF: the write ends are closed now, so capture
            #    everything the child emitted between the last poll and exit.
            self._final_drain()
            # 4. Flush the final partial streaming chunk (best-effort). The
            #    _final_drain above already fed the tail bytes to the sink via
            #    _absorb; this flushes whatever remains under the threshold.
            self._flush_stream_to_eof()

    def _incremental_drain(mut self):
        """One non-blocking pass over BOTH pipes: read whatever is ready now and
        fold it into the partial-line accumulators / rings. Drains each stream
        in a tight inner loop until would_block / eof so a hot child can't
        outrun a single read. Never blocks (the fds are O_NONBLOCK)."""
        self._drain_stream_nb(self.supervisor.stdout_fd(), is_stdout=True)
        self._drain_stream_nb(self.supervisor.stderr_fd(), is_stdout=False)

    def _drain_stream_nb(mut self, fd: Int32, is_stdout: Bool):
        """Drain one stream non-blocking until would_block / eof / error,
        feeding each ready chunk into the per-stream partial accumulator. A
        bounded inner-loop cap (so a child that writes faster than we read can't
        spin us forever in one pass — we'll catch the rest next iteration)."""
        if fd < Int32(0):
            return
        comptime MAX_CHUNKS_PER_PASS = 256
        var chunks = 0
        while chunks < MAX_CHUNKS_PER_PASS:
            var chunk = self.supervisor.read_available(fd)
            if chunk.would_block or chunk.eof or chunk.error:
                break
            if chunk.text.byte_length() > 0:
                self._absorb(chunk.text, is_stdout)
            chunks += 1

    def _final_drain(mut self):
        """After the child has exited, drain both pipes to EOF (blocking-safe —
        the write ends are closed so drain_pipe returns promptly at EOF) to
        capture the tail, then flush any remaining partial lines."""
        var sout = self.supervisor.stdout_fd()
        if sout >= Int32(0):
            var t = self.supervisor.drain_pipe(sout)
            if t.byte_length() > 0:
                self._absorb(t, is_stdout=True)
        var serr = self.supervisor.stderr_fd()
        if serr >= Int32(0):
            var t = self.supervisor.drain_pipe(serr)
            if t.byte_length() > 0:
                self._absorb(t, is_stdout=False)
        # Flush any trailing unterminated partial line into the rings.
        if self.stdout_partial.byte_length() > 0:
            var so = self.stdout_partial
            self.stdout_partial = String("")
            self._push_stdout_line(so^)
        if self.stderr_partial.byte_length() > 0:
            var se = self.stderr_partial
            self.stderr_partial = String("")
            self._push_stderr_line(se^)

    def _absorb(mut self, text: String, is_stdout: Bool):
        """Fold a freshly-read chunk into the per-stream partial accumulator,
        flushing each complete ('\\n'-terminated) line into the ring. Chunks do
        NOT align on line boundaries, so a partial line is held until the next
        chunk completes it (or _final_drain flushes the tail).

        For STDOUT, the raw chunk also goes to the stream sink BEFORE line
        parsing, so the `{log_prefix}/chunks/{n}.log` objects concatenate to
        the child's exact stdout bytes. The in-memory ring (bounded by
        --max-stdout-bytes) is only the logs.txt summary."""
        if is_stdout and self.log_sink.enabled and self.log_store:
            ref st = self.log_store.value()
            self.log_sink.feed_stdout[Self.S](text, st)
        var bytes = text.as_bytes()
        for i in range(len(bytes)):
            var c = bytes[i]
            if c == UInt8(0x0A):  # newline -> a complete line
                if is_stdout:
                    var line = self.stdout_partial
                    self.stdout_partial = String("")
                    self._push_stdout_line(line^)
                else:
                    var line = self.stderr_partial
                    self.stderr_partial = String("")
                    self._push_stderr_line(line^)
            else:
                if is_stdout:
                    self.stdout_partial += chr(Int(c))
                else:
                    self.stderr_partial += chr(Int(c))

    def _push_stdout_line(mut self, var line: String):
        """Append one stdout line to the stdout ring, enforcing the byte budget
        (max_stdout_bytes). Once the budget is exceeded we stop appending and
        set stdout_truncated (the post-exit logs.txt notes the truncation)."""
        var line_len = line.byte_length() + 1  # +1 for the dropped '\n'
        if self.stdout_bytes + line_len > self.config.max_stdout_bytes:
            if not self.stdout_truncated:
                self.stdout_truncated = True
                self.stdout_ring.append(
                    String("...[stdout truncated: exceeded ")
                    + String(self.config.max_stdout_bytes)
                    + String(" bytes]...")
                )
            return
        self.stdout_bytes += line_len
        self.stdout_ring.append(line^)

    def _push_stderr_line(mut self, var line: String):
        """Append one stderr line to the stderr ring, keeping only the LAST
        max_stderr_lines (a bounded ring — drop the oldest when full). This is
        the failure-forensics tail."""
        self.stderr_ring.append(line^)
        var cap = self.config.max_stderr_lines
        if cap > 0 and len(self.stderr_ring) > cap:
            # Drop the oldest lines to keep only the last `cap`.
            var drop = len(self.stderr_ring) - cap
            var kept = List[String]()
            for i in range(drop, len(self.stderr_ring)):
                kept.append(self.stderr_ring[i])
            self.stderr_ring = kept^

    # ---- step: analyze the exit + send the terminal heartbeat ----

    def analyze_exit(mut self):
        """Map ExitInfo -> the terminal phase:
          * cancel_requested        -> CANCELLED (already set by act_on_cancel).
          * exit_code == 0          -> COMPLETED.
          * else (non-zero / signal)-> FAILED, build a FailureReport.
        Must be called after the child has exited (child_exited == True)."""
        if self.state.phase == JobSupervisorPhase.cancelled():
            # act_on_cancel already finalized the phase.
            return
        if self.state.timed_out:
            # enforce_max_runtime already finalized the phase and report.
            return
        if (
            self.exit_info.exit_code == Int32(0)
            and self.exit_info.signal == Int32(-1)
        ):
            self.state.phase = JobSupervisorPhase.completed()
            return
        self._record_failure()

    def _record_failure(mut self):
        """Phase FAILED, with the forensic report of the reaped child."""
        self.state.phase = JobSupervisorPhase.failed()
        var exit_code = Optional[Int32]()
        if self.exit_info.exit_code >= Int32(0):
            exit_code = Optional[Int32](self.exit_info.exit_code)
        var signal = Optional[Int32]()
        if self.exit_info.signal >= Int32(0):
            signal = Optional[Int32](self.exit_info.signal)
        var tail = List[String]()
        for ref l in self.stderr_ring:
            tail.append(l)
        var panic = _detect_panic(self.stderr_ring)
        self.state.failure = Optional[FailureReport](
            FailureReport(exit_code, signal, tail^, panic^)
        )

    def finalize_heartbeat(mut self) -> HeartbeatOutcome:
        """Report the TERMINAL heartbeat (COMPLETED / FAILED / CANCELLED),
        retried within the default budget (`finalize_heartbeat_within`)."""
        return self.finalize_heartbeat_within(
            TERMINAL_BEAT_BUDGET_MS,
            TERMINAL_BEAT_FIRST_DELAY_MS,
            TERMINAL_BEAT_MAX_ATTEMPTS,
        )

    def finalize_heartbeat_within(
        mut self, budget_ms: Int, first_delay_ms: Int, max_attempts: Int
    ) -> HeartbeatOutcome:
        """Report the terminal heartbeat; while the outcome is a retryable
        failure (`terminal_beat_retryable`: no reply, 408, 429, 5xx, or a
        credential that could not be read), send it again after
        `first_delay_ms`, doubling up to TERMINAL_BEAT_MAX_DELAY_MS, for at
        most `max_attempts` sends and only while the next send would start
        within `budget_ms` of the first. Returns the last outcome. A refusal
        that repeating cannot change (a 4xx, a credential refused in the
        clear) is returned after one send.

        The terminal beat is the one that says how the job ended; a RUNNING
        beat is not retried, because the next one follows within an
        interval."""
        var hb = self._make_heartbeat(self.state.phase)
        var start = now_ns()
        var delay = first_delay_ms
        var attempt = 1
        while True:
            var outcome = self.reporter.report(hb)
            if outcome.ok or not terminal_beat_retryable(outcome.status):
                return outcome
            if attempt >= max_attempts:
                return outcome
            var elapsed_ms = Int((now_ns() - start) // UInt64(1_000_000))
            if elapsed_ms + delay > budget_ms:
                return outcome
            log.warn[
                "job supervisor: terminal heartbeat failed (status {}); retry {}",
                "komira_job_supervisor",
            ](ArgStr(String(outcome.status)), ArgStr(String(attempt)))
            _sleep_ms(delay)
            delay = min(delay * 2, TERMINAL_BEAT_MAX_DELAY_MS)
            attempt += 1

    def log_lines(self) -> List[String]:
        """The logs.txt content: the captured stdout lines, then the stderr
        lines."""
        var lines = List[String]()
        for ref l in self.stdout_ring:
            lines.append(l)
        for ref l in self.stderr_ring:
            lines.append(l)
        return lines^

    def upload_terminal_artifacts(mut self):
        """With a log store: write logs.txt, and crash_report.json on FAILED.
        Best-effort; a no-op without a log store."""
        if not self.log_store:
            return
        ref st = self.log_store.value()
        _ = upload_logs[Self.S](self.config, st, self.log_lines())
        if self.state.phase == JobSupervisorPhase.failed() and self.state.failure:
            _ = upload_crash_report[Self.S](
                self.config, st, self.state.failure.value().copy()
            )

    def terminal_phase(self) -> JobSupervisorPhase:
        return self.state.phase


# =============================================================================
# §3: run_job_supervisor, the blocking loop.
# =============================================================================
def run_job_supervisor[
    R: HeartbeatReporter,
    S: ConditionalWriteStore,
](
    var config: JobSupervisorConfig,
    var reporter: R,
    var binary_store: Optional[S],
    var log_store: Optional[S],
) raises -> JobSupervisorPhase:
    """Run one job to its end and return its terminal phase (module header).

    `binary_store` is required iff the config names a --binary-key;
    `log_store` is optional (without it there is no live stream and no
    terminal upload). Raises only before the job is spawned (a missing
    store, a failed fetch, a failed spawn); after that every failure is
    reported, not raised."""
    comptime GRACE_MS = 5000
    # PID 1 (module header): before anything else, so a stop that arrives
    # during the fetch or the first beat is latched, not fatal.
    install_stop_signal_handler()
    if not adopt_orphans():
        log.warn[
            "job supervisor: cannot become the reaper of orphans here; {}",
            "komira_job_supervisor",
        ](ArgStr(String("init collects them instead")))
    if config.uses_binary_store():
        if not binary_store:
            raise Error(
                "job supervisor: --binary-key is set but no binary store was"
                " supplied"
            )
        _ = download_binary[S](config, binary_store.value())
    _ = binary_store^

    var job_supervisor = JobSupervisor[R, S](config^, reporter^, log_store^)

    # 1. initial RUNNING heartbeat.
    _ = job_supervisor.do_heartbeat()

    # 2. spawn the job, unless a stop arrived during the fetch or the first
    # beat: then it is CANCELLED without being started.
    var stopped_before_spawn = job_supervisor.act_on_stop_signal(GRACE_MS)
    if not stopped_before_spawn:
        job_supervisor.spawn_child()

    # 3. poll-then-heartbeat loop.
    var hb_interval = job_supervisor.config.heartbeat_interval_secs
    while not stopped_before_spawn:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        if job_supervisor.act_on_stop_signal(GRACE_MS):
            break
        if job_supervisor.enforce_max_runtime(now_ns(), GRACE_MS):
            break
        var outcome = job_supervisor.do_heartbeat()
        if outcome.ok and outcome.cancel:
            job_supervisor.act_on_cancel(GRACE_MS)
            break
        var slept = 0
        while slept < hb_interval:
            _sleep_secs(1)
            slept += 1
            # Drain and check for exit every second so a fast child is
            # noticed promptly.
            job_supervisor.poll_and_drain()
            if job_supervisor.child_exited:
                break
            if job_supervisor.act_on_stop_signal(GRACE_MS):
                break
            if job_supervisor.enforce_max_runtime(now_ns(), GRACE_MS):
                break
            job_supervisor._tick_stream_timer()
        if job_supervisor.child_exited:
            break

    # 4. classify, report the terminal phase, write the record.
    _ = job_supervisor.reap_orphans()
    job_supervisor.analyze_exit()
    _ = job_supervisor.finalize_heartbeat()
    job_supervisor.upload_terminal_artifacts()

    var phase = job_supervisor.terminal_phase()
    log.info["job supervisor: job {} finished phase={}", "komira_job_supervisor"](
        ArgStr(job_supervisor.config.job_name),
        ArgStr(String(phase.wire_str())),
    )
    return phase
