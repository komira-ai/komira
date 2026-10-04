# =============================================================================
# komira_job_supervisor/job_supervisor.mojo — the job supervisor run loop.
# =============================================================================
#
# The pod-side supervisor: spawn the job binary, heartbeat the job-manager,
# handle cancel, and on child exit analyze the result + send a terminal
# heartbeat.
#
# LIFECYCLE:
#   1. send the INITIAL Running heartbeat (ASSIGNED -> RUNNING in the DB).
#   2. Supervisor.spawn(ChildSpec) the job binary.
#   3. LOOP, every heartbeat_interval:
#        a. drain the child's stderr into the ring (forensics).
#        b. poll the child for exit (try_wait); if exited, break to (4).
#        c. POST a Running heartbeat; if the response is {cancel:true},
#           Supervisor.terminate(grace) the child + mark CANCELLED + break.
#   4. ANALYZE the exit (ExitInfo -> Completed / Cancelled / Failed) ->
#      build a FailureReport on Failed (exit_code / signal / stderr_tail /
#      panic_message) -> send the TERMINAL heartbeat (COMPLETED/FAILED/
#      CANCELLED) -> return.
#
# THE `JobSupervisor` STRUCT vs `run_job_supervisor`: the lifecycle is decomposed into discrete
# stepping methods on an `JobSupervisor` struct (spawn_child / do_heartbeat /
# poll_and_drain / finalize) so a SAME-PROCESS e2e test can INTERLEAVE the
# job supervisor's heartbeat POSTs with the job-manager service's `run_once` serving (the
# job-supervisor-loop-wants-to-block vs server-loop-wants-to-block problem the brief
# flagged). `run_job_supervisor(config)` composes the same steps into the continuous
# blocking loop the prod binary runs.
#
# MVP SCOPE (deferred, noted in __init__.mojo): S3 binary download, S3 log
# upload, crash-report-to-S3, reactor-driven async stderr drain (this uses a
# simple post-exit `drain_pipe` + an incremental pre-exit drain), proto-binary
# heartbeat (this uses proto3-JSON).
#
# ENCAPSULATION + gap6: the Supervisor encapsulates ALL fd/pipe/pid internals
# (komira_supervisor) — the job supervisor only sees typed scalars + Strings. The stderr
# ring is owned Strings. No UnsafePointer crosses any boundary; no wildcard
# origin. Mojo 1.0.0b1.
# =============================================================================

from std.ffi import external_call

from komira_supervisor.supervisor import (
    Supervisor,
    ChildSpec,
    ExitInfo,
)


# =============================================================================
# §0 — _sleep_secs — a usleep-backed second-granularity pause.
#
# We use `usleep` (single-arg, returns Int32) instead of stdlib `time.sleep`
# (which declares `nanosleep`): an AOT binary that links komira_async (whose
# reactor declares its OWN `external_call["nanosleep", ...]`) hit a "conflicting
# nanosleep signature" legalization failure. `usleep` is a DISTINCT symbol from
# either nanosleep decl, so it sidesteps the conflict (same fix as
# komira_supervisor._sleep_ms).
# =============================================================================
def _sleep_secs(secs: Int):
    """Sleep `secs` whole seconds via usleep (microsecond granularity)."""
    if secs <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(secs * 1_000_000))

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase, JobSupervisorState, FailureReport
from komira_job_supervisor.boot import (
    download_binary,
    make_s3_client_from_chain,
    make_s3_client_over,
    make_tls_s3_client_from_chain,
    mk_job_supervisor_s3_plain_connector,
    mk_job_supervisor_s3_tls_connector,
)
from komira_job_supervisor.heartbeat_client import (
    SupervisorHeartbeat,
    HeartbeatOutcome,
    send_heartbeat_blocking,
)
from komira_job_supervisor.upload import upload_crash_report, upload_logs
from komira_job_supervisor.log_streamer import LogStreamSink

from komira_job_supervisor.s3_client import JobSupervisorS3Client
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

