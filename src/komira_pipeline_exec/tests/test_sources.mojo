# =============================================================================
# SOURCE_BATCH, SOURCE_SINK_OUTPUT and SOURCE_PARQUET
# =============================================================================
#
# Each source is drained by workers claiming in turn, the way the driver's
# workers do. The Parquet files are written by `komira_parquet_writer` from the
# sample table (a = r, b = r * 10 with NULL where r % 5 == 2, s = "s" + r % 4)
# and read back by the source the spec builds. What these tests prove:
#
#   * A resident batch and a finished segment's output are each served as
#     morsels of the requested size, every row once across the workers, in the
#     positions the sink orders by, and each worker is told once that input has
#     ended.
#   * The builder refuses a Parquet spec that is not total, one with no path,
#     and one that names a column the file lacks, each by name.
#   * A Parquet scan returns every row of a file cut into several row groups,
#     of a glob of two files, with the columns of the projection in the order
#     it names them.
#   * A filter in the spec is applied by the scan: rows it rejects never come
#     out, a NULL operand rejects the row, a filter on a column the projection
#     leaves out still filters, and a filter that rejects every row of a row
#     group leaves it out.
#   * The filter of the spec also reaches the scan as the predicate that row
#     group statistics are checked against: row groups that cannot hold a
#     matching row are left out when the source is built (read from the scan's
#     prune counters).
#   * A glob that matches no file is refused, and the message names the glob.
#   * A morsel size cuts a row group into morsels without losing or repeating a
#     row.
#   * A worker the source was not built for is refused.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_scan.rg_prune_counter import (
    reset_rg_prune_counters,
    rg_prune_setup_evals,
    rg_prune_setup_pruned,
)
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import SourceSpecPod
from komira_pipeline_exec.plan_harness import (
    b_is_null,
    column_names,
    int64_column,
    sample_batch,
)
from komira_pipeline_exec.source_batch import BatchSource
from komira_pipeline_exec.source_parquet import build_parquet_source
from komira_pipeline_exec.source_sink_output import SinkOutputSource
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_GE,
    BIN_GT,
    BIN_LT,
    Expr,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir

comptime NW = 3


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), _lit(v))


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _range(lo: Int, hi: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(lo, hi):
        out.append(r)
    return out^


def _drain[S: MorselSourceImpl](src: S) raises -> Slab[Morsel]:
    """Every morsel, the workers claiming in turn until each has been told
    the input ended; each worker is asked again after that and must say so
    again."""
    var out = Slab[Morsel]()
    var live = List[Bool](length=NW, fill=True)
    var n_live = NW
    while n_live > 0:
        for w in range(NW):
            if not live[w]:
                continue
            var m = src.next_morsel(w)
            if m:
                out.append(m.take())
            else:
                live[w] = False
                n_live -= 1
    return out^


def _in_position_order(ref morsels: Slab[Morsel]) -> List[Int]:
    """Indices of `morsels` sorted by (partition id, origin hint)."""
    var order = List[Int]()
    for i in range(len(morsels)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            ref p = morsels[order[j - 1]]
            ref q = morsels[order[j]]
            var after = p.partition_id > q.partition_id or (
                p.partition_id == q.partition_id
                and p.origin_hint > q.origin_hint
            )
            if not after:
                break
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    return order^


def _column(ref morsels: Slab[Morsel], col: Int) raises -> List[Int]:
    """Column `col` of the rows the morsels keep, in position order."""
    var out = List[Int]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        ref batch = morsels[order[k]].batch
        var values = int64_column(batch, col)
        for i in range(len(values)):
            if batch.has_selection_mask() and not batch.selection_mask_get(i):
                continue
            out.append(values[i])
    return out^


def _write(name: String, start: Int, rows: Int, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        sample_batch(start, rows), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


# ---- SOURCE_BATCH and SOURCE_SINK_OUTPUT ------------------------------------


def test_a_resident_batch_is_served_in_morsels_of_the_requested_size() raises:
    var src = BatchSource(sample_batch(0, 25), 10)
    assert_equal(src.row_count_hint(), 25)
    assert_equal(src.output_schema().num_columns(), 3)
    var morsels = _drain(src)
    assert_equal(len(morsels), 3)
    var sizes = List[Int]()
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        sizes.append(morsels[order[k]].num_rows())
    _expect(sizes, [10, 10, 5])
    _expect(_column(morsels, 0), _range(0, 25))


def test_a_finished_segments_output_is_served_the_same_way() raises:
    var src = SinkOutputSource(sample_batch(100, 17), 4, 6)
    assert_equal(src.producer(), 4)
    var morsels = _drain(src)
    assert_equal(len(morsels), 3)
    _expect(_column(morsels, 0), _range(100, 117))


def test_an_output_of_no_rows_is_served_as_no_morsel() raises:
    var src = SinkOutputSource(sample_batch(0, 0), 0, 10)
    assert_equal(len(_drain(src)), 0)
    assert_equal(src.output_schema().num_columns(), 3)


# ---- SOURCE_PARQUET ---------------------------------------------------------


def test_a_spec_that_is_not_total_is_refused() raises:
    var path = _write("not_total", 0, 10, 10)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(path^, None, None)
    with assert_raises(contains="is not total"):
        _ = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
            spec, 0, NW, cache, pool
        )


def test_a_spec_with_no_path_or_an_unknown_column_is_refused() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var nameless = SourceSpecPod.parquet(String(""), None, None, True)
    with assert_raises(contains="names no path"):
        _ = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
            nameless, 0, NW, cache, pool
        )
    var path = _write("unknown_column", 0, 10, 10)
    var spec = SourceSpecPod.parquet(path^, Optional(_names("a", "nope")), None, True)
    with assert_raises(contains="unknown projection column 'nope'"):
        _ = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
            spec, 0, NW, cache, pool
        )


