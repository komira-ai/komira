# =============================================================================
# komira_async.timer.timer_wheel — hierarchical timing wheel
# =============================================================================
#
#
# Per-worker (one TimerWheel per Worker, owned by that Worker's Reactor;
# per-core architecture).
#
# Wheel geometry follows tokio's parameters
# (`tokio/src/runtime/time/wheel/mod.rs:45 NUM_LEVELS=6`,
# `level.rs:38 LEVEL_MULT=64`):
#
#   BASE_RESOLUTION_MS = 1
#   NUM_LEVELS         = 6
#   LEVEL_MULT         = 64
#
#   Level 0: 64 buckets × 1ms       = 64ms       span
#   Level 1: 64 buckets × 64ms      = ~4s        span
#   Level 2: 64 buckets × 4s        = ~4min      span
#   Level 3: 64 buckets × ~4min     = ~4hr       span
#   Level 4: 64 buckets × ~4hr      = ~12 days   span
#   Level 5: 64 buckets × ~12 days  = ~2 years   span
#
# Insertion: O(1). Cancel: O(B-per-bucket) amortized (typically O(1)). Tick
# advance: O(B) per level; cascade to lower levels on level-N tick
# wraparound.
#
# Concurrency: Single owner (per-worker by construction); no internal
# sync needed — NO ArcPointer, NO Atomic state on the wheel itself.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer in any field — single-owner.
#   - ZERO wildcard origins on public surface.
#   - ZERO unsafe_from_address.
# =============================================================================


# =============================================================================
# Wheel parameters — Tokio NUM_LEVELS=6, LEVEL_MULT=64, BASE_RESOLUTION_MS=1.
# Validated values. Public so test code +
# integrators can verify.
# =============================================================================
comptime BASE_RESOLUTION_MS: Int64 = 1
comptime NUM_LEVELS: UInt8 = 6
comptime LEVEL_MULT: UInt8 = 64

# Derived constants — slot range in nanoseconds for each level.
# Level N's slot range = (LEVEL_MULT^N) * BASE_RESOLUTION_MS milliseconds.
#   Level 0 = 1ms   = 1_000_000 ns
#   Level 1 = 64ms  = 64_000_000 ns
#   Level 2 = 64²ms ≈ 4.096s   = 4_096_000_000 ns
#   Level 3 = 64³ms ≈ 4.4min   = 262_144_000_000 ns
#   Level 4 = 64⁴ms ≈ 4.66hr   = 16_777_216_000_000 ns
#   Level 5 = 64⁵ms ≈ 12.4days = 1_073_741_824_000_000 ns
comptime _LEVEL_0_SLOT_NS: Int64 = 1_000_000
comptime _LEVEL_1_SLOT_NS: Int64 = 64_000_000
comptime _LEVEL_2_SLOT_NS: Int64 = 4_096_000_000
comptime _LEVEL_3_SLOT_NS: Int64 = 262_144_000_000
comptime _LEVEL_4_SLOT_NS: Int64 = 16_777_216_000_000
comptime _LEVEL_5_SLOT_NS: Int64 = 1_073_741_824_000_000

# Level N's TOTAL span = LEVEL_MULT * slot_range. delta < level_span_N → fits
# in level <= N.
#   Level 0 span = 64ms        = 64_000_000 ns
#   Level 1 span = 4.096s      = 4_096_000_000 ns
#   Level 2 span = ~4.4min     = 262_144_000_000 ns
#   Level 3 span = ~4.66hr     = 16_777_216_000_000 ns
#   Level 4 span = ~12 days    = 1_073_741_824_000_000 ns
#   Level 5 span = ~2 years    = 68_719_476_736_000_000 ns
comptime _LEVEL_0_SPAN_NS: Int64 = 64_000_000
comptime _LEVEL_1_SPAN_NS: Int64 = 4_096_000_000
comptime _LEVEL_2_SPAN_NS: Int64 = 262_144_000_000
comptime _LEVEL_3_SPAN_NS: Int64 = 16_777_216_000_000
comptime _LEVEL_4_SPAN_NS: Int64 = 1_073_741_824_000_000