import komira_log as log
from komira_log import ArgStr


# =============================================================================
# §1 — stderr ring helpers.
# =============================================================================
def _split_lines(text: String) -> List[String]:
    """Split captured stderr text into lines (on '\\n'), dropping a trailing
    empty line. The job supervisor keeps the last N for failure forensics."""
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
# §2 — JobSupervisor — the supervisor state machine, decomposed into stepping methods.
# =============================================================================
struct JobSupervisor[
    C: Connector,
](Movable):
    """The job supervisor for ONE job. Owns the `JobSupervisorConfig`, the
    `JobSupervisorState`, the `Supervisor` (the spawned child), and the stderr ring.

    The stepping methods (spawn_child / do_heartbeat / poll_and_drain /
    finalize_heartbeat) are the SAME steps `run_job_supervisor` composes into the
    continuous loop — exposed individually so a same-process e2e can interleave
    them with the job-manager service's serving.

    ★ `C` IS THE **S3** TRANSPORT, AND ONLY THE S3 TRANSPORT.
    `KernelTcpConnector` for MinIO/LocalStack over plaintext,
    `TlsConnector[KernelTcpConnector]` for real S3 or an `https://` endpoint.
    `run_job_supervisor` picks it from `JobSupervisorConfig.s3_uses_tls()`; the aliases
    `PlainJobSupervisor` / `TlsJobSupervisor` below are the two instantiations that exist.

    ⚠ THE HEARTBEAT TRANSPORT IS **NOT** `C`, AND THAT ASYMMETRY IS DELIBERATE
    RATHER THAN AN OVERSIGHT. The heartbeat client is built per-POST inside
    `send_heartbeat_blocking` and lives no longer than the call, so its
    transport can be a RUNTIME bool (`config.jm_uses_tls()`) with no type
    parameter at all. The S3 client is a FIELD -- it outlives the call and is
    handed to `LogStreamSink` on every drain -- so its transport has to be in
    the type. Making both type parameters would force every construction site to
    name two, and the second would always be inferable from config."""

    var config: JobSupervisorConfig
    var state: JobSupervisorState
    var supervisor: Supervisor
    var stderr_ring: List[String]
    var stdout_ring: List[String]
    var spawned: Bool
    var child_exited: Bool
    var exit_info: ExitInfo

    # Incremental-drain state (the deadlock fix). Non-blocking reads arrive in
    # arbitrary chunks that do NOT align on line boundaries, so each stream
    # carries a partial-line accumulator; a complete line (terminated by '\n')
    # is flushed into the corresponding ring. The stdout byte budget caps the
    # in-memory capture (a chatty job can produce unbounded stdout — we bound
    # it to avoid a new OOM and flag truncation).
    var stdout_partial: String
    var stderr_partial: String
    var stdout_bytes: Int       # running total of stdout bytes captured
    var stdout_truncated: Bool  # set once max_stdout_bytes is exceeded
    var capture_nonblocking: Bool  # fds set O_NONBLOCK yet?

    # Streaming-log state. `log_sink` accumulates stdout into 64 KiB / 10s
    # chunks; `stream_client` is the attached S3 client used to PUT each chunk
    # DURING the run. Both are engaged only when a log bucket is configured AND
    # a client is attached (attach_stream_client) — otherwise the sink is
    # `disabled()` and the job supervisor keeps the in-memory logs.txt path.
    var log_sink: LogStreamSink
    var stream_client: Optional[JobSupervisorS3Client[Self.C]]

    def __init__(out self, var config: JobSupervisorConfig):
        # Build the (initially disabled) streaming sink BEFORE moving config.
        var sink = LogStreamSink.disabled()
        if config.log_bucket:
            sink = LogStreamSink(
                String(config.log_bucket.value()),
                String(config.job_id),
                config.log_chunk_bytes,
                config.log_flush_secs * 1000,  # secs -> ms
                False,  # not enabled until a client is attached
            )
        self.config = config^
        self.state = JobSupervisorState()
        self.supervisor = Supervisor()
        self.stderr_ring = List[String]()
        self.stdout_ring = List[String]()
        self.spawned = False
        self.child_exited = False
        self.exit_info = ExitInfo(Int32(-1), Int32(-1), Int32(-1))
        self.stdout_partial = String("")
        self.stderr_partial = String("")
        self.stdout_bytes = 0
        self.stdout_truncated = False
        self.capture_nonblocking = False
        self.log_sink = sink^
        self.stream_client = Optional[JobSupervisorS3Client[Self.C]]()

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
            String(self.config.job_id),
            phase,
            String(self.config.pod_name),
            self.state.progress,
            msg^,
            failure^,
        )

    # ---- step: spawn the child ----

    def spawn_child(mut self) raises:
        """Spawn the job binary (MVP: a local path + argv). The trivial-child
        e2e seeds a `ChildSpec.shell(...)` via `spawn_child_spec` instead — the
        prod path builds the spec from config here. When an S3 binary was
        downloaded, `binary_download_path` is where it landed (defaults to
        `job_binary_path` for the local-binary MVP path)."""
        var spec = ChildSpec(String(self.config.binary_download_path))
        for ref a in self.config.job_argv:
            spec.with_arg(a)
        self.spawn_child_spec(spec^)

    def spawn_child_spec(mut self, var spec: ChildSpec) raises:
        """Spawn an explicit ChildSpec (the e2e uses ChildSpec.shell for a
        deterministic trivial child). Raises if posix_spawn fails."""
        var pid = self.supervisor.spawn(spec)
        if pid <= Int32(0):
            raise Error(
                String("job supervisor: spawn failed for job ")
                + self.config.job_id
                + String(" (rc=")
                + String(Int(pid))
                + String(")")
            )
        self.spawned = True
        # Make the capture-pipe read ends non-blocking so the incremental drain
        # read (read_available) can run every loop iteration WITHOUT parking the
        # heartbeat loop. This is the core of the deadlock fix: without it a
        # chatty child fills the ~64 KiB pipe buffer, blocks on write(), and
        # never exits, so the exit-poll never fires.
        _ = self.supervisor.set_nonblocking(self.supervisor.stdout_fd())
        _ = self.supervisor.set_nonblocking(self.supervisor.stderr_fd())
        self.capture_nonblocking = True

    # ---- streaming logs: attach the S3 client + engage the sink ----

    def attach_stream_client(mut self, var client: JobSupervisorS3Client[Self.C]):
        """Attach an S3 client for LIVE log streaming and engage the sink. Only
        engages when a log bucket is configured (the sink was built non-disabled
        in __init__ in that case); a no-op effect on a no-bucket config (the
        sink stays disabled, the client is simply held). Call BEFORE spawn so the
        first drained stdout streams. Idempotent — re-attaching replaces the
        client."""
        self.stream_client = Optional[JobSupervisorS3Client[Self.C]](client^)
        if self.config.log_bucket:
            self.log_sink.enabled = True

    def _flush_stream_to_eof(mut self):
        """On terminal, flush the final partial chunk through the attached
        client (best-effort). A no-op when streaming is not engaged."""
        if not self.log_sink.enabled:
            return
        if self.stream_client:
            ref c = self.stream_client.value()
            self.log_sink.flush_final[Self.C](c)

    def _tick_stream_timer(mut self):
        """Time-based flush opportunity (called from the heartbeat loop so a
        quiet-but-nonempty chunk flushes on the interval even when no new stdout
        arrives). A no-op when streaming is not engaged."""
        if not self.log_sink.enabled:
            return
        if self.stream_client:
            ref c = self.stream_client.value()
            self.log_sink.maybe_flush[Self.C](c)

    # ---- step: send one heartbeat for the current RUNNING state ----

    def do_heartbeat(mut self) -> HeartbeatOutcome:
        """POST one RUNNING heartbeat. On {cancel:true}, mark
        cancel_requested (the caller acts on it — see act_on_cancel). Best-effort
        — a network failure is logged + swallowed (never crashes the loop)."""
        var hb = self._make_heartbeat(JobSupervisorPhase.running())
        var outcome = send_heartbeat_blocking(
            self.config.jm_host,
            self.config.jm_port,
            hb,
            self.config.jm_uses_tls(),
            self.config.jm_auth_mode,
            self.config.jm_auth_audience(),
        )
        if outcome.ok and outcome.cancel:
            self.state.cancel_requested = True
        return outcome

    # ---- step: act on a cancel request (terminate the child) ----

    def act_on_cancel(mut self, grace_ms: Int):
        """If the job-manager requested cancellation, SIGTERM->grace->SIGKILL
        the child and mark the job supervisor CANCELLED. Idempotent: a no-op if the child
        already exited."""
        if not self.state.cancel_requested:
            return
        if self.child_exited:
            return
        self.exit_info = self.supervisor.terminate(grace_ms)
        self.child_exited = True
        self.state.phase = JobSupervisorPhase.cancelled()

    # ---- step: incremental drain + poll the child for exit ----

    def poll_and_drain(mut self):
        """Incrementally drain BOTH capture pipes (non-blocking) AND poll the
        child for exit. This is the deadlock fix: every call drains whatever
        stdout/stderr is ready RIGHT NOW so the pipe never fills (a child that
        writes >64 KiB before exiting no longer blocks on write() forever).

        Order matters: drain FIRST (relieve any pipe pressure so a blocked
        write() can complete and the child can reach exit), THEN try_wait. On
        observed exit, do a FINAL drain to EOF to capture the tail the child
        wrote between the last poll and exit. Sets child_exited + exit_info."""
        if self.child_exited:
            return
        # 1. Relieve pipe pressure now (non-blocking — never parks the loop).
        self._incremental_drain()
        # 2. Poll for exit.
        var r = self.supervisor.try_wait()
        if r.collected:
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

        For STDOUT, the RAW byte chunk is ALSO fed to the streaming sink BEFORE
        line-parsing — the streamed `{job_id}/chunks/{n}.log` objects reconstruct
        (by concatenation) to the child's exact stdout byte stream, newlines and
        all. This is what makes logs visible LIVE during the run and removes the
        in-memory byte cap as the limit (only the current sub-threshold chunk
        lives in memory). The in-memory stdout ring + its byte budget remain for
        the optional terminal logs.txt summary, but no longer bound total
        stdout."""
        if is_stdout and self.log_sink.enabled and self.stream_client:
            ref c = self.stream_client.value()
            self.log_sink.feed_stdout(text, c)
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
        if (
            self.exit_info.exit_code == Int32(0)
            and self.exit_info.signal == Int32(-1)
        ):
            self.state.phase = JobSupervisorPhase.completed()
            return
        # Failed — build the forensic report.
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
            FailureReport(exit_code, signal, tail^, panic^, Optional[Int64]())
        )

    def finalize_heartbeat(mut self) -> HeartbeatOutcome:
        """Send the TERMINAL heartbeat (the current terminal phase) so the DB
        transitions COMPLETED / FAILED / CANCELLED. Best-effort."""
        var hb = self._make_heartbeat(self.state.phase)
        return send_heartbeat_blocking(
            self.config.jm_host,
            self.config.jm_port,
            hb,
            self.config.jm_uses_tls(),
            self.config.jm_auth_mode,
            self.config.jm_auth_audience(),
        )

    def log_lines(self) -> List[String]:
        """Assemble the captured log lines for upload: stdout first, then
        stderr (the MVP single-object `logs.txt` content). A v0.5 hardening
        splits stdout / stderr into separate objects + chunks them."""
        var lines = List[String]()
        for ref l in self.stdout_ring:
            lines.append(l)
        for ref l in self.stderr_ring:
            lines.append(l)
        return lines^

    def upload_terminal_artifacts(mut self) raises:
        """(DEPLOYMENT-REAL) Best-effort terminal S3 upload: logs.txt always,
        plus crash_report.json on FAILED. Builds a fresh production JobSupervisorS3Client
        (credentials via the chain + clock via the helper). The per-upload
        failures are swallowed inside upload_logs / upload_crash_report (they
        return Bool); this method only raises if the client itself can't be
        constructed (e.g. no credentials), which the caller treats as
        best-effort."""
        if self.config.s3_uses_tls():
            var tls_client = make_tls_s3_client_from_chain(
                self.config.s3_region, self.config.s3_endpoint
            )
            _ = upload_logs[TlsConnector[KernelTcpConnector]](
                self.config, tls_client, self.log_lines()
            )
            if self.state.phase == JobSupervisorPhase.failed() and self.state.failure:
                _ = upload_crash_report[TlsConnector[KernelTcpConnector]](
                    self.config,
                    tls_client,
                    self.state.failure.value().copy(),
                )
            return
        var client = make_s3_client_from_chain(
            self.config.s3_region, self.config.s3_endpoint
        )
        _ = upload_logs[KernelTcpConnector](
            self.config, client, self.log_lines()
        )
        if self.state.phase == JobSupervisorPhase.failed() and self.state.failure:
            _ = upload_crash_report[KernelTcpConnector](
                self.config, client, self.state.failure.value().copy()
            )

    def terminal_phase(self) -> JobSupervisorPhase:
        return self.state.phase


# =============================================================================
# §3 — run_job_supervisor — the continuous blocking loop (the prod path).
# =============================================================================
# The two instantiations that exist. Named so a call site says which transport
# it means instead of spelling a nested generic.
comptime PlainJobSupervisor = JobSupervisor[KernelTcpConnector]
comptime TlsJobSupervisor = JobSupervisor[TlsConnector[KernelTcpConnector]]


def run_job_supervisor(var config: JobSupervisorConfig) raises:
    """The prod job supervisor lifecycle, over the S3 transport the CONFIG selects.

    ★ THIS IS THE ONE PLACE THE JOB SUPERVISOR'S S3 TRANSPORT IS CHOSEN. When there
    was no choice to make, `JobSupervisor` held a plaintext S3 client and the binary download, the live log stream
    and the terminal upload were all plaintext, unconditionally. A job supervisor
    pointed at real S3 therefore signed a correct SigV4 request for an
    `https://` URL -- `S3Config.aws(region)` is HTTPS -- and sent it in the
    clear to port 443.

    `s3_uses_tls()` is derived from the endpoint (absent => real AWS => TLS;
    otherwise the endpoint's own scheme), so a MinIO deploy keeps the plaintext
    arm byte-for-byte and needs no new env var to do it.

    ⚠ THE BRANCH IS AT THE TOP AND MONOMORPHISES THE WHOLE LOOP. It is not a
    per-call dispatch: `run_job_supervisor_over[C]` is instantiated twice and each
    instantiation is entirely one transport, so no code path can mix them."""
    if config.s3_uses_tls():
        run_job_supervisor_over[TlsConnector[KernelTcpConnector]](
            config^, mk_job_supervisor_s3_tls_connector
        )
    else:
        run_job_supervisor_over[KernelTcpConnector](
            config^, mk_job_supervisor_s3_plain_connector
        )


def run_job_supervisor_over[
    C: Connector,
](
    var config: JobSupervisorConfig,
    mk_connector: def () raises thin -> C,
) raises:
    """The prod job supervisor lifecycle over an EXPLICIT S3 transport `C`: initial
    Running heartbeat -> spawn -> the poll-then-heartbeat loop (terminate on
    cancel) -> analyze exit -> terminal heartbeat. Blocks until the child exits
    (or is cancelled). `run_job_supervisor` above is the entry the prod binary's `main`
    calls; this is what it dispatches to.

    MVP: a simple poll-then-sleep loop (reactor-async drain deferred). The grace
    window for a cancel is 5s (5000ms).

    DEPLOYMENT-REAL: when `config.binary_s3_uri` is set, the job supervisor downloads +
    SHA-verifies + chmods the binary from S3 BEFORE spawn (reusing the
    production JobSupervisorS3Client + the credential chain + the clock helper), and on
    terminal uploads logs (+ a crash-report on FAILED) to the log bucket. When
    no S3 URI is configured the job supervisor runs the LOCAL job_binary_path and skips
    the S3 path entirely (the MVP / in-process e2e path)."""
    comptime GRACE_MS = 5000
    var uses_s3 = config.uses_s3_binary()
    var job_supervisor = JobSupervisor[C](config^)

    # 0. (DEPLOYMENT-REAL) download the job binary from S3 before spawn.
    if uses_s3:
        var dl_client = make_s3_client_over[C](
            mk_connector, job_supervisor.config.s3_region, job_supervisor.config.s3_endpoint
        )
        _ = download_binary[C](job_supervisor.config, dl_client)

    # 1. initial Running heartbeat (ASSIGNED -> RUNNING).
    _ = job_supervisor.do_heartbeat()

    # 1b. (DEPLOYMENT-REAL) engage LIVE log streaming when a log bucket is
    #     configured: attach a fresh production S3 client so each drained stdout
    #     chunk PUTs to `{log_bucket}/{job_id}/chunks/{n}.log` DURING the run.
    #     Best-effort — a client-construction failure must NOT abort the job, so
    #     it is swallowed (the terminal logs.txt path still runs).
    if job_supervisor.config.log_bucket:
        try:
            var stream_client = make_s3_client_over[C](
                mk_connector, job_supervisor.config.s3_region, job_supervisor.config.s3_endpoint
            )
            job_supervisor.attach_stream_client(stream_client^)
        except e:
            log.warn[
                "job supervisor: log-stream client build failed (best-effort, falling"
                " back to terminal logs.txt): {}",
                "komira_job_supervisor",
            ](ArgStr(String(e)))

    # 2. spawn the job binary.
    job_supervisor.spawn_child()

    # 3. poll-then-heartbeat loop.
    var hb_interval = job_supervisor.config.heartbeat_interval_secs
    while True:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        var outcome = job_supervisor.do_heartbeat()
        if outcome.ok and outcome.cancel:
            job_supervisor.act_on_cancel(GRACE_MS)
            break
        # Sleep the heartbeat interval (MVP: a coarse whole-second sleep; the
        # reactor-deadline await is the deferred hardening).
        var slept = 0
        while slept < hb_interval:
            _sleep_secs(1)
            slept += 1
            # Drain + check exit each second so a fast child is noticed promptly.
            job_supervisor.poll_and_drain()
            if job_supervisor.child_exited:
                break
            # Time-based streaming flush: a quiet-but-nonempty chunk flushes on
            # the flush interval even when no new stdout arrived this second.
            job_supervisor._tick_stream_timer()
        if job_supervisor.child_exited:
            break

    # 4. analyze the exit + send the terminal heartbeat.
    job_supervisor.analyze_exit()
    _ = job_supervisor.finalize_heartbeat()

    # 5. (DEPLOYMENT-REAL) best-effort S3 upload of logs (+ crash-report on
    #    FAILED) to the log bucket. Skipped when no log bucket is configured.
    #    A fresh client is built (the download client was dropped after spawn)
    #    so credentials/clock are re-resolved at terminal time.
    if job_supervisor.config.log_bucket:
        try:
            job_supervisor.upload_terminal_artifacts()
        except e:
            # Best-effort: the heartbeat already carried the forensics.
            log.warn[
                "job supervisor: terminal S3 upload failed (best-effort): {}",
                "komira_job_supervisor",
            ](ArgStr(String(e)))

    log.info["job supervisor: job {} finished phase={}", "komira_job_supervisor"](
        ArgStr(job_supervisor.config.job_id),
        ArgStr(job_supervisor.terminal_phase().wire_str()),
    )
