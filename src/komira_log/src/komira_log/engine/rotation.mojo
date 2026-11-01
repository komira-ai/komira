# =============================================================================
# komira_log.engine.rotation — per-segment rotation policy (P3).
# =============================================================================
#
# Size / time / composite rotation for ONE output segment. The drain (off the
# hot path) consults the policy after each line append: when the segment's byte
# counter crosses `max_bytes`, OR the wall clock crosses `interval_ms` since the
# segment opened, the appender rotates — renames the live file to a timestamped
# archive `{name}.{date-index}.log`, retains the last `keep` archives (deleting
# the oldest beyond that), and opens a fresh live file.
#
# Per-segment + independent: each per-core segment carries its OWN `RotationPolicy`
# + its OWN byte counter + its OWN open-time anchor; there is NO global rollover
# barrier ("each core's RollingFileAppender rotates its OWN
# segment independently"). The policy is a small POD value type — the appender
# (output_sink.mojo) owns the counters and drives the decision.
#
# Encapsulation: pure POD scalars. No `UnsafePointer`, no wildcard origin,
# no heap-owning field. The policy never touches an fd — it only DECIDES; the
# `SegmentFile` (output_sink.mojo) performs the rename/unlink/reopen.
# =============================================================================


# Rotation mode discriminants. A composite policy is `SIZE | TIME` (a segment
# rotates whenever EITHER bound is crossed).
comptime ROTATE_NONE: UInt8 = UInt8(0)
comptime ROTATE_SIZE: UInt8 = UInt8(1)
comptime ROTATE_TIME: UInt8 = UInt8(2)
comptime ROTATE_COMPOSITE: UInt8 = UInt8(3)  # SIZE | TIME

# Sentinel "no retention cap" — keep every archive.
comptime RETAIN_ALL: Int = -1


@fieldwise_init
struct RotationPolicy(Copyable, ImplicitlyCopyable, Movable):
    """Per-segment rotation decision inputs. POD; the appender owns the live
    counters (current byte count, segment open-time) and calls `should_rotate`.
    """

    # ROTATE_NONE / SIZE / TIME / COMPOSITE.
    var mode: UInt8
    # Size bound (bytes). Rotate when the segment reaches/exceeds this. Ignored
    # unless mode has the SIZE bit.
    var max_bytes: Int
    # Time bound (milliseconds). Rotate when `now_ms - opened_ms >= interval_ms`.
    # Ignored unless mode has the TIME bit.
    var interval_ms: Int
    # Retention: keep at most this many ROTATED archives per segment; delete the
    # oldest beyond it. `RETAIN_ALL` (-1) keeps every archive.
    var keep: Int

    @staticmethod
    def none() -> Self:
        """No rotation — a single ever-growing segment file."""
        return Self(
            mode=ROTATE_NONE,
            max_bytes=0,
            interval_ms=0,
            keep=RETAIN_ALL,
        )

    @staticmethod
    def by_size(max_bytes: Int, keep: Int = RETAIN_ALL) -> Self:
        return Self(
            mode=ROTATE_SIZE,
            max_bytes=max_bytes,
            interval_ms=0,
            keep=keep,
        )

    @staticmethod
    def by_time(interval_ms: Int, keep: Int = RETAIN_ALL) -> Self:
        return Self(
            mode=ROTATE_TIME,
            max_bytes=0,
            interval_ms=interval_ms,
            keep=keep,
        )

    @staticmethod
    def composite(
        max_bytes: Int, interval_ms: Int, keep: Int = RETAIN_ALL
    ) -> Self:
        return Self(
            mode=ROTATE_COMPOSITE,
            max_bytes=max_bytes,
            interval_ms=interval_ms,
            keep=keep,
        )

    @always_inline
    def _has_size(self) -> Bool:
        return (self.mode == ROTATE_SIZE) or (self.mode == ROTATE_COMPOSITE)

    @always_inline
    def _has_time(self) -> Bool:
        return (self.mode == ROTATE_TIME) or (self.mode == ROTATE_COMPOSITE)

    @always_inline
    def should_rotate(
        self, current_bytes: Int, opened_ms: Int64, now_ms: Int64
    ) -> Bool:
        """Decide whether the segment should rotate NOW, given its live byte
        count and open-time. Pure function — no I/O. The appender calls this
        after appending a line (so a just-crossed bound triggers on the next
        line boundary, never mid-line)."""
        if self.mode == ROTATE_NONE:
            return False
        if self._has_size() and self.max_bytes > 0:
            if current_bytes >= self.max_bytes:
                return True
        if self._has_time() and self.interval_ms > 0:
            if Int(now_ms - opened_ms) >= self.interval_ms:
                return True
        return False
