# =============================================================================
# mark_semi_anti -- `MarkSemiAntiProbeOp`, the marking pass of a SEMI or ANTI
# join that builds its LEFT side and streams its RIGHT side
# =============================================================================
#
# A SEMI join keeps the LEFT rows with a match on the RIGHT, an ANTI join the
# LEFT rows without one. The usual kernel builds a table over the RIGHT side and
# probes it with the LEFT rows; when the LEFT side is much the smaller, building
# it is cheaper. This operator is the probe half of that orientation: a table
# over the LEFT key (`FinalizedHashIndex`) is shared by every worker, each
# worker streams RIGHT morsels through `execute`, and every LEFT build row that
# some RIGHT row's key equals gets its matched flag set. `execute` emits
# nothing: it empties the morsel and returns NEED_MORE_INPUT, so a collecting
# sink receives no rows. After the workers finish, the caller reads the LEFT
# survivors with `FinalizedHashIndex.collect_marked_indices` (set for SEMI,
# clear for ANTI) and gathers them from the build batch: each surviving LEFT
# row once, in LEFT row order, which is the order and multiplicity the usual
# kernel produces.
#
# KEYS. Single INT64 key on each side (the probe key column is read as the
# single-key join probe reads it, `acquire_probe_key`). A NULL RIGHT key
# matches nothing and marks no row. A NULL LEFT key is never linked into the
# table (`HashJoinBuilder`), so its row stays unmarked: SEMI drops it and ANTI
# keeps it, as DuckDB does.
#
# A RIGHT row that the morsel's selection mask excludes marks nothing: a row a
# filter removed is not a row of the join's input.
#
# The table may use either chain-entry layout of `HashJoinBuilder` (fused or
# split, with or without `build_indices`, and payload-inline); the walk is
# specialised on the layout at compile time.
# =============================================================================

from std.memory import ArcPointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_op_join_build.join import (
    HashJoinBuilder,
    _CHAIN_END,
    _PREFETCH_DISTANCE,
    _hash_join_key,
)
from komira_op_join_probe.join_probe_op_state import acquire_probe_key

from .finalized_hash_index import FinalizedHashIndex


struct MarkSemiAntiProbeOp(MorselOperatorImpl):
    """The marking probe of a LEFT-built SEMI / ANTI join; see the module
    header.

    One per worker. Every worker's operator holds a handle to the same
    `FinalizedHashIndex` (built over the LEFT key) and the name of the RIGHT
    key column it reads from each morsel.
    """

    var _index: ArcPointer[FinalizedHashIndex]
    var _probe_key_name: String

    def __init__(
        out self,
        var index: ArcPointer[FinalizedHashIndex],
        var probe_key_name: String,
    ):
        """One worker's marking operator.

        Args:
            index: The shared index over the LEFT side's key.
            probe_key_name: The RIGHT (streamed) side's INT64 key column.
        """
        self._index = index^
        self._probe_key_name = probe_key_name^

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Mark the LEFT rows this RIGHT morsel matches, then empty the morsel
        and return NEED_MORE_INPUT."""
        if morsel.batch.num_rows() == 0 or self._index[].num_rows() == 0:
            morsel.replace_batch(RecordBatch())
            return ExecResult(NEED_MORE_INPUT)
        var key_idx = morsel.batch.schema.column_index(self._probe_key_name)
        var keys = acquire_probe_key(morsel.batch.column_at(key_idx))
        ref idx = self._index[]
        ref b = idx.builder
        if b._fused:
            if b._bi_elided:
                _mark[True, True](idx, keys, morsel.batch)
            else:
                _mark[True, False](idx, keys, morsel.batch)
        else:
            if b._bi_elided:
                _mark[False, True](idx, keys, morsel.batch)
            else:
                _mark[False, False](idx, keys, morsel.batch)
        _ = keys
        morsel.replace_batch(RecordBatch())
        return ExecResult(NEED_MORE_INPUT)


def _mark[
    fused: Bool, nobi: Bool
](
    imm idx: FinalizedHashIndex,
    imm probe_keys: PrimitiveArray[DType.int64],
    imm batch: RecordBatch,
) raises:
    """Set the flag of every build row whose key equals some probe row's key.

    Every matching build row is marked (no stop at the first match, unlike a
    SEMI probe, which only asks whether a probe row matches). Specialised on
    the chain-entry layout: `fused` reads `key_next` at the builder's stride,
    `nobi` takes the chain index as the build row."""
    ref b = idx.builder
    var n = probe_keys.length
    var mask = UInt64(b.capacity - 1)
    var probe_has_nulls = probe_keys.null_count != 0
    var has_sel = batch.has_selection_mask()
    var kn = b.kn_stride()

    # SAFETY: the raw pointers below read the builder's lists and the probe
    # key buffer, which `idx` and `probe_keys` keep alive for the whole call
    # (the keepalives at the end); chain indices come from `build`, which only
    # writes valid entry indices or `_CHAIN_END`.
    var key_view = probe_keys.view_ro()
    var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var kn_ptr = b.key_next.unsafe_ptr()

    # NOT-VECTORIZABLE: a chain walk is data dependent. Two-stage prefetch as
    # in the SEMI probe: the bucket a full distance ahead, the chain head half
    # a distance ahead.
    for i in range(n):
        if i + _PREFETCH_DISTANCE < n:
            var fk = Int64((key_ptr + i + _PREFETCH_DISTANCE)[])
            var fslot = Int(_hash_join_key(fk) & mask)
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (ht_ptr + fslot).bitcast[Scalar[DType.int64]]()
            )
        if i + _PREFETCH_DISTANCE // 2 < n:
            var mk = Int64((key_ptr + i + _PREFETCH_DISTANCE // 2)[])
            var mhead = (ht_ptr + Int(_hash_join_key(mk) & mask))[]
            if mhead != _CHAIN_END:
                comptime if fused:
                    prefetch[
                        params = PrefetchOptions().for_read().high_locality()
                    ]((kn_ptr + kn * mhead).bitcast[Scalar[DType.int64]]())
                else:
                    prefetch[
                        params = PrefetchOptions().for_read().high_locality()
                    ]((bk_ptr + mhead).bitcast[Scalar[DType.int64]]())

        if probe_has_nulls and probe_keys.is_null(i):
            continue
        if has_sel and not batch.selection_mask_get(i):
            continue
        var key = Int64((key_ptr + i)[])
        var h = _hash_join_key(key)
        # The bloom is a placeholder over a NULL buffer when `_use_bloom` is
        # False; it must not be consulted then.
        if b._use_bloom and not b.bloom.might_contain_join_key(key, h):
            continue
        var c = (ht_ptr + Int(h & mask))[]
        while c != _CHAIN_END:
            var ck: Int64
            var nxt: Int
            comptime if fused:
                ck = (kn_ptr + kn * c)[]
                nxt = Int((kn_ptr + kn * c + 1)[])
            else:
                ck = (bk_ptr + c)[]
                nxt = (nc_ptr + c)[]
            if ck == key:
                comptime if nobi:
                    idx.mark_matched(c)
                else:
                    idx.mark_matched((bi_ptr + c)[])
            c = nxt

    _ = b.hash_table
    _ = b.build_keys
    _ = b.next_chain
    _ = b.build_indices
    _ = b.key_next
    _ = key_view
