# =============================================================================
# join_deferred -- the records of the streaming join probe's DEFERRED output
# and the per-worker buckets that hold them.
# =============================================================================
#
# A morsel's output is either STAGED (assembled now, `staged_chunk`) or
# DEFERRED (`deferred_chunk`: the probe morsel and its match indices are
# retained and gathered once, at the end). `JoinDeferredState` holds one
# append-only bucket per worker and the rule each morsel is judged by
# (`deferral_verdict`); `assert_records_agree_on_layout` is the gather's
# precondition. No assembly happens here.
# =============================================================================

from std.memory import ArcPointer
from std.math import max

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_arrow.streaming_concat import _arrow_type_byte_width
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from .join_defer_verdict import (
    DEFER_ADMIT,
    DEFER_IDX_BYTES_PER_COL,
    deferral_verdict,
)

from .join_deferred_idx import (
    try_narrow_index_pair,
    try_narrow_index_single,
)


struct DeferredJoinChunk(Movable):
    """One morsel's contribution to the streaming join's output."""

    var probe_batch: RecordBatch
    var staged: RecordBatch
    var probe_idx: List[Int]
    var build_idx: List[Int]
    var probe_idx32: List[Int32]
    var build_idx32: List[Int32]
    var idx32: Bool
    var build_pay: List[Int64]
    var pay_col: Int
    var build_idx_elided: Bool
    var elide_alias: List[Int32]
    var partition_id: Int
    var origin_hint: Int
    var seq: Int
    var num_rows: Int
    var deferred: Bool
    var cse_ok: Bool

    def __init__(out self):
        self.probe_batch = RecordBatch()
        self.staged = RecordBatch()
        self.probe_idx = List[Int]()
        self.build_idx = List[Int]()
        self.probe_idx32 = List[Int32]()
        self.build_idx32 = List[Int32]()
        self.idx32 = False
        self.build_pay = List[Int64]()
        self.pay_col = -1
        self.build_idx_elided = False
        self.elide_alias = List[Int32]()
        self.partition_id = 0
        self.origin_hint = 0
        self.seq = 0
        self.num_rows = 0
        self.deferred = False
        self.cse_ok = False

    @staticmethod
    def deferred_chunk(
        var probe_batch: RecordBatch,
        var probe_idx: List[Int],
        var build_idx: List[Int],
        partition_id: Int,
        origin_hint: Int,
        seq: Int,
        cse_ok: Bool,
        var build_pay: List[Int64] = List[Int64](),
        pay_col: Int = -1,
        var elide_alias: List[Int32] = List[Int32](),
        build_idx_elided: Bool = False,
        nt_store: Bool = True,
    ) raises -> Self:
        """Construct the RETAINED-probe kind: the probe morsel and its match
        indices (narrowed to 4 bytes when they fit, written with non-temporal
        stores unless `nt_store` is False). With `pay_col >= 0` a build payload
        column rides inline (`build_pay`, one value per match); with
        `build_idx_elided` the build indices are dropped, which requires the
        payload plus a probe-side alias (`elide_alias`) for every other build
        column. Raises on any inconsistency among those."""
        var out = Self()
        out.num_rows = len(probe_idx)
        if pay_col >= 0 and len(build_pay) != out.num_rows:
            raise Error(
                "DeferredJoinChunk.deferred_chunk: build_pay length "
                + String(len(build_pay))
                + " != retained match count "
                + String(out.num_rows)
            )
        if build_idx_elided:
            if pay_col < 0:
                raise Error(
                    "DeferredJoinChunk.deferred_chunk: build_idx_elided with"
                    " no inlined payload -- nothing would serve the build"
                    " side"
                )
            if len(build_idx) != 0:
                raise Error(
                    "DeferredJoinChunk.deferred_chunk: build_idx_elided but"
                    " the build index list holds "
                    + String(len(build_idx))
                    + " entries -- the two statements contradict"
                )
            if len(elide_alias) <= pay_col:
                raise Error(
                    "DeferredJoinChunk.deferred_chunk: build_idx_elided with"
                    " an alias vector of "
                    + String(len(elide_alias))
                    + " entries, which does not cover pay_col "
                    + String(pay_col)
                )
            for c in range(len(elide_alias)):
                if c == pay_col:
                    continue
                if elide_alias[c] < 0:
                    raise Error(
                        "DeferredJoinChunk.deferred_chunk: build_idx_elided"
                        " but build column "
                        + String(c)
                        + " has no probe-side alias and no inlined payload"
                    )
        out.probe_batch = probe_batch^
        out.probe_idx = probe_idx^
        out.build_idx = build_idx^
        out.build_pay = build_pay^
        out.build_idx_elided = build_idx_elided
        out.elide_alias = elide_alias^
        _try_narrow_indices(out, nt_store)
        out.pay_col = pay_col if pay_col >= 0 else -1
        out.partition_id = partition_id
        out.origin_hint = origin_hint
        out.seq = seq
        out.deferred = True
        out.cse_ok = cse_ok
        return out^

    @staticmethod
    def staged_chunk(
        var staged: RecordBatch,
        partition_id: Int,
        origin_hint: Int,
        seq: Int,
        cse_ok: Bool,
    ) -> Self:
        """Construct the ALREADY-ASSEMBLED kind (the pre-deferral shape)."""
        var out = Self()
        out.num_rows = staged.num_rows()
        out.staged = staged^
        out.partition_id = partition_id
        out.origin_hint = origin_hint
        out.seq = seq
        out.deferred = False
        out.cse_ok = cse_ok
        return out^


