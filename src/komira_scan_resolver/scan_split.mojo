# =============================================================================
# Scan splits: the unit a scan kind is read in, and the reader that reads one.
# =============================================================================
#
# A scan of a kind is a set of SPLITS: a partition of a message log, one split
# object of a search index. Each split is read from a `start` position to an
# optional `stop` position. Positions are KIND-ENCODED bytes: the engine carries
# them, checkpoints them and hands them back, but never interprets them.
#
# A `SplitReader` reads ONE split. It is polled, and every poll answers ROWS (a
# batch, and the position after it), IDLE (nothing now, the split has not
# reached its stop) or END (the split is never polled again: it reached its
# stop, or a stop the reader enforces, such as a per-split byte budget, ended
# it short of it). END short of the stop is a CUT: `position` is where the
# rest of the split starts. The position after any poll is a resume point: reopening the split
# with `start` set to it reads exactly the rest.
#
# A bounded read is the same thing with every split's `stop` set. `drain_scan`
# (`drain_scan.mojo`) is that bounded read, and it is the only one this
# library executes; a split with no stop is planned and opened here, and read
# by an engine that can park on IDLE.
#
# ERASURE. `ErasedSplitReader` boxes one concrete reader behind thin fn-ptrs,
# the same shape as `ErasedScanSourceResolver`, because a reader is produced by
# a resolver whose concrete type the engine does not know. It is returned BY
# VALUE; no pointer leaves this package, and none enters it: the only
# constructor takes the concrete reader and binds its own trampolines.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_core.arrow.record_batch import RecordBatch
from komira_core.source.scan_params import ScanParams


comptime SCAN_RESOLVER_ABI_VERSION: UInt32 = 1
"""The layout version of the two erased facades (`ErasedScanSourceResolver`,
`ErasedSplitReader`). Each stores it as its FIRST field, so a host that
receives a facade built by another compilation (across a shared-library
boundary) can read it before trusting any other field. Bump it on ANY change
to either facade's field list or to a vtable signature."""

comptime SCAN_RESOLVER_ABI_MISMATCH: StaticString = "SCAN_RESOLVER_ABI_MISMATCH"
"""NAMED ERROR — an erased facade was built against another
`SCAN_RESOLVER_ABI_VERSION` than the host that received it. Its fields cannot
be read under this host's layout, so it is refused rather than called."""

comptime SCAN_SPLIT_POSITION_VERSION: StaticString = (
    "SCAN_SPLIT_POSITION_VERSION"
)
"""NAMED ERROR — a `SplitPosition` was encoded under another version of its
kind's position encoding (a checkpoint taken before the kind changed it). The
bytes cannot be read under this version, so the position is refused rather
than misread as an offset somewhere else in the split."""

comptime SCAN_SPLIT_POLLED_AFTER_END: StaticString = (
    "SCAN_SPLIT_POLLED_AFTER_END"
)
"""NAMED ERROR — a split reader was polled after it answered END. END is
final; a caller that polls again has lost track of the split."""

comptime SCAN_RESOLVER_FOREIGN_KIND: StaticString = (
    "SCAN_RESOLVER_FOREIGN_KIND"
)
"""NAMED ERROR — a resolver or reader was handed (or produced) a binding or a
split position for a kind that is not its own.

The erased facades enforce this once for every conformer, so no kind has to
remember to: a resolver that read a foreign binding would read ITS store with
ANOTHER kind's params, and a reader that resumed at a foreign position would
read the bytes as an offset of its own — wrong rows, not an error.
"""


# =============================================================================
# §1 — positions and splits (values only; no pointer, no engine type)
# =============================================================================


