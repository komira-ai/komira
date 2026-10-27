# =============================================================================
# topn_late_mat — the scan side of a two-phase (late-materialized) top-N
# =============================================================================
#
# `SELECT <many columns> WHERE <filter> ORDER BY <key> LIMIT n` decodes every
# projected column of every row group the filter and the running top-N
# boundary let through, to return n rows that come from a few of them. A
# two-phase top-N decodes the wide columns only where the answer lives:
#
#   phase 1: the same scan, filter and top-N, projecting only the sort keys,
#            with `TopNRowGroupStampOp` stamping each surviving row with the
#            row group it came from;
#   phase 2: the full projection, the same filter and top-N, over only the
#            row groups phase 1's answer names (`ParquetSource`'s
#            `claim_units`, given `topn_late_mat_winner_row_groups`).
#
# Phase 2 returns phase 1's rows. Phase 1's answer W is a top-n of every row
# that passes the filter; phase 2 runs the same comparator over a subset S of
# those rows that contains W, and the top-n of any S with W in S is W: no row
# of S beats W's n-th (it would have beaten it in the whole), and W is in S.
# Ties resolve in file order on both phases (this relies on the top-N sink,
# which lives outside this package, ordering by `(partition_id, origin_hint)`
# and placing a NULL key the same way in both phases; the tests here model
# that rule, they do not run the sink), so the rows W won its ties with are also the
# earliest tied rows in S. DuckDB's late materialization rewrites the same
# query into a semi join on the row id; one-page column chunks make the row
# group the finest grain a Parquet scan can fetch at.
#
# The driver that decides to take two phases and runs both is not here; this
# module holds the pieces that know how the source numbers row groups. The
# counters below are how a test or a trace tells the two-phase route ran (both
# routes return the same rows).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl

from .parquet_source_options import rg_index_of_partition_id


comptime TOPN_LATE_MAT_RG_COLUMN: StaticString = "__komira_topn_late_mat_rg"
"""The stamp column's name. The driver must not take two phases over a file
that has a column of this name."""


struct TopNRowGroupStampOp(MorselOperatorImpl):
    """Appends `TOPN_LATE_MAT_RG_COLUMN` (INT64, non-null): the flat row group
    each morsel was decoded from, recovered from its partition id
    (`rg_index_of_partition_id`), so the number is the one `claim_units` takes.
    That holds when every morsel comes from one row group: the whole-row-group
    and one-morsel-per-unit emits. A coarse row-range emit concatenates units
    across row groups under the first unit's id; the driver must not take two
    phases then (`topn_stamp_is_exact`).

    The column has the batch's physical row count, so a batch that still
    carries a deferred selection mask stays consistent: the mask gathers the
    stamp with every other column. Stateless; one per worker."""

    def __init__(out self):
        pass

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var n = morsel.batch.num_rows()
        var rg = Int64(rg_index_of_partition_id(morsel.partition_id))
        var values = List[Int64](capacity=n)
        for _ in range(n):
            values.append(rg)
        morsel.batch.append_column(
            Field(String(TOPN_LATE_MAT_RG_COLUMN), ArrowType.INT64, False),
            Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values)),
        )
        return ExecResult(NEED_MORE_INPUT)


def topn_late_mat_winner_row_groups(batch: RecordBatch) raises -> List[Int]:
    """The distinct row groups phase 1's answer came from, ascending.

    Raises:
        If a non-empty `batch` has no stamp column (phase 2 would otherwise
        get an empty allow-list and return no row), or a stamp is negative.
    """
    var out = List[Int]()
    if batch.num_rows() == 0:
        return out^
    var ci = -1
    for c in range(batch.schema.num_columns()):
        if batch.schema.field_at(c).name == String(TOPN_LATE_MAT_RG_COLUMN):
            ci = c
            break
    if ci < 0:
        raise Error(
            "topn_late_mat: phase-1 answer has " + String(batch.num_rows()) + " rows but no "
            + String(TOPN_LATE_MAT_RG_COLUMN) + " column"
        )
    var col = batch.column_as_primitive[DType.int64](ci)
    for i in range(batch.num_rows()):
        var rg = Int(col.get(i))
        if rg < 0:
            raise Error("topn_late_mat: negative row-group stamp " + String(rg))
        var seen = False
        for j in range(len(out)):
            if out[j] == rg:
                seen = True
                break
        if not seen:
            out.append(rg)
    sort(out)
    return out^


def _init_topn_late_mat_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _TOPN_LATE_MAT_RUNS = _Global["komira_parquet_topn_late_mat_runs", _init_topn_late_mat_counter]
comptime _TOPN_LATE_MAT_PHASE2_UNITS = _Global["komira_parquet_topn_late_mat_phase2_units", _init_topn_late_mat_counter]


def topn_late_mat_record(phase2_units: Int) raises:
    """Record one two-phase run whose phase 2 was allowed `phase2_units` row
    groups."""
    _ = _TOPN_LATE_MAT_RUNS.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _TOPN_LATE_MAT_PHASE2_UNITS.get_or_create_ptr()[][].fetch_add(Int64(phase2_units))


def topn_late_mat_runs() raises -> Int:
    """Two-phase runs recorded in this process."""
    return Int(_TOPN_LATE_MAT_RUNS.get_or_create_ptr()[][].load())


def topn_late_mat_phase2_units() raises -> Int:
    """The sum of the phase-2 allow-list sizes recorded in this process."""
    return Int(_TOPN_LATE_MAT_PHASE2_UNITS.get_or_create_ptr()[][].load())


def reset_topn_late_mat_counters() raises:
    """Zero both counters."""
    _TOPN_LATE_MAT_RUNS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _TOPN_LATE_MAT_PHASE2_UNITS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
