# =============================================================================
# komira_agent/log_streamer.mojo — streaming/chunked stdout -> S3 DURING the run.
# =============================================================================
#
# The deployment-real LIVE log-streaming path: instead of buffering all of
# stdout in memory and uploading one `logs.txt` on exit, the agent accumulates
# the stdout bytes drained each loop iteration into a CURRENT-CHUNK buffer and
# flushes that chunk to `{log_bucket}/{job_id}/chunks/{n}.log` (n = a monotonic
# counter) as soon as it crosses a BYTE THRESHOLD (default 64 KiB) OR a FLUSH
# INTERVAL elapses (default ~10s). On terminal it flushes the final partial
# chunk. The effect: logs are visible LIVE in S3 while the job runs, and a long
# chatty job is no longer capped at the in-memory byte bound — only the current
# (sub-threshold) chunk lives in memory at a time.
#
# BEST-EFFORT: a failed chunk upload must NOT crash the agent or
# interrupt the child. `flush_current` tries the `put_object` once, then retries
# ONCE, then DROPS the chunk (logging to stderr) and moves on. The chunk counter
# still advances on a dropped chunk so a later partial-success listing reflects
# the gap rather than silently re-using an index.
#
# WIRED INTO THE DRAIN LOOP: the agent's existing `poll_and_drain` already pulls
# stdout incrementally (the deadlock-fix non-blocking drain). The streaming sink
# is fed the SAME stdout bytes as they are absorbed (see Agent._absorb feeding
# `feed_stdout`). Streaming is engaged ONLY when an S3 `log_bucket` is configured
# AND an S3 client is attached (`attach_client`); the no-S3 in-process e2e keeps
# the no-streaming path (the sink is simply never fed/flushed). The stderr ring
# (last-N for failure forensics) is unaffected — only stdout streams.
#
# ENCAPSULATION + gap6: the chunk buffer is an OWNED `List[UInt8]`; the upload
# bytes are an owned `List[UInt8]`; the S3 client is passed by `mut` reference to
# the flush methods (never stored as a wildcard-origin field — the sink holds NO
# pointer). No UnsafePointer crosses any boundary; no wildcard origin; no
# byte-slab with heap-owning element. Mojo 1.0.0b1.
# =============================================================================

from komira_agent.s3_client import AgentS3Client
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_clock import now_unix_ms

import komira_log as log
from komira_log import ArgStr, ArgI64


# =============================================================================
# §0 — defaults.
# =============================================================================
comptime DEFAULT_CHUNK_BYTES = 64 * 1024  # 64 KiB flush-by-size threshold
comptime DEFAULT_FLUSH_MS = 10_000  # ~10s flush-by-time interval