struct SplitPosition(Copyable, Equatable, Movable, Deinitable):
    """Where a split read is, in the kind's own encoding.

    Opaque to the engine and checkpointable as it is. `kind_id` says whose
    encoding the bytes are in and `version` which version of it; a foreign
    `kind_id` or a mismatched `version` is refused by name
    (`SCAN_RESOLVER_FOREIGN_KIND` / `SCAN_SPLIT_POSITION_VERSION`) where the
    erased facades take a position in. Ordering and monotonicity are the
    kind's obligation; the engine never compares two positions except for
    equality.
    """

    var kind_id: UInt32
    var version: UInt8
    var bytes: List[UInt8]

    def __init__(out self, kind_id: UInt32, version: UInt8, var bytes: List[UInt8]):
        self.kind_id = kind_id
        self.version = version
        self.bytes = bytes^

    def copy(self) -> Self:
        return Self(self.kind_id, self.version, self.bytes.copy())

    def __eq__(self, other: Self) -> Bool:
        if self.kind_id != other.kind_id or self.version != other.version:
            return False
        if len(self.bytes) != len(other.bytes):
            return False
        for i in range(len(self.bytes)):
            if self.bytes[i] != other.bytes[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def require_kind(
        self, kind_id: UInt32, version: UInt8, kind_name: String, what: String
    ) raises:
        """Refuse this position unless it is encoded by `kind_id` at `version`.
        `what` names the position in the message (`start of 'orders/3'`)."""
        if self.kind_id != kind_id:
            raise Error(
                String(SCAN_RESOLVER_FOREIGN_KIND)
                + String(": the ")
                + what
                + String(" position is encoded by kind id ")
                + String(self.kind_id)
                + String(", not by '")
                + kind_name
                + String("' (id ")
                + String(kind_id)
                + String(")")
            )
        if self.version != version:
            raise Error(
                String(SCAN_SPLIT_POSITION_VERSION)
                + String(": the ")
                + what
                + String(" position is encoded at version ")
                + String(Int(self.version))
                + String("; '")
                + kind_name
                + String("' reads version ")
                + String(Int(version))
            )


struct ScanSplit(Copyable, Movable, Deinitable):
    """One unit of a scan: a key, where reading starts, and where it stops.

    `split_key` is stable across executions (`orders/3`, `<index>/<object>`),
    so a checkpoint can name the split it holds a position for.

    `stop = None` means the split has no POSITION-shaped stop. It runs forever
    only when the binding names no stop either; a time-shaped stop cannot be
    written as a position before reading, so a reader enforces it itself and
    answers END. `drain_scan` reads only splits whose `stop` is set.

    `after` lists split keys that must reach their stops before this one is
    opened (a partition created by splitting or merging others reads after
    them). A split whose reader answered END short of its stop is cut, not
    finished, and its dependents are not opened.

    `est_rows` / `est_bytes` are scheduling hints, -1 when unknown. Nothing
    may depend on them for correctness.
    """

    var split_key: String
    var start: SplitPosition
    var stop: Optional[SplitPosition]
    var after: List[String]
    var est_rows: Int64
    var est_bytes: Int64

    def __init__(
        out self,
        var split_key: String,
        var start: SplitPosition,
        var stop: Optional[SplitPosition] = None,
        var after: List[String] = List[String](),
        est_rows: Int64 = -1,
        est_bytes: Int64 = -1,
    ):
        self.split_key = split_key^
        self.start = start^
        self.stop = stop^
        self.after = after^
        self.est_rows = est_rows
        self.est_bytes = est_bytes

    def copy(self) -> Self:
        var stop: Optional[SplitPosition] = None
        if self.stop:
            stop = Optional(self.stop.value().copy())
        return Self(
            split_key=String(self.split_key),
            start=self.start.copy(),
            stop=stop^,
            after=self.after.copy(),
            est_rows=self.est_rows,
            est_bytes=self.est_bytes,
        )

    def is_bounded(self) -> Bool:
        return Bool(self.stop)

    def resumed_at(self, var position: SplitPosition) -> Self:
        """This split, starting at `position` instead of `start`. What a
        checkpoint restore opens: the remainder of the same split, to the same
        stop."""
        var out = self.copy()
        out.start = position^
        return out^


struct ScanSplitPlan(Movable, Deinitable):
    """The splits ONE execution reads, and what the kind resolved to plan them.

    `complete` is True when no split will ever be added to this scan (a
    bounded kind, or a bounded read of an unbounded one). `resolved` is the
    side channel `drain_scan` hands back in `ScanOpened.resolved`: what the kind
    read to plan this execution (a generation, per-partition offsets).

    THE PLAN IS THE AUTHORITY on what an execution reads. `plan_splits` is the
    ONE execution-time read of the kind's store; each split's `stop` is exact,
    and `resolved` reports what those stops were derived from. The binding's
    snapshot token (tier 1, one `UInt64`) is freshness and identity only. A
    kind whose token cannot name its snapshot exactly (one number for many
    partitions) is not an exception to this rule; it is the reason for it.
    """

    var splits: List[ScanSplit]
    var complete: Bool
    var resolved: ScanParams

    def __init__(
        out self,
        var splits: List[ScanSplit],
        complete: Bool,
        var resolved: ScanParams,
    ):
        self.splits = splits^
        self.complete = complete
        self.resolved = resolved^

    def num_splits(self) -> Int:
        return len(self.splits)


struct SplitDelta(Movable, Deinitable):
    """Splits discovered since the plan (or the last delta), for a read that
    follows a growing set of splits. `complete` is True once none will be
    added again."""

    var added: List[ScanSplit]
    var complete: Bool

    def __init__(out self, var added: List[ScanSplit], complete: Bool):
        self.added = added^
        self.complete = complete


struct DrainedSplit(Copyable, Movable, Deinitable):
    """Where a drain left ONE split of its plan.

    `position` is the resume point after the last poll of the split, or its
    `start` when the drain never opened it. `cut` is True when the drain
    stopped before the split's stop: the row limit or the byte budget ran out
    in it or before it, its reader answered END short of its stop (a stop the
    reader enforces), or a split it reads `after` was cut. A continuation reads the split from `position`; a
    split that is not `cut` has nothing left to read.

    What `ScanSourceResolver.resolve_drained` receives, one per planned split,
    in plan order.
    """

    var split_key: String
    var position: SplitPosition
    var cut: Bool

    def __init__(out self, var split_key: String, var position: SplitPosition, cut: Bool):
        self.split_key = split_key^
        self.position = position^
        self.cut = cut

    def copy(self) -> Self:
        return Self(String(self.split_key), self.position.copy(), self.cut)


# =============================================================================
# §2 — polling a split
# =============================================================================

comptime SPLIT_POLL_ROWS: UInt8 = 0
"""The poll read something: `position` is past it, and `batch` holds its
visible rows (None when everything it read was filtered out)."""
comptime SPLIT_POLL_IDLE: UInt8 = 1
"""Nothing to read now, and the split has not reached its stop. Poll again
later; `position` is unchanged."""
comptime SPLIT_POLL_END: UInt8 = 2
"""Never polled again: the split reached its stop, or a stop the reader
enforces (a per-split byte budget) ended it short of it. `position` is where
the rest of the split starts, so END short of the stop is a cut."""


struct SplitPoll(Movable, Deinitable):
    """One poll's answer.

    `batch` carries the BINDING's schema, the same in every batch of every
    split (the `ScanOpened` rule). `position` is the resume point AFTER this
    poll, checkpointable as it is. `source_bytes` is what the poll consumed
    from the kind's store, as the kind measures it (0 when it does not); it is
    what a byte budget counts. `source_ts_hint_us` is -1 or the kind's own
    progress clock; it is a hint and NOT a watermark (the engine derives
    watermarks per split from the binding).
    """

    var status: UInt8
    var batch: Optional[RecordBatch]
    var position: SplitPosition
    var source_bytes: Int64
    var source_ts_hint_us: Int64

    def __init__(
        out self,
        status: UInt8,
        var position: SplitPosition,
        var batch: Optional[RecordBatch] = None,
        source_bytes: Int64 = 0,
        source_ts_hint_us: Int64 = -1,
    ):
        self.status = status
        self.batch = batch^
        self.position = position^
        self.source_bytes = source_bytes
        self.source_ts_hint_us = source_ts_hint_us

    @staticmethod
    def rows(
        var batch: RecordBatch, var position: SplitPosition, source_bytes: Int64 = 0
    ) -> SplitPoll:
        return SplitPoll(
            SPLIT_POLL_ROWS,
            position^,
            Optional(batch^),
            source_bytes=source_bytes,
        )

    @staticmethod
    def idle(var position: SplitPosition) -> SplitPoll:
        return SplitPoll(SPLIT_POLL_IDLE, position^)

    @staticmethod
    def end(var position: SplitPosition) -> SplitPoll:
        return SplitPoll(SPLIT_POLL_END, position^)

    def is_rows(self) -> Bool:
        return self.status == SPLIT_POLL_ROWS

    def is_idle(self) -> Bool:
        return self.status == SPLIT_POLL_IDLE

    def is_end(self) -> Bool:
        return self.status == SPLIT_POLL_END

    def num_rows(self) -> Int:
        if self.batch:
            return self.batch.value().num_rows()
        return 0


trait SplitReader(Movable, Deinitable):
    """Reads ONE split, from the start it was opened at to its stop.

    The reader owns its cursor (`mut self`); the resolver that opened it is
    borrowed and never mutated. A reader holds what it needs to finish its
    split (the split's bytes, a pinned snapshot), because the window between
    planning and reading is not bounded by one call.
    """

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        """Read at most about `max_rows` rows / `max_bytes` source bytes (each
        -1 for no bound). A poll that can make progress always does: the first
        unit the kind reads (a record batch, a segment) is returned WHOLE even
        when it exceeds either bound, so a small budget never stalls a read."""
        ...


# =============================================================================
# §3 — ErasedSplitReader — one reader behind a non-generic facade
# =============================================================================

# SAFETY: the two fn-ptr aliases below are private (underscore-named, not
# re-exported) and type only private fields of `ErasedSplitReader`. Its one
# constructor, generic over the concrete `R`, binds both to trampolines for that
# same `R`, so the reinterpret of `_home`'s bytes back to `R` is type-correct.
# The pointer is formed from the live `_home` at each call and borrowed for that
# call only; only the drop arm consumes the home, once, from the destructor.
comptime _PollFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin], Int64, Int64
) raises thin -> SplitPoll
comptime _DropReaderFn = def (UnsafePointer[UInt8, MutUntrackedOrigin]) thin -> None