@fieldwise_init
struct TimerHandle(Movable, Copyable, ImplicitlyCopyable, Deinitable):
    """Opaque handle for cancel.

    Generation-tagged via _id (monotonic; never reused) for ABA-free cancel.
    _level + _bucket cache the schedule-time location so cancel() can do a
    direct bucket index without recomputing from the deadline (which would
    be wrong post-cascade anyway).

    All three fields POD; ImplicitlyCopyable so `List[TimerHandle][i]` is
    ergonomic in tests and any caller code that bookkeeps multiple handles
    in a list.
    """

    var _id: UInt64
    var _level: UInt8
    var _bucket: UInt8


@fieldwise_init
struct TimerCallback(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Function-pointer carrier: on fire,
    invoke fn(arg) which routes to the appropriate IoOp / channel /
    mutex op_id wakeup.

    Copyable + ImplicitlyCopyable: List[TimerCallback] is the return type of
    TimerWheel.advance, which requires T: Copyable.
    Both fields are POD (function pointer + UInt64), trivially Copyable —
    keyword-construct args ('cb=cb') do an implicit copy.
    """

    var _fn: def(UInt64) thin -> None
    var _arg: UInt64


@fieldwise_init
struct TimerEntry(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Per-scheduled-timer record stored in a wheel bucket.

    All fields POD → TimerEntry: Copyable & Movable. List[TimerEntry] is
    the per-bucket storage shape on Mojo 0.26.3.

    Destroy-recreate audit: NO List[U] / String / OwnedPointer[U] / ArcPointer[U] /
    wildcard-origin pointer field. TimerCallback's fields are
    (fn(UInt64) thin -> None, UInt64) — both POD. Safe in any container.
    """

    var _handle_id: UInt64
    var _deadline_ns: Int64
    var _cancelled: Bool
    var _cb: TimerCallback


# =============================================================================
# Private level/slot math helpers
# =============================================================================
# These power schedule() (deadline → level + slot) and advance() (cascade
# re-schedule). Pure functions; no state. Underscore-prefixed for "private"
# but exposed at module scope for direct unit testing.

def _slot_range_ns(level: UInt8) -> Int64:
    """Level N's slot range in nanoseconds. 64^N ms.

    Implemented as a 6-way branch (level <= 5) rather than `pow(64, N)` to
    keep this O(1) and inline-friendly. NUM_LEVELS=6 hardcoded; if levels
    grow, extend this branch.
    """
    if level == UInt8(0):
        return _LEVEL_0_SLOT_NS
    if level == UInt8(1):
        return _LEVEL_1_SLOT_NS
    if level == UInt8(2):
        return _LEVEL_2_SLOT_NS
    if level == UInt8(3):
        return _LEVEL_3_SLOT_NS
    if level == UInt8(4):
        return _LEVEL_4_SLOT_NS
    return _LEVEL_5_SLOT_NS


def _level_for_delta(delta_ns: Int64) -> UInt8:
    """Pick the highest level whose slot range fits delta_ns.

    Algorithm: find the smallest N such that delta_ns < level_N_span. If
    delta exceeds all levels, clamp to top (level 5) per Tokio's "top
    level acts as a pseudo-ring buffer" rule (level.rs:78-87).

    delta <= 0 → level 0 (fire on next tick).
    """
    if delta_ns <= Int64(0):
        return UInt8(0)
    if delta_ns < _LEVEL_0_SPAN_NS:
        return UInt8(0)
    if delta_ns < _LEVEL_1_SPAN_NS:
        return UInt8(1)
    if delta_ns < _LEVEL_2_SPAN_NS:
        return UInt8(2)
    if delta_ns < _LEVEL_3_SPAN_NS:
        return UInt8(3)
    if delta_ns < _LEVEL_4_SPAN_NS:
        return UInt8(4)
    return UInt8(5)


def _cancel_in_list(mut entries: List[TimerEntry], id: UInt64) -> Bool:
    """Linear scan a per-bucket entry list for the matching id; flip the
    _cancelled flag if found. Returns True iff found.

    Implemented as a free fn so the caller's borrow on the InlineArray
    slot stays scoped to the call expression — Mojo 0.26.3's borrow
    checker is happier with this shape than with `entries[i]._cancelled =
    True` written inside cancel() under a `mut self` body that's
    simultaneously holding refs into self._level_N[...].
    """
    var n = len(entries)
    for i in range(n):
        if entries[i]._handle_id == id:
            entries[i]._cancelled = True
            return True
    return False


def _slot_for_deadline(deadline_ns: Int64, level: UInt8, epoch_ns: Int64) -> UInt8:
    """Compute the bucket index for an entry at this level given the wheel's
    epoch. slot = ((deadline_ns - epoch_ns) / slot_range_N) % LEVEL_MULT.

    epoch_ns is the wheel's anchor time (its construction time). Slots are
    addressed relative to epoch so a long-lived wheel doesn't suffer from
    absolute-time drift.

    For deadline_ns < epoch_ns (very rare; only if `now < epoch`), the
    integer-division-of-negative result is implementation-defined in the
    abstract but Mojo's Int64 truncates toward zero. We clamp via max(0, ...)
    to avoid producing a negative slot index.
    """
    var rel = deadline_ns - epoch_ns
    if rel < Int64(0):
        rel = Int64(0)
    var range_ns = _slot_range_ns(level)
    var slot_idx = (rel // range_ns) % Int64(LEVEL_MULT)
    return UInt8(slot_idx)


# =============================================================================
# TimerWheel — public surface
# =============================================================================
# Per-worker single-owner. The foundational layer (entry
# struct + math) is here; the schedule / cancel / advance
# implementations. The public API stubs below remain for now (still raise
# NotImplementedError).


struct TimerWheel(Deinitable):
    """Hierarchical timing wheel.

    full field set declared + __init__ initializes all
    384 buckets to empty Lists. Bucket layout: 6 named `_level_<N>:
    InlineArray[List[TimerEntry], 64]` fields.
    schedule/cancel/advance still raise NotImplementedError; Commits 3/4/5
    land them.

    Storage rationale (destroy-recreate audit):
    - `InlineArray[List[TimerEntry], N]` is inline-stored for the OUTER
      array. The INNER List heap-buffers TimerEntry, but TimerEntry is
      safe across destroy-recreate POD (UInt64 + Int64 + Bool + TimerCallback POD).
    - `List[List[TimerEntry]]` outer would heap-allocate the level
      itself, adding redundant indirection. Six named InlineArray fields
      is uglier source but cleaner runtime + zero-pointer-chasing.
    - `_occupied: InlineArray[UInt64, 6]` is the per-level bitmask of
      "this slot has at least one entry" — Tokio's level.rs:14-19
      optimization for skip-empty advance().
    """

    var _level_0: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _level_1: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _level_2: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _level_3: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _level_4: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _level_5: Array[List[TimerEntry], Int(LEVEL_MULT)]
    var _occupied: Array[UInt64, Int(NUM_LEVELS)]
    var _now_ns: Int64
    var _epoch_ns: Int64
    var _next_handle_id: UInt64

    def __init__(out self):
        """Construct an empty wheel anchored at epoch=0.

        _next_handle_id starts at 1; 0 is reserved as the "null handle"
        sentinel (a TimerHandle whose _id == 0 is invalid).

        InlineArray initialization uses `fill=List[TimerEntry]()` per
        Mojo 0.26.3 idiom (matches `agg_commit.mojo:322` precedent for
        `InlineArray[Movable_T, N](fill=...)`).
        """
        self._level_0 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_1 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_2 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_3 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_4 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_5 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._occupied = Array[UInt64, Int(NUM_LEVELS)](fill=UInt64(0))
        self._now_ns = Int64(0)
        self._epoch_ns = Int64(0)
        self._next_handle_id = UInt64(1)

    def __init__(out self, _epoch_ns: Int64):
        """Construct with explicit epoch. _now_ns starts at epoch (a fresh
        wheel has nothing to fire yet)."""
        self._level_0 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_1 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_2 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_3 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_4 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._level_5 = Array[List[TimerEntry], Int(LEVEL_MULT)](
            fill=List[TimerEntry]()
        )
        self._occupied = Array[UInt64, Int(NUM_LEVELS)](fill=UInt64(0))
        self._now_ns = _epoch_ns
        self._epoch_ns = _epoch_ns
        self._next_handle_id = UInt64(1)

    def schedule(mut self, deadline_ns: Int64, cb: TimerCallback) raises -> TimerHandle:
        """O(1) insertion.

        Algorithm:
          1. delta = deadline_ns - self._now_ns. delta <= 0 → level 0,
             current slot+1 (next tick).
          2. level = _level_for_delta(delta).
          3. slot  = _slot_for_deadline(deadline_ns, level, _epoch_ns).
          4. handle_id = _next_handle_id; bump.
          5. append TimerEntry to _level_<level>[slot]; set _occupied bit.
          6. return TimerHandle(handle_id, level, slot).

        Pointer discipline: returns POD TimerHandle by value; takes
        TimerCallback by value (Copyable+ImplicitlyCopyable POD).

        Raise on: nothing. Past deadlines are silently scheduled in
        level 0; oversized deadlines clamp to level 5 (Tokio "top
        level acts as pseudo-ring buffer" rule).
        """
        var delta = deadline_ns - self._now_ns
        var level = _level_for_delta(delta)
        var slot = _slot_for_deadline(deadline_ns, level, self._epoch_ns)
        var hid = self._next_handle_id
        self._next_handle_id += UInt64(1)

        var entry = TimerEntry(
            _handle_id=hid,
            _deadline_ns=deadline_ns,
            _cancelled=False,
            _cb=cb,
        )

        var slot_idx = Int(slot)
        if level == UInt8(0):
            self._level_0[slot_idx].append(entry)
        elif level == UInt8(1):
            self._level_1[slot_idx].append(entry)
        elif level == UInt8(2):
            self._level_2[slot_idx].append(entry)
        elif level == UInt8(3):
            self._level_3[slot_idx].append(entry)
        elif level == UInt8(4):
            self._level_4[slot_idx].append(entry)
        else:
            self._level_5[slot_idx].append(entry)

        # Set the _occupied bit for this slot at this level.
        var bit = UInt64(1) << UInt64(slot)
        self._occupied[Int(level)] = self._occupied[Int(level)] | bit

        return TimerHandle(_id=hid, _level=level, _bucket=slot)

    def cancel(mut self, handle: TimerHandle) raises:
        """O(1) amortized cancel.

        Tombstone-on-cancel: marks the matching entry's _cancelled flag.
        advance() sweeps tombstoned entries when it processes their slot.
        Physical removal is deferred to keep cancel cheap.

        Lookup strategy:
          1. FAST PATH: scan _level_<handle._level>[handle._bucket] for
             _handle_id == handle._id. Mark cancelled. O(B-per-bucket),
             typically O(1).
          2. POST-CASCADE FALLBACK: if not found at cached location (the
             entry was cascaded to a different level/bucket between
             schedule and cancel), scan all 384 buckets. O(384) in the
             worst case; v0.2 may add a side-table.
          3. Cancel-after-fire / stale id: silent no-op.

        Idempotent: calling cancel() twice on the same handle marks the
        already-cancelled entry cancelled a second time (no observable
        side-effect).
        """
        if self._cancel_in_bucket(handle._level, handle._bucket, handle._id):
            return
        # Fallback: scan all 384 buckets across all 6 levels.
        for level in range(Int(NUM_LEVELS)):
            for slot in range(Int(LEVEL_MULT)):
                if self._cancel_in_bucket(UInt8(level), UInt8(slot), handle._id):
                    return
        # Not found anywhere → silent no-op (already fired, or stale handle).

    def _cancel_in_bucket(mut self, level: UInt8, bucket: UInt8, id: UInt64) -> Bool:
        """Linear scan one bucket for an entry with the given id; mark
        cancelled if found. Returns True iff found.

        Internal helper; six-way branch on level matches schedule()'s
        shape.
        """
        var slot_idx = Int(bucket)
        if level == UInt8(0):
            return _cancel_in_list(self._level_0[slot_idx], id)
        if level == UInt8(1):
            return _cancel_in_list(self._level_1[slot_idx], id)
        if level == UInt8(2):
            return _cancel_in_list(self._level_2[slot_idx], id)
        if level == UInt8(3):
            return _cancel_in_list(self._level_3[slot_idx], id)
        if level == UInt8(4):
            return _cancel_in_list(self._level_4[slot_idx], id)
        return _cancel_in_list(self._level_5[slot_idx], id)

    def advance(mut self, now_ns: Int64) raises -> List[TimerCallback]:
        """Called by Reactor.run_once.
        Returns the list of callbacks to fire in completion order.

        Algorithm (correctness-first; bitmask-
        accelerated fast path is a v0.2 perf-tuning step):

        1. _now_ns = max(_now_ns, now_ns) — never move backwards.

        2. Walk all 384 buckets across the 6 levels. For each entry e:
           a) If e._cancelled — drop (do not fire, do not re-schedule).
           b) If e._deadline_ns <= new_now — fire (append e._cb to
              result).
           c) Else: e is still in the future. Compute the level it
              SHOULD be in given the advanced _now_ns:
                 want_level = _level_for_delta(e._deadline_ns - new_now)
              If want_level == its current level — leave it in place.
              Else (want_level < current_level — finer resolution
              needed) — cascade: remove from current bucket, append
              to _level_<want_level>[want_slot].
        3. Rebuild _occupied bitmasks based on which buckets are
           non-empty after the sweep.

        Result list ordering: FIFO within a bucket, then bucket-order
        within a level (slots ascending), then level-order
        (level 0 first, then level 1, ...). For most workloads with
        timers spread across levels, level 0 fires last (it has the
        finest resolution and we cascade INTO it from higher levels
        before walking it). To get timestamp-monotone ordering, the
        fired callbacks within one advance() are NOT guaranteed to be
        in deadline order — only "would-have-fired by now". The
        Reactor + IoOp.sleep contract is satisfied by "fires sometime
        within one tick of its deadline".

        Complexity: O(B) where B = total live entries (cancelled,
        firing, or cascaded). For workers hosting O(100) timers,
        this is ~100 iterations per advance — well within the perf
        envelope. v0.2 may add the Tokio bitmask-skip-empty fast path
        (level.rs:next_occupied_slot) to bring idle-wheel advance to
        O(1).
        """
        var new_now = self._now_ns
        if now_ns > new_now:
            new_now = now_ns
        self._now_ns = new_now

        var result = List[TimerCallback]()

        # Process levels from highest (5) down to 0 so cascaded entries
        # land in lower-level buckets that we haven't visited yet THIS
        # call (they get walked on the NEXT advance() call). This is
        # safe because cascade always moves an entry to a level <= its
        # current level — a level-2 entry cascading to level 0 won't
        # be re-cascaded this advance().
        #
        # NOTE: this design accepts that an entry whose deadline arrives
        # mid-advance and cascades to level 0 won't fire this same
        # advance() call — it fires on the next advance(). For the
        # reactor's tick-resolution contract this is acceptable. (Tokio
        # has the same property — its wheel processes one slot per tick
        # and timers don't observe sub-tick latency improvements from
        # mid-advance cascades.)

        # Walk levels 5 → 0.
        var l = Int(NUM_LEVELS) - 1
        while l >= 0:
            self._sweep_level(UInt8(l), new_now, result)
            l -= 1

        return result^

    def _sweep_level(
        mut self,
        level: UInt8,
        new_now: Int64,
        mut result: List[TimerCallback],
    ):
        """Sweep one level: for each bucket with at least one entry,
        partition entries into (fire, cascade-down, keep) and rebuild
        the bucket. Update _occupied bit accordingly.

        Helper-function shape (not method) lets us hold a `mut` borrow
        on the OUT result list while walking the InlineArray slot —
        Mojo 0.26.3 borrow checker is happier this way.
        """
        for slot_idx in range(Int(LEVEL_MULT)):
            self._sweep_bucket(level, UInt8(slot_idx), new_now, result)

    def _sweep_bucket(
        mut self,
        level: UInt8,
        bucket: UInt8,
        new_now: Int64,
        mut result: List[TimerCallback],
    ):
        """Sweep one bucket. For each entry: fire if due, cascade if
        level changed, keep otherwise. Rebuild bucket in place.

        Cascade target buckets are appended in this same call — those
        entries get visited again only on the NEXT advance().
        """
        var slot_idx = Int(bucket)

        # Snapshot the current bucket. We can't mutate while iterating
        # in Mojo 0.26.3 without explicit care, so build a fresh keep-
        # list and replace.
        var snapshot = List[TimerEntry]()
        if level == UInt8(0):
            for i in range(len(self._level_0[slot_idx])):
                snapshot.append(self._level_0[slot_idx][i])
            self._level_0[slot_idx] = List[TimerEntry]()
        elif level == UInt8(1):
            for i in range(len(self._level_1[slot_idx])):
                snapshot.append(self._level_1[slot_idx][i])
            self._level_1[slot_idx] = List[TimerEntry]()
        elif level == UInt8(2):
            for i in range(len(self._level_2[slot_idx])):
                snapshot.append(self._level_2[slot_idx][i])
            self._level_2[slot_idx] = List[TimerEntry]()
        elif level == UInt8(3):
            for i in range(len(self._level_3[slot_idx])):
                snapshot.append(self._level_3[slot_idx][i])
            self._level_3[slot_idx] = List[TimerEntry]()
        elif level == UInt8(4):
            for i in range(len(self._level_4[slot_idx])):
                snapshot.append(self._level_4[slot_idx][i])
            self._level_4[slot_idx] = List[TimerEntry]()
        else:
            for i in range(len(self._level_5[slot_idx])):
                snapshot.append(self._level_5[slot_idx][i])
            self._level_5[slot_idx] = List[TimerEntry]()

        # Now classify each snapshot entry.
        var keep = List[TimerEntry]()
        for i in range(len(snapshot)):
            var e = snapshot[i]
            if e._cancelled:
                # Tombstone — drop.
                continue
            if e._deadline_ns <= new_now:
                # Due — fire.
                result.append(e._cb)
                continue
            # Future entry — does it still belong at this (level, bucket)?
            var delta = e._deadline_ns - new_now
            var want_level = _level_for_delta(delta)
            if want_level == level:
                # Stays in this bucket.
                keep.append(e)
            else:
                # Cascade to lower-level bucket. Re-compute slot via
                # current epoch.
                var new_slot = _slot_for_deadline(
                    e._deadline_ns, want_level, self._epoch_ns
                )
                # Update the entry's snapshot to reflect its new
                # location (TimerHandle's cached coords still point at
                # the OLD level/bucket — cancel() falls back to
                # full-wheel scan in that case).
                self._cascade_append(want_level, new_slot, e)

        # Restore the keep-list back to the bucket.
        if level == UInt8(0):
            self._level_0[slot_idx] = keep^
        elif level == UInt8(1):
            self._level_1[slot_idx] = keep^
        elif level == UInt8(2):
            self._level_2[slot_idx] = keep^
        elif level == UInt8(3):
            self._level_3[slot_idx] = keep^
        elif level == UInt8(4):
            self._level_4[slot_idx] = keep^
        else:
            self._level_5[slot_idx] = keep^

        # Update _occupied bit for this bucket.
        var bit = UInt64(1) << UInt64(bucket)
        var bucket_now_empty = self._bucket_is_empty(level, bucket)
        if bucket_now_empty:
            self._occupied[Int(level)] = self._occupied[Int(level)] & ~bit
        else:
            self._occupied[Int(level)] = self._occupied[Int(level)] | bit

    def _cascade_append(mut self, level: UInt8, bucket: UInt8, e: TimerEntry):
        """Append a cascaded entry to (level, bucket). Set _occupied bit.
        Called from _sweep_bucket; the destination bucket is on a
        lower-or-equal level than the current sweep level (we sweep
        high → low so cascade-down doesn't re-visit)."""
        var slot_idx = Int(bucket)
        if level == UInt8(0):
            self._level_0[slot_idx].append(e)
        elif level == UInt8(1):
            self._level_1[slot_idx].append(e)
        elif level == UInt8(2):
            self._level_2[slot_idx].append(e)
        elif level == UInt8(3):
            self._level_3[slot_idx].append(e)
        elif level == UInt8(4):
            self._level_4[slot_idx].append(e)
        else:
            self._level_5[slot_idx].append(e)
        var bit = UInt64(1) << UInt64(bucket)
        self._occupied[Int(level)] = self._occupied[Int(level)] | bit

    def _bucket_is_empty(self, level: UInt8, bucket: UInt8) -> Bool:
        """True iff (level, bucket) has zero entries."""
        var slot_idx = Int(bucket)
        if level == UInt8(0):
            return len(self._level_0[slot_idx]) == 0
        if level == UInt8(1):
            return len(self._level_1[slot_idx]) == 0
        if level == UInt8(2):
            return len(self._level_2[slot_idx]) == 0
        if level == UInt8(3):
            return len(self._level_3[slot_idx]) == 0
        if level == UInt8(4):
            return len(self._level_4[slot_idx]) == 0
        return len(self._level_5[slot_idx]) == 0
