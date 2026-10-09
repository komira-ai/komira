# =============================================================================
# komira_log.engine.output_sink — the drain's output side (P3).
# =============================================================================
#
# The drain (drain.mojo / shared_engine.drain_worker) renders each record to a
# `String` line and hands it to a sink. Besides stderr, the production output
# side is:
#
#   * `SegmentFile`        — one rotating file segment: an owned `RawWriteFd`
#                            (O_APPEND) + a live byte counter + an open-time
#                            anchor + a `RotationPolicy` + an archive index.
#                            Append a line; when the policy fires, rename the
#                            live file to `{base}.{idx}.log`, retain the last
#                            `keep` archives, reopen a fresh live file.
#   * `LogSink`            — a tagged union over three output modes (stderr /
#                            single file / per-core segments). The engine owns
#                            ONE `LogSink`; the drain on core N calls
#                            `write_line_core(N, line)`. STDERR + FILE ignore
#                            the core index; PER_CORE_SEGMENTS routes to
#                            `_segments[N]` (its own fd — the share-nothing
#                            property: "one fd per core, owned by that core's
#                            appender — no shared fd, no cross-core lock").
#
# Per-core segment naming: `{base}.core{N}.log` for the live file;
# `{base}.core{N}.{idx}.log` for rotated archives. The merge reader
# (merge.mojo) globs the segment set and k-way-timestamp-merges.
#
# # Write model (buffered blocking, NOT reactor-async)
#
# The drain is ALREADY off the hot path (worker idle / budgeted tiers), so a
# synchronous blocking `write(2)` in the drain does NOT touch a query worker's
# critical path. A reactor-async append would keep even the off-hot-path drain
# from parking on EAGAIN, but wiring the reactor into the engine requires
# threading a `Reactor` handle through the forever-root → engine → drain chain,
# and `komira_log` depends only on the core packages, komira_trace, komira_metrics and the small leaf packages: adding
# `komira_async` would invert the dependency graph (`komira_async` depends on
# `komira_log`). So the sink uses a buffered blocking write via
# `RawWriteFd.write_bytes`. A reactor-async upgrade needs that edge inverted or
# a callback-style submit handle.
#
# # Encapsulation
#
# `SegmentFile` owns an `Optional[RawWriteFd]` (the movable-fd-in-Optional
# pattern) + POD counters + a `RotationPolicy` (POD)
# + the base-path `String` (the OWNER of its bytes, never byte-slab-stored).
# `LogSink._segments` is a `Slab[SegmentFile]` (the rings/Tracer pattern — a
# non-Copyable fd-owning struct cannot live in a `List`). The stderr lock is the
# P1 `OwnedPointer[Atomic]` pattern. NO `UnsafePointer` field, NO wildcard
# origin, NO heap-owning field inside a byte-slab. The only raw pointer is the
# Slab's interior arithmetic (`get_mut_interior`) — confined to the slab.
# =============================================================================

from komira_atomic_alias import AtomicU8
from std.memory import alloc, UnsafePointer, OwnedPointer

from komira_collections.slab import Slab
from komira_libc.posix_io import RawWriteFd

from komira_clock import now_unix_ms
from komira_log.log_write import LogWriteLosses, write_log_line

from komira_log.engine.rotation import (
    RotationPolicy,
    ROTATE_NONE,
    RETAIN_ALL,
)
from komira_log.engine.fs_ops import rename_path, unlink_path


# Sink-mode discriminants.
comptime SINK_STDERR: UInt8 = UInt8(0)
comptime SINK_FILE: UInt8 = UInt8(1)
comptime SINK_PER_CORE_SEGMENTS: UInt8 = UInt8(2)

comptime _STDERR_FD: Int32 = 2


# -----------------------------------------------------------------------------
# SegmentFile — one rotating output segment (one fd, one byte counter, one
# rotation policy). Non-Copyable (owns an fd) but Movable → lives in a Slab.
# -----------------------------------------------------------------------------