struct ErasedSplitReader(SplitReader, Movable, Deinitable):
    """A RUNTIME-erased `SplitReader`. Construct with
    `ErasedSplitReader(reader^, ...)` (or `ErasedSplitReader.erase[R]`).

    Adds what every reader would otherwise have to remember: a position for
    another kind (or another encoding version) is refused on the way out, and
    a poll after END is refused by name.
    """

    # FIRST FIELD, deliberately: the layout version, readable before any other
    # field is trusted (see `SCAN_RESOLVER_ABI_VERSION`).
    var _abi: UInt32
    # `_home` owns the raw bytes of the concrete R (`alloc[R](1)` + a move into
    # it + `bitcast[UInt8]()`). CONCRETE origin, ASAP-tracked. The single
    # pointer field — no wildcard origin in any field.
    var _home: OwnedPointer[UInt8]
    var _kind_id: UInt32
    var _position_version: UInt8
    var _kind_name: String
    var _split_key: String
    var _ended: Bool
    # FFI-POD thin fn-ptr fields (code pointers, no heap — the carve-out).
    var _poll_fn: _PollFn
    var _drop_fn: _DropReaderFn

    def __init__[
        R: SplitReader
    ](
        out self,
        var reader: R,
        kind_id: UInt32,
        position_version: UInt8,
        var kind_name: String,
        var split_key: String,
    ):
        """Erase a concrete reader of the split `split_key` of kind `kind_id`.

        The ONLY constructor: it boxes `reader` and binds both trampolines for
        the same `R` itself, so no caller can pair a home with a vtable bound
        for another type, and no pointer or fn-ptr type appears in the
        signature.

        SAFETY: `alloc[R](1)` + an in-place move puts `reader` on a fresh heap
        slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single ownership
        of the byte-cast slot (concrete origin, ASAP-tracked). Both trampolines
        are bound for the SAME `R`, so the in-body reinterpret of the home ptr
        is type-correct by construction.
        """
        var home_typed = alloc[R](1)
        # SAFETY: fresh allocation we own; move-construct `reader` into it.
        UnsafePointer(to=home_typed[]).unsafe_write(reader^)
        self._abi = SCAN_RESOLVER_ABI_VERSION
        self._home = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
        )
        self._kind_id = kind_id
        self._position_version = position_version
        self._kind_name = kind_name^
        self._split_key = split_key^
        self._ended = False
        self._poll_fn = _erased_split_poll_for[R]
        self._drop_fn = _erased_split_drop_for[R]

    @staticmethod
    def erase[
        R: SplitReader
    ](
        var reader: R,
        kind_id: UInt32,
        position_version: UInt8,
        var kind_name: String,
        var split_key: String,
    ) -> ErasedSplitReader:
        """`ErasedSplitReader(reader^, ...)`, spelled as the verb."""
        return ErasedSplitReader(
            reader^, kind_id, position_version, kind_name^, split_key^
        )

    def abi_version(self) -> UInt32:
        return self._abi

    def require_abi(self, expected: UInt32) raises:
        """Refuse this facade unless it was built at `expected`, the
        `SCAN_RESOLVER_ABI_VERSION` the receiving host was compiled with."""
        _require_abi(self._abi, expected, String("split reader"))

    def split_key(self) -> String:
        return String(self._split_key)

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        """SAFETY: `_home` owns R's heap home for this facade's lifetime. The
        byte ptr formed here is reinterpreted by the trampoline as the SAME R
        bound at construction, and R's `mut self` `poll` runs in place through it
        (not moved, not freed). `self` is borrowed `mut` for the call, so
        nothing else reaches the home meanwhile. The untracked origin is
        confined to this cast-site body."""
        if self._ended:
            raise Error(
                String(SCAN_SPLIT_POLLED_AFTER_END)
                + String(": split '")
                + self._split_key
                + String("' of '")
                + self._kind_name
                + String("' already answered END")
            )
        var p = self._home.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var out = self._poll_fn(p, max_rows, max_bytes)
        out.position.require_kind(
            self._kind_id,
            self._position_version,
            self._kind_name,
            String("polled '") + self._split_key + String("'"),
        )
        if out.is_end():
            self._ended = True
        return out^

    def __deinit__(deinit self):
        """Destroy the erased R AND free its home in ONE shot via `_drop_fn`.

        SAFETY: `unsafe_leak()` relinquishes the home's free so it does NOT also
        free the buffer; `_drop_fn` reconstructs one `OwnedPointer[R]` over the
        SAME allocation and runs destroy + free exactly once."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._drop_fn(raw)


def _require_abi(found: UInt32, expected: UInt32, what: String) raises:
    if found != expected:
        raise Error(
            String(SCAN_RESOLVER_ABI_MISMATCH)
            + String(": the erased ")
            + what
            + String(" was built at scan-resolver ABI ")
            + String(found)
            + String("; this host reads ABI ")
            + String(expected)
        )


def _erased_split_poll_for[
    R: SplitReader
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], max_rows: Int64, max_bytes: Int64
) raises -> SplitPoll:
    """SAFETY: `home` is the byte-cast of the live `OwnedPointer[R]` home the
    facade owns (the same R bound here at construction); it is reinterpreted to
    `R*` and R's `poll` runs in place — R is neither moved nor freed."""
    var rp = home.bitcast[R]()
    return rp[].poll(max_rows, max_bytes)


def _erased_split_drop_for[
    R: SplitReader
](home: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """Reconstruct ONE `OwnedPointer[R]` over the home bytes and let it run R's
    destructor + free the allocation in a single tracked consume.

    SAFETY: `home` is the byte-cast of the R-home allocation whose free the
    facade's `__deinit__` relinquished (`unsafe_leak()`); reconstructing the
    single owner over the SAME bytes makes destroy + free happen exactly once.
    """
    var owned = OwnedPointer[R](unsafe_from_raw_pointer=home.bitcast[R]())
    var r = owned^.into_inner()
    _ = r^