def _try_narrow_indices(mut rec: DeferredJoinChunk, nt_store: Bool) raises:
    """Replace `rec`'s 8-byte index lists with 4-byte ones, or REFUSE."""
    if rec.build_idx_elided:
        var one = try_narrow_index_single(rec.probe_idx, rec.num_rows, nt_store)
        if not one.ok:
            _ = one^
            return
        rec.probe_idx32 = one.probe32.take()
        rec.idx32 = True
        rec.probe_idx = List[Int]()
        return
    var narrowed = try_narrow_index_pair(
        rec.probe_idx, rec.build_idx, rec.num_rows, nt_store
    )
    if not narrowed.ok:
        _ = narrowed^
        return
    rec.probe_idx32 = narrowed.probe32.take()
    rec.build_idx32 = narrowed.build32.take()
    rec.idx32 = True
    rec.probe_idx = List[Int]()
    rec.build_idx = List[Int]()


@always_inline
def _layout_disagreement(
    imm col: Column[HeapRegion],
    want_type: ArrowType,
    want_dec_p: Int,
    want_dec_s: Int,
) -> String:
    """The EMPTY string if `col` carries exactly
    `(want_type, want_dec_p, want_dec_s)`, else a one-line description of the
    FIRST way it does not.
    """
    if col.arrow_type != want_type:
        return (
            String("arrow_type ")
            + String(col.arrow_type)
            + " != "
            + String(want_type)
        )
    if col._decimal_p != want_dec_p or col._decimal_s != want_dec_s:
        return (
            String("decimal (p, s) = (")
            + String(col._decimal_p)
            + ", "
            + String(col._decimal_s)
            + ") != ("
            + String(want_dec_p)
            + ", "
            + String(want_dec_s)
            + ")"
        )
    return String("")


def assert_records_agree_on_layout(
    imm chunks: Slab[DeferredJoinChunk],
    imm col_type: List[ArrowType],
    imm col_dec_p: List[Int],
    imm col_dec_s: List[Int],
    probe_ncols: Int,
) raises:
    """Raise unless EVERY record's source columns carry the layout the
    destination buffers were typed, sized and strided for (type, and decimal
    precision and scale): a record that disagrees would be gathered into a
    correctly sized, silently corrupt buffer.
    """
    var num_cols = len(col_type)
    var n = len(chunks)
    for k in range(n):
        ref ch = chunks[k]
        if ch.num_rows == 0:
            continue
        if ch.deferred:
            if ch.probe_batch.num_columns() < probe_ncols:
                raise Error(
                    "assemble_deferred_join_output: deferred record "
                    + String(k)
                    + " retained a probe batch of "
                    + String(ch.probe_batch.num_columns())
                    + " columns but the output's probe half is "
                    + String(probe_ncols)
                    + " columns wide -- the gather would read a column that"
                    " does not exist."
                )
            for c in range(probe_ncols):
                var why = _layout_disagreement(
                    ch.probe_batch.column_at(c),
                    col_type[c],
                    col_dec_p[c],
                    col_dec_s[c],
                )
                if why:
                    raise Error(
                        "assemble_deferred_join_output: DEFERRED record "
                        + String(k)
                        + " (partition "
                        + String(ch.partition_id)
                        + ", origin "
                        + String(ch.origin_hint)
                        + ") disagrees with the assembly's layout on output"
                        " column "
                        + String(c)
                        + ": "
                        + why
                        + ". The gather strides this column by the reference"
                        " record's width, so proceeding would write a"
                        " correctly-sized, silently corrupt buffer."
                    )
            continue
        if ch.staged.num_columns() != num_cols:
            raise Error(
                "assemble_deferred_join_output: STAGED record "
                + String(k)
                + " carries "
                + String(ch.staged.num_columns())
                + " columns but the join output is "
                + String(num_cols)
                + " columns wide."
            )
        for c in range(num_cols):
            var why = _layout_disagreement(
                ch.staged.column_at(c),
                col_type[c],
                col_dec_p[c],
                col_dec_s[c],
            )
            if why:
                raise Error(
                    "assemble_deferred_join_output: STAGED record "
                    + String(k)
                    + " (partition "
                    + String(ch.partition_id)
                    + ", origin "
                    + String(ch.origin_hint)
                    + ") disagrees with the assembly's layout on output column "
                    + String(c)
                    + ": "
                    + why
                    + ". The staged arm block-copies this column at the"
                    " reference record's width, so proceeding would write a"
                    " correctly-sized, silently corrupt buffer."
                )