# =============================================================================
# §1 — LogStreamSink — the current-chunk accumulator + flush policy.
# =============================================================================
struct LogStreamSink(Movable):
    """Accumulate stdout bytes into a current chunk and flush it to
    `{log_bucket}/{job_id}/chunks/{n}.log` on a byte-threshold OR a
    flush-interval, best-effort.

      bucket          — the log bucket (only set when streaming is engaged).
      job_id          — the hyphenated job UUID (the key prefix).
      chunk_bytes     — flush-by-size threshold (>= this many buffered bytes
                        triggers a flush). Defaulted to 64 KiB; 0/neg => default.
      flush_ms        — flush-by-time interval in ms. Defaulted to ~10s;
                        0/neg => default.
      enabled         — True iff streaming is engaged (a log bucket is set). When
                        False, feed/flush are no-ops (the no-S3 path).

    Working state:
      current_chunk   — the owned in-flight chunk buffer (bytes since last flush).
      chunk_index     — the monotonic next-chunk counter.
      last_flush_ms   — wall-clock ms of the last flush (or sink start); the
                        flush-interval is measured against this.
      uploaded_count  — count of chunks SUCCESSFULLY put (for diagnostics/tests).
    """

    var bucket: String
    var job_id: String
    var chunk_bytes: Int
    var flush_ms: Int
    var enabled: Bool

    var current_chunk: List[UInt8]
    var chunk_index: Int
    var last_flush_ms: Int64
    var uploaded_count: Int

    def __init__(
        out self,
        var bucket: String,
        var job_id: String,
        chunk_bytes: Int,
        flush_ms: Int,
        enabled: Bool,
    ):
        self.bucket = bucket^
        self.job_id = job_id^
        self.chunk_bytes = (
            chunk_bytes if chunk_bytes > 0 else DEFAULT_CHUNK_BYTES
        )
        self.flush_ms = flush_ms if flush_ms > 0 else DEFAULT_FLUSH_MS
        self.enabled = enabled
        self.current_chunk = List[UInt8]()
        self.chunk_index = 0
        self.last_flush_ms = now_unix_ms()
        self.uploaded_count = 0

    @staticmethod
    def disabled() -> LogStreamSink:
        """A no-op sink (streaming not engaged — no log bucket). feed/flush are
        no-ops; the agent keeps the in-memory logs.txt path."""
        return LogStreamSink(String(""), String(""), 0, 0, False)

    # ---- feed: absorb freshly-drained stdout bytes ----

    def feed_stdout[
        C: Connector,
    ](
        mut self,
        text: String,
        mut s3_client: AgentS3Client[C],
    ):
        """Append `text`'s bytes to the current chunk; flush if the byte
        threshold is crossed OR the flush interval has elapsed. A no-op when
        streaming is not engaged. Best-effort — a flush failure never raises."""
        if not self.enabled:
            return
        var bytes = text.as_bytes()
        for i in range(len(bytes)):
            self.current_chunk.append(bytes[i])
        self.maybe_flush[C](s3_client)

    def maybe_flush[
        C: Connector,
    ](mut self, mut s3_client: AgentS3Client[C]):
        """Flush the current chunk iff (a) it has crossed the byte threshold,
        or (b) the flush interval has elapsed since the last flush AND there is
        something buffered. A no-op when streaming is not engaged or the buffer
        is empty-and-not-over-time."""
        if not self.enabled:
            return
        if len(self.current_chunk) == 0:
            # Nothing buffered — reset the timer so an idle child doesn't
            # accumulate "overdue" time and flush an empty chunk later.
            return
        var over_size = len(self.current_chunk) >= self.chunk_bytes
        var now = now_unix_ms()
        var over_time = (now - self.last_flush_ms) >= Int64(self.flush_ms)
        if over_size or over_time:
            self.flush_current[C](s3_client)

    # ---- flush: put the current chunk, best-effort one-retry-then-drop ----

    def flush_current[
        C: Connector,
    ](mut self, mut s3_client: AgentS3Client[C]):
        """Upload the current chunk to `{bucket}/{job_id}/chunks/{n}.log`,
        advance the counter, and reset the buffer. BEST-EFFORT: try once, retry
        ONCE on failure, then DROP the chunk (a failed log upload must NOT crash
        the agent). The counter advances even on a
        drop so the index reflects the produced-chunk sequence. A no-op when
        streaming is not engaged or the buffer is empty."""
        if not self.enabled:
            return
        if len(self.current_chunk) == 0:
            return
        var n = self.chunk_index
        var key = self.job_id + String("/chunks/") + String(n) + String(".log")
        var byte_count = len(self.current_chunk)

        # Move the buffer out into the upload payload and reset the in-flight
        # chunk to empty (the next feed starts a fresh chunk regardless of the
        # upload outcome). A separate copy is kept for the one-shot retry.
        var payload = self.current_chunk^
        self.current_chunk = List[UInt8]()
        self.chunk_index = n + 1
        self.last_flush_ms = now_unix_ms()

        var ok = self._put_once[C](s3_client, key, payload.copy())
        if not ok:
            # Retry ONCE, then drop.
            ok = self._put_once[C](s3_client, key, payload^)
            if not ok:
                log.warn[
                    "agent stream: chunk {} upload failed after retry,"
                    " dropping ({} bytes) key={}",
                    "komira_agent.streamer",
                ](
                    ArgI64(Int64(n)),
                    ArgI64(Int64(byte_count)),
                    ArgStr(key),
                )
                return
        else:
            _ = payload^
        self.uploaded_count += 1
        log.debug[
            "agent stream: chunk {} ({} bytes) -> s3://{}/{}",
            "komira_agent.streamer",
        ](
            ArgI64(Int64(n)),
            ArgI64(Int64(byte_count)),
            ArgStr(self.bucket),
            ArgStr(key),
        )

    def _put_once[
        C: Connector,
    ](
        mut self,
        mut s3_client: AgentS3Client[C],
        key: String,
        var data: List[UInt8],
    ) -> Bool:
        """One `put_object` attempt. Returns True on success, False (swallowing
        the error) on any failure so the caller can decide retry/drop."""
        try:
            s3_client.put_object(self.bucket, key, data^)
            return True
        except e:
            log.warn[
                "agent stream: chunk put failed (best-effort) key={}: {}",
                "komira_agent.streamer",
            ](ArgStr(key), ArgStr(String(e)))
            return False

    # ---- flush the final partial chunk on terminal ----

    def flush_final[
        C: Connector,
    ](mut self, mut s3_client: AgentS3Client[C]):
        """On terminal, flush whatever remains in the current chunk (the final
        partial chunk). A no-op when streaming is not engaged or nothing is
        buffered."""
        if not self.enabled:
            return
        if len(self.current_chunk) == 0:
            return
        self.flush_current[C](s3_client)

    def chunks_produced(self) -> Int:
        """The number of chunk indices consumed (produced, including dropped)."""
        return self.chunk_index