struct SegmentFile(Deinitable, Movable):
    """One rotating file segment: an owned append fd + a byte counter + an
    open-time anchor + a `RotationPolicy` + an archive index.

    The live file is `{base_path}.log`; rotated archives are
    `{base_path}.{idx}.log`. `base_path` already encodes the per-core suffix
    (e.g. `/var/log/komira.core3`) when the sink is per-core.
    """

    # `{base_path}.log` is the live file; archives are `{base_path}.{idx}.log`.
    var base_path: String
    # The live append fd. `None` until `open_live()`.
    var _fd: Optional[RawWriteFd]
    # Bytes written to the CURRENT live file since it opened (drives SIZE).
    var _cur_bytes: Int
    # Wall-clock ms when the current live file opened (drives TIME).
    var _opened_ms: Int64
    # Monotonic archive index for the rotated-file name `{base}.{idx}.log`.
    var _archive_idx: Int
    var _policy: RotationPolicy

    def __init__(out self):
        """Empty (unopened) segment — `open_live()` must follow before writes."""
        self.base_path = String("")
        self._fd = Optional[RawWriteFd]()
        self._cur_bytes = 0
        self._opened_ms = Int64(0)
        self._archive_idx = 0
        self._policy = RotationPolicy.none()

    def _live_path(self) -> String:
        return self.base_path + ".log"

    def _archive_path(self, idx: Int) -> String:
        return self.base_path + "." + String(idx) + ".log"

    def open_live(mut self) raises:
        """Open (truncate) the live file `{base}.log` and reset the counters.
        Truncate (not append) so a fresh run starts clean; rotation handles
        history. Idempotent-ish: if a live fd is already open it is closed
        first."""
        if self._fd:
            var old = self._fd.take()
            old.close()
        var fd = RawWriteFd.open_truncate(self._live_path())
        self._fd = Optional[RawWriteFd](fd^)
        self._cur_bytes = 0
        self._opened_ms = now_unix_ms()

    def __init__(
        out self, base_path: String, policy: RotationPolicy
    ) raises:
        """A segment whose live file `{base_path}.log` is already open.
        `SegmentFile` is Movable, so the per-core segments are built as values
        and appended to a `Slab[SegmentFile]`; nothing initialises a slot in
        place."""
        self.base_path = base_path
        self._fd = Optional[RawWriteFd]()
        self._cur_bytes = 0
        self._opened_ms = Int64(0)
        self._archive_idx = 0
        self._policy = policy
        self.open_live()

    def _rotate(mut self) raises:
        """Rename the live file to the next archive, retain the last `keep`,
        reopen a fresh live file. Called by `append_line` when the policy
        fires (at a line boundary — never mid-line)."""
        # Close the live fd so the rename moves a quiescent file.
        if self._fd:
            var live = self._fd.take()
            live.close()
        var idx = self._archive_idx
        rename_path(self._live_path(), self._archive_path(idx))
        self._archive_idx = idx + 1
        # Retention: delete archives older than the last `keep`.
        if self._policy.keep != RETAIN_ALL and self._policy.keep >= 0:
            # Archives [0 .. _archive_idx) exist; keep the most recent `keep`.
            var oldest_to_keep = self._archive_idx - self._policy.keep
            var i = oldest_to_keep - 1
            while i >= 0:
                # Best-effort delete (an already-pruned archive is fine).
                try:
                    unlink_path(self._archive_path(i))
                except:
                    pass
                i -= 1
        # Reopen a fresh live file.
        var fd = RawWriteFd.open_truncate(self._live_path())
        self._fd = Optional[RawWriteFd](fd^)
        self._cur_bytes = 0
        self._opened_ms = now_unix_ms()

    def append_line(mut self, line: String) raises:
        """Append `line` + '\\n' to the live file, advance the byte counter,
        and rotate if the policy fires. Whole-line write."""
        var out = line + "\n"
        var bytes = out.as_bytes()
        var n = len(bytes)
        if self._fd:
            ref fd = self._fd.value()
            fd.write_bytes(bytes)
        self._cur_bytes += n
        # Rotate at the line boundary if the policy says so.
        if self._policy.mode != ROTATE_NONE:
            var now_ms = now_unix_ms()
            if self._policy.should_rotate(
                self._cur_bytes, self._opened_ms, now_ms
            ):
                self._rotate()

    def flush(mut self) raises:
        """Fsync the live fd (durability on demand — e.g. an ERROR record or
        teardown). No-op if closed."""
        if self._fd:
            ref fd = self._fd.value()
            fd.fsync()

    @always_inline
    def current_bytes(self) -> Int:
        return self._cur_bytes

    @always_inline
    def archive_count(self) -> Int:
        return self._archive_idx