struct JoinDeferredBucket(Movable):
    """One worker's append-only record list."""

    var chunks: Slab[DeferredJoinChunk]

    def __init__(out self):
        self.chunks = Slab[DeferredJoinChunk]()


struct JoinDeferredState(Movable):
    """Driver-owned, Arc-shared deferred-gather state for one streaming probe."""

    var buckets: Slab[JoinDeferredBucket]
    var num_slots: Int
    var out_row_width: Int
    var out_num_cols: Int
    var force_defer: Bool
    var traffic_rule: Bool
    var idx_bytes_per_col: Int

    def __init__(
        out self,
        var buckets: Slab[JoinDeferredBucket],
        num_slots: Int,
        out_row_width: Int,
        out_num_cols: Int,
        force_defer: Bool,
        traffic_rule: Bool,
        idx_bytes_per_col: Int,
    ):
        self.buckets = buckets^
        self.num_slots = num_slots
        self.out_row_width = out_row_width
        self.out_num_cols = out_num_cols
        self.force_defer = force_defer
        self.traffic_rule = traffic_rule
        self.idx_bytes_per_col = idx_bytes_per_col


def build_join_deferred_state(
    num_workers: Int,
    out_row_width: Int,
    out_num_cols: Int,
    force_defer: Bool = False,
    traffic_rule: Bool = True,
    idx_bytes_per_col: Int = DEFER_IDX_BYTES_PER_COL,
) raises -> ArcPointer[JoinDeferredState]:
    """Construct the per-worker bucket slab inside an ArcPointer, with the
    deferral rule the join's morsels are judged by: `force_defer` admits every
    priceable morsel, `traffic_rule` selects the traffic rule over the memory
    rule, `idx_bytes_per_col` is the index width it prices (see
    `deferral_verdict`). The defaults are the shipped rule."""
    var n = max(num_workers, 1)
    var buckets = Slab[JoinDeferredBucket].create(n)
    for _ in range(n):
        buckets.append(JoinDeferredBucket())
    var st = JoinDeferredState(
        buckets^,
        n,
        out_row_width,
        out_num_cols,
        force_defer,
        traffic_rule,
        idx_bytes_per_col,
    )
    return ArcPointer[JoinDeferredState](st^)


def deferred_probe_retained_bytes(imm batch: RecordBatch) raises -> Int:
    """Bytes retaining THIS morsel costs, or -1 if it cannot be priced."""
    var total = 0
    for c in range(batch.num_columns()):
        var w = _arrow_type_byte_width(batch.column_at(c).arrow_type)
        if w <= 0:
            return -1
        total += batch.num_rows() * w
    return total


@always_inline
def admits_deferral(
    probe_bytes: Int,
    matches: Int,
    out_row_width: Int,
    force: Bool = False,
    out_num_cols: Int = 0,
    traffic_rule: Bool = False,
    retained_bytes_per_match: Int = 16,
    idx_bytes_per_col: Int = 8,
) -> Bool:
    """Should THIS morsel defer? `deferral_verdict(...) == DEFER_ADMIT`."""
    return (
        deferral_verdict(
            probe_bytes,
            matches,
            out_row_width,
            force,
            out_num_cols,
            traffic_rule,
            retained_bytes_per_match,
            idx_bytes_per_col,
        )
        == DEFER_ADMIT
    )
