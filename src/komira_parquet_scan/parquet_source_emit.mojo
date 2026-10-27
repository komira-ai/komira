# =============================================================================
# parquet_source_emit — how the morsel source hands a decoded row group out
# =============================================================================
#
# A decode arm of the source ends in a `ClaimOutcome`: skip the claimed row
# group (nothing in it survives), fall through to the next arm, or emit a
# batch. The source then turns an emitted batch into morsels: a batch larger
# than `morsel_rows` is cut into sub-morsels (`split_and_stash_first`), the
# first returned and the rest parked on the worker's pending slab in reverse,
# so the worker's next calls pop them in order. Sub-morsel `k` of row group
# `rg` takes partition id `rg * SUB_SLOT_STRIDE + slot_base + k` and origin
# hint `slot_base + k`, which the collect sink's sort turns back into file
# order. A count-only batch is never cut.
# =============================================================================

from std.builtin.swap import swap

from komira_arrow.record_batch import RecordBatch
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel, split_record_batch

from .parquet_source_options import SUB_SLOT_STRIDE


struct CursorState:
    """The source's shared atomics, zero-filled in place in a one-slot
    `Slab` (an atomic does not move).

    Fields:
        rg_cursor: the next claim index.
        cursor_fetch_adds: claims of a stride from the cursor.
        morsel_counter: the next morsel id.
        rgs_decoded: row groups decoded.
        rgs_allmatch: row groups counted from the footer.
        subrg_counter: the next row-range unit.
    """

    var rg_cursor: AtomicI64
    var cursor_fetch_adds: AtomicI64
    var morsel_counter: AtomicI64
    var rgs_decoded: AtomicI64
    var rgs_allmatch: AtomicI64
    var subrg_counter: AtomicI64


comptime OUTCOME_SKIP: Int = 0
comptime OUTCOME_FALL_THROUGH: Int = 1
comptime OUTCOME_EMIT: Int = 2
comptime OUTCOME_EMIT_COUNT: Int = 3


struct ClaimOutcome(Movable):
    """What a decode arm made of a claimed row group.

    Fields:
        kind: `OUTCOME_SKIP` (no row survives), `OUTCOME_FALL_THROUGH` (the
            arm does not apply), `OUTCOME_EMIT` (emit `batch`, cut to
            `morsel_rows`) or `OUTCOME_EMIT_COUNT` (emit the count-only
            `batch` whole).
        batch: the batch to emit.
        allmatch: the row group was counted from its statistics.
    """

    var kind: Int
    var batch: Optional[RecordBatch]
    var allmatch: Bool

    def __init__(out self, kind: Int, var batch: Optional[RecordBatch] = None, allmatch: Bool = False):
        self.kind = kind
        self.batch = batch^
        self.allmatch = allmatch

    @staticmethod
    def skip() -> ClaimOutcome:
        return ClaimOutcome(OUTCOME_SKIP)

    @staticmethod
    def fall_through() -> ClaimOutcome:
        return ClaimOutcome(OUTCOME_FALL_THROUGH)

    @staticmethod
    def emit(var batch: RecordBatch) -> ClaimOutcome:
        return ClaimOutcome(OUTCOME_EMIT, Optional(batch^))

    @staticmethod
    def emit_count(rows: Int, allmatch: Bool = False) raises -> ClaimOutcome:
        return ClaimOutcome(OUTCOME_EMIT_COUNT, Optional(RecordBatch.count_only(rows)), allmatch)


def _take_batch(var m: Morsel) -> RecordBatch:
    """A morsel's batch, the morsel left whole for its destructor."""
    var out = RecordBatch()
    swap(m.batch, out)
    _ = m^
    return out^


def split_and_stash_first(
    var batch: RecordBatch,
    morsel_rows: Int,
    claimed_rg: Int,
    mut morsel_counter: AtomicI64,
    mut pending: Slab[Morsel],
    slot_base: Int = 0,
) raises -> Morsel:
    """Cut `batch` into morsels of at most `morsel_rows` rows; return the
    first and park the rest on `pending` in reverse, so popping returns them
    in order. Each takes the next id of `morsel_counter`."""
    var ma = split_record_batch(batch^, morsel_rows)
    var n_sub = len(ma)
    if n_sub == 0:
        return Morsel(
            RecordBatch(),
            morsel_id=Int(morsel_counter.fetch_add(Int64(1))),
            partition_id=claimed_rg * SUB_SLOT_STRIDE + slot_base,
            origin_hint=slot_base,
        )
    var k = n_sub - 1
    while k >= 1:
        var mid_k = Int(morsel_counter.fetch_add(Int64(1)))
        var extracted = ma._inner.take_slot_unchecked(k)
        ma._inner.set_len_unchecked(len(ma._inner) - 1)
        pending.append(
            Morsel(
                _take_batch(extracted^),
                morsel_id=mid_k,
                partition_id=claimed_rg * SUB_SLOT_STRIDE + slot_base + k,
                origin_hint=slot_base + k,
            )
        )
        k -= 1
    var mid0 = Int(morsel_counter.fetch_add(Int64(1)))
    var extracted0 = ma._inner.take_slot_unchecked(0)
    ma._inner.set_len_unchecked(len(ma._inner) - 1)
    return Morsel(
        _take_batch(extracted0^),
        morsel_id=mid0,
        partition_id=claimed_rg * SUB_SLOT_STRIDE + slot_base,
        origin_hint=slot_base,
    )


def emit_outcome(
    var outcome: ClaimOutcome,
    morsel_rows: Int,
    claimed_rg: Int,
    mut morsel_counter: AtomicI64,
    mut pending: Slab[Morsel],
) raises -> Morsel:
    """The morsel of an emitting outcome: a count-only batch whole, any
    other batch cut to `morsel_rows` (when positive)."""
    var batch = outcome.batch.take()
    if outcome.kind == OUTCOME_EMIT and morsel_rows > 0 and batch.num_rows() > morsel_rows:
        return split_and_stash_first(batch^, morsel_rows, claimed_rg, morsel_counter, pending)
    return Morsel(
        batch^,
        morsel_id=Int(morsel_counter.fetch_add(Int64(1))),
        partition_id=claimed_rg * SUB_SLOT_STRIDE,
        origin_hint=0,
    )