def test_every_row_of_a_file_in_several_row_groups_comes_back() raises:
    var path = _write("rows", 0, 100, 30)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(path^, None, None, True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    assert_equal(src.num_row_groups(), 4)
    assert_equal(src.output_schema().num_columns(), 3)
    var morsels = _drain(src)
    _expect(_column(morsels, 0), _range(0, 100))
    # The NULLs of column b came back as NULLs.
    var order = _in_position_order(morsels)
    var seen = 0
    for k in range(len(order)):
        ref batch = morsels[order[k]].batch
        for i in range(batch.num_rows()):
            assert_equal(batch.column_at(1).is_null_at(i), b_is_null(seen + i))
        seen += batch.num_rows()
    assert_equal(seen, 100)


def test_the_projection_orders_the_columns_as_it_names_them() raises:
    var path = _write("projection", 0, 40, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(path^, Optional(_names("s", "a")), None, True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    var morsels = _drain(src)
    var names = column_names(morsels[0].batch)
    assert_equal(len(names), 2)
    assert_equal(names[0], "s")
    assert_equal(names[1], "a")
    _expect(_column(morsels, 1), _range(0, 40))


def test_a_glob_reads_every_file_it_matches() raises:
    _ = _write("glob_part_1", 0, 30, 15)
    _ = _write("glob_part_2", 30, 20, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(
        test_tmpdir() + "/glob_part_*.parquet", Optional(_names("a")), None, True
    )
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    assert_equal(src.num_files(), 2)
    _expect(_column(_drain(src), 0), _range(0, 50))


def test_the_filter_of_the_spec_is_applied_by_the_scan() raises:
    var path = _write("filtered", 0, 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    # 40 <= a < 60 keeps part of the second and third row groups and drops
    # the first and the fourth whole.
    var filter = Expr.binary(BIN_AND, _cmp(BIN_GE, "a", 40), _cmp(BIN_LT, "a", 60))
    var spec = SourceSpecPod.parquet(path^, None, Optional(filter^), True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    _expect(_column(_drain(src), 0), _range(40, 60))


def test_the_pushed_predicate_prunes_the_row_groups_it_excludes() raises:
    var path = _write("pruned", 0, 100, 25)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    # Row groups [0, 25) and [75, 100) hold no row of 40 <= a < 60.
    var filter = Expr.binary(BIN_AND, _cmp(BIN_GE, "a", 40), _cmp(BIN_LT, "a", 60))
    var spec = SourceSpecPod.parquet(path^, None, Optional(filter^), True)
    reset_rg_prune_counters()
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    assert_equal(rg_prune_setup_evals(), 1)
    assert_equal(rg_prune_setup_pruned(), 2)
    _expect(_column(_drain(src), 0), _range(40, 60))


def test_a_glob_that_matches_no_file_is_refused_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var glob = test_tmpdir() + "/no_such_part_*.parquet"
    var spec = SourceSpecPod.parquet(glob.copy(), Optional(_names("a")), None, True)
    var message = String("")
    try:
        _ = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
            spec, 0, NW, cache, pool
        )
    except e:
        message = String(e)
    assert_true(glob in message, message)


def test_a_null_operand_rejects_the_row_in_the_scan() raises:
    var path = _write("null_filter", 0, 100, 40)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    # b > 700 is r > 70, and b is NULL where r % 5 == 2.
    var spec = SourceSpecPod.parquet(path^, None, Optional(_cmp(BIN_GT, "b", 700)), True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    var want = List[Int]()
    for r in range(71, 100):
        if not b_is_null(r):
            want.append(r)
    _expect(_column(_drain(src), 0), want)


def test_a_filter_on_a_column_the_projection_leaves_out_still_filters() raises:
    var path = _write("filter_other_column", 0, 60, 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(
        path^, Optional(_names("s")), Optional(_cmp(BIN_GE, "a", 50)), True
    )
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, NW, cache, pool
    )
    var morsels = _drain(src)
    var total = 0
    var order = _in_position_order(morsels)
    for k in range(len(order)):
        ref batch = morsels[order[k]].batch
        assert_equal(batch.num_columns(), 1)
        for i in range(batch.num_rows()):
            if batch.has_selection_mask() and not batch.selection_mask_get(i):
                continue
            total += 1
    assert_equal(total, 10)


def test_a_morsel_size_cuts_a_row_group_without_losing_a_row() raises:
    var path = _write("cut", 0, 90, 45)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(path^, Optional(_names("a")), None, True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 16, NW, cache, pool
    )
    var morsels = _drain(src)
    assert_true(len(morsels) > 2)
    for k in range(len(morsels)):
        assert_true(morsels[k].num_rows() <= 16)
    _expect(_column(morsels, 0), _range(0, 90))


def test_a_worker_the_source_was_not_built_for_is_refused() raises:
    var path = _write("workers", 0, 10, 10)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var spec = SourceSpecPod.parquet(path^, None, None, True)
    var src = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](
        spec, 0, 2, cache, pool
    )
    with assert_raises(contains="is not in [0, 2)"):
        _ = src.next_morsel(2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
