# =============================================================================
# komira_job_supervisor/log_streamer.mojo: the job's stdout, streamed to the
# log object store while the job runs.
# =============================================================================
#
# Instead of holding all of stdout in memory until exit, the supervisor feeds
# each drained stdout chunk to a `LogStreamSink`, which accumulates the bytes
# and writes them to `{log_prefix}/chunks/{n}.log` (n counts up from 0) once
# the buffer crosses a byte threshold (default 64 KiB) or a flush interval has
# passed (default 10 s); the final partial chunk is written on exit. The
# objects concatenate, in index order, to the child's exact stdout bytes.
#
# The store is any komira_objectstore `ConditionalWriteStore` the embedding
# binary supplies; streaming is engaged only when it supplies a log store.
#
# BEST-EFFORT: a failed write never stops the job. A chunk is tried once,
# retried once, then dropped with a warning; the index still advances, so a
# listing shows the gap instead of reusing an index.
#
# The chunk buffer is an owned List[UInt8]; the store is passed by reference
# to each flush and never held. No pointer type.
# =============================================================================

from komira_clock import now_unix_ms
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

import komira_log as log
from komira_log import ArgStr, ArgI64


# =============================================================================
# §0: defaults.
# =============================================================================
comptime DEFAULT_CHUNK_BYTES = 64 * 1024  # 64 KiB flush-by-size threshold
comptime DEFAULT_FLUSH_MS = 10_000  # ~10s flush-by-time interval


# =============================================================================
# §1: LogStreamSink, the current-chunk accumulator and flush policy.
# =============================================================================
struct LogStreamSink(Movable):
    """Accumulate stdout bytes into a current chunk and write it to
    `{prefix}/chunks/{n}.log` on a byte threshold OR a flush interval,
    best-effort.

      prefix          — the object-key prefix (`--log-prefix`).
      chunk_bytes     — flush-by-size threshold (>= this many buffered bytes
                        triggers a flush). Defaulted to 64 KiB; 0/neg => default.
      flush_ms        — flush-by-time interval in ms. Defaulted to ~10s;
                        0/neg => default.
      enabled         — True iff streaming is engaged (a log store was
                        supplied). When False, feed/flush are no-ops.

    Working state:
      current_chunk   — the owned in-flight chunk buffer (bytes since last flush).
      chunk_index     — the monotonic next-chunk counter.
      last_flush_ms   — wall-clock ms of the last flush (or sink start); the
                        flush-interval is measured against this.
      uploaded_count  — count of chunks SUCCESSFULLY put (for diagnostics/tests).
    """

    var prefix: String
    var chunk_bytes: Int
    var flush_ms: Int
    var enabled: Bool

    var current_chunk: List[UInt8]
    var chunk_index: Int
    var last_flush_ms: Int64
    var uploaded_count: Int

    def __init__(
        out self,
        var prefix: String,
        chunk_bytes: Int,
        flush_ms: Int,
        enabled: Bool,
    ):
        self.prefix = prefix^
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
        """A no-op sink (streaming not engaged: no log store). feed/flush are
        no-ops."""
        return LogStreamSink(String(""), 0, 0, False)

    # ---- feed: absorb freshly-drained stdout bytes ----

    def feed_stdout[
        S: ConditionalWriteStore,
    ](
        mut self,
        text: String,
        store: S,
    ):
        """Append `text`'s bytes to the current chunk; flush if the byte
        threshold is crossed OR the flush interval has elapsed. A no-op when
        streaming is not engaged. Best-effort — a flush failure never raises."""
        if not self.enabled:
            return
        var bytes = text.as_bytes()
        for i in range(len(bytes)):
            self.current_chunk.append(bytes[i])
        self.maybe_flush[S](store)

    def maybe_flush[
        S: ConditionalWriteStore,
    ](mut self, store: S):
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
            self.flush_current[S](store)

    # ---- flush: put the current chunk, best-effort one-retry-then-drop ----

    def flush_current[
        S: ConditionalWriteStore,
    ](mut self, store: S):
        """Write the current chunk to `{prefix}/chunks/{n}.log`,
        advance the counter, and reset the buffer. BEST-EFFORT: try once, retry
        ONCE on failure, then DROP the chunk (a failed log upload must NOT crash
        the job supervisor). The counter advances even on a
        drop so the index reflects the produced-chunk sequence. A no-op when
        streaming is not engaged or the buffer is empty."""
        if not self.enabled:
            return
        if len(self.current_chunk) == 0:
            return
        var n = self.chunk_index
        var key = self.prefix + String("/chunks/") + String(n) + String(".log")
        var byte_count = len(self.current_chunk)

        # Move the buffer out into the upload payload and reset the in-flight
        # chunk to empty (the next feed starts a fresh chunk regardless of the
        # upload outcome). A separate copy is kept for the one-shot retry.
        var payload = self.current_chunk^
        self.current_chunk = List[UInt8]()
        self.chunk_index = n + 1
        self.last_flush_ms = now_unix_ms()

        var ok = self._put_once[S](store, key, payload.copy())
        if not ok:
            # Retry ONCE, then drop.
            ok = self._put_once[S](store, key, payload^)
            if not ok:
                log.warn[
                    "job supervisor stream: chunk {} upload failed after retry,"
                    " dropping ({} bytes) key={}",
                    "komira_job_supervisor.streamer",
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
            "job supervisor stream: chunk {} ({} bytes) -> {}",
            "komira_job_supervisor.streamer",
        ](
            ArgI64(Int64(n)),
            ArgI64(Int64(byte_count)),
            ArgStr(key),
        )

    def _put_once[
        S: ConditionalWriteStore,
    ](
        mut self,
        store: S,
        key: String,
        var data: List[UInt8],
    ) -> Bool:
        """One `put` attempt. Returns True on success, False (swallowing
        the error) on any failure so the caller can decide retry/drop."""
        try:
            _ = store.put(Path.parse(key), data^)
            return True
        except e:
            log.warn[
                "job supervisor stream: chunk put failed (best-effort) key={}: {}",
                "komira_job_supervisor.streamer",
            ](ArgStr(key), ArgStr(String(e)))
            return False

    # ---- flush the final partial chunk on terminal ----

    def flush_final[
        S: ConditionalWriteStore,
    ](mut self, store: S):
        """On terminal, flush whatever remains in the current chunk (the final
        partial chunk). A no-op when streaming is not engaged or nothing is
        buffered."""
        if not self.enabled:
            return
        if len(self.current_chunk) == 0:
            return
        self.flush_current[S](store)

    def chunks_produced(self) -> Int:
        """The number of chunk indices consumed (produced, including dropped)."""
        return self.chunk_index