# -----------------------------------------------------------------------------
# LogSink — the engine's single output handle. A tagged union over the three
# output modes. The engine owns ONE; the drain calls `write_line_core(N, line)`.
# -----------------------------------------------------------------------------


struct LogSink(Movable):
    """The drain's output handle. STDERR (dev default), FILE (one file), or
    PER_CORE_SEGMENTS (one fd per core — the share-nothing production default).

    The core index is honored ONLY in PER_CORE_SEGMENTS mode; STDERR/FILE
    ignore it (all cores funnel to the one fd, serialized by the stderr lock /
    the single fd's append). The drain calls `write_line_core(worker_id, line)`
    uniformly; the sink routes.
    """

    var _kind: UInt8
    # STDERR mode: the P1 process-wide write lock (whole-line atomicity).
    # SAFETY: heap-owned Atomic via OwnedPointer (the non-Movable-
    # payload pattern). 0 == unlocked, 1 == locked.
    var _lock: OwnedPointer[AtomicU8]
    # FILE mode: one segment (no per-core fan-out).
    var _file: SegmentFile
    # PER_CORE_SEGMENTS mode: one SegmentFile per core (+1 fallback slot, mirror
    # of the engine's N+1 rings — the non-worker fallback writes to core N).
    var _segments: Slab[SegmentFile]
    var _n_segments: Int
    # STDERR mode: lines this sink failed to put on fd 2 whole. ⚠ THIS IS THE
    # DEFAULT SINK — `SharedEngine.__init__` installs `LogSink.stderr()`, and a
    # service that never calls `set_sink_single_file` /
    # `set_sink_per_core_segments` stays on it. So this counter, not the P1
    # one, is where such a service's lost lines land.
    var _losses: LogWriteLosses

    def __init__(out self):
        """STDERR sink — the dev default (matches the P1 StderrSink behavior)."""
        self._kind = SINK_STDERR
        var raw = alloc[AtomicU8](1)
        raw[] = AtomicU8(UInt8(0))
        self._lock = OwnedPointer[AtomicU8](
            unsafe_from_raw_pointer=raw
        )
        self._file = SegmentFile()
        self._segments = Slab[SegmentFile].create_prefilled(0)
        self._n_segments = 0
        self._losses = LogWriteLosses()

    @staticmethod
    def stderr() -> Self:
        return Self()

    @staticmethod
    def single_file(base_path: String, policy: RotationPolicy) raises -> Self:
        """One file `{base_path}.log` (rotating). All cores funnel here,
        serialized by the single append fd."""
        var s = Self()
        s._kind = SINK_FILE
        var seg = SegmentFile()
        seg.base_path = base_path
        seg._policy = policy
        seg.open_live()
        s._file = seg^
        return s^

    @staticmethod
    def per_core_segments(
        base_path: String, num_cores: Int, policy: RotationPolicy
    ) raises -> Self:
        """One fd per core: `{base_path}.core{N}.log`. The share-nothing
        production default. `num_cores` segments + 1 fallback
        slot (the non-worker fallback routes there — mirror of the engine's N+1
        rings)."""
        if num_cores <= 0:
            raise Error("LogSink.per_core_segments: num_cores must be > 0")
        var s = Self()
        s._kind = SINK_PER_CORE_SEGMENTS
        var n = num_cores + 1
        s._n_segments = n
        s._segments = Slab[SegmentFile].create_with_capacity(n)
        for c in range(n):
            var core_base = base_path + ".core" + String(c)
            s._segments.append(SegmentFile(core_base, policy))
        return s^

    @always_inline
    def kind(self) -> UInt8:
        return self._kind

    def _stderr_write(mut self, line: String):
        """Whole-line atomic stderr write under the P1 spin-lock."""
        var out = line + "\n"
        # acquire
        while True:  # cov: unreachable the retry needs another thread to hold the lock at the moment of the CAS; no deterministic test can make that happen
            var expected = UInt8(0)
            if self._lock[].compare_exchange(expected, UInt8(1)):
                break
        self._write_all_fd(_STDERR_FD, out)
        # release
        AtomicU8.store(
            UnsafePointer(to=self._lock[]).unsafe_bitcast[Scalar[DType.uint8]](), UInt8(0)
        )

    def _write_all_fd(mut self, fd: Int32, s: String):
        """Put `s` on `fd` best-effort, count what does not make it, and
        announce any NEW losses on the next healthy line.

        ★ THE ENGINE-PATH TWIN OF THE P1 WRITE LOOP. A loop that `break`s on the
        first non-positive return — no retry, no errno classification, no
        counter — lets an EINTR (a platform SIGTERM on scale-down) or an EAGAIN
        on a congested fd 2 truncate the line mid-message with nothing recording
        it. Two copies of one loop is how fixing one fixes nothing; both CALL
        `komira_log.log_write`.

        ⛔ IT DOES NOT RAISE. The core packages' fd write-all rules that "losing a
        diagnostic beats wedging the process", and that stands. Giving up is
        bounded, classified and counted."""
        var outcome = write_log_line(fd, s)
        self._losses.note(outcome)
        # ⭐ EDGE-REPORT (the `_report_overflow_drops` pattern): announce each
        # NEW batch once instead of re-printing a cumulative total per line.
        # Only when `fd` has just proven healthy, and the report's own outcome
        # is deliberately NOT noted — so this can never recurse and never
        # amplifies the congestion that caused the loss.
        if outcome.complete():
            var report = self._losses.take_report()
            if report.byte_length() > 0:
                _ = write_log_line(fd, report + "\n")

    @always_inline
    def dropped_line_count(self) -> Int64:
        """Lines of which NOTHING reached the stderr fd. NON-ZERO MEANS LOG
        LINES WERE LOST. (STDERR mode only; the FILE / PER_CORE_SEGMENTS paths
        go through `RawWriteFd.write_bytes`, which RAISES rather than
        dropping.)"""
        return self._losses.lines_lost

    @always_inline
    def truncated_line_count(self) -> Int64:
        """Lines of which only a PREFIX reached the stderr fd — under the
        Cloud-Logging JSON layout (`pattern_layout.render_line`), a malformed
        entry the collector DROPS rather than a damaged one it keeps."""
        return self._losses.lines_truncated

    @always_inline
    def last_write_errno(self) -> Int32:
        """The errno of the most recent loss, 0 if there has been none."""
        return self._losses.last_errno

    def write_line_core(mut self, worker_id: Int, line: String) raises:
        """Write `line` (no trailing newline) to the sink, routed by mode.

        STDERR / FILE ignore `worker_id`; PER_CORE_SEGMENTS routes to
        `_segments[worker_id]` (its own fd — share-nothing). Out-of-range
        `worker_id` falls back to the last (fallback) segment."""
        if self._kind == SINK_STDERR:
            self._stderr_write(line)
            return
        if self._kind == SINK_FILE:
            self._file.append_line(line)
            return
        # PER_CORE_SEGMENTS
        var idx = worker_id
        if idx < 0 or idx >= self._n_segments:
            idx = self._n_segments - 1  # fallback slot
        self._segments.get_mut_interior(idx).append_line(line)

    def flush_all(mut self) raises:
        """Fsync every live fd (teardown / ERROR durability). No-op for STDERR."""
        if self._kind == SINK_FILE:
            self._file.flush()
        elif self._kind == SINK_PER_CORE_SEGMENTS:
            for c in range(self._n_segments):
                self._segments.get_mut_interior(c).flush()

    @always_inline
    def segment_bytes(self, core: Int) -> Int:
        """Per-core live byte count (tests / monitoring). 0 if not per-core."""
        if self._kind != SINK_PER_CORE_SEGMENTS:
            return 0
        if core < 0 or core >= self._n_segments:
            return 0
        return self._segments[core].current_bytes()

    @always_inline
    def segment_archive_count(self, core: Int) -> Int:
        """Per-core rotated-archive count (tests)."""
        if self._kind != SINK_PER_CORE_SEGMENTS:
            return 0
        if core < 0 or core >= self._n_segments:
            return 0
        return self._segments[core].archive_count()
