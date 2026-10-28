# =============================================================================
# BatchMorselOptions -- the source's dark switches are arguments
# =============================================================================
#
# `BatchMorselSource` once read the steal switch from the process environment.
# It is `BatchMorselOptions.steal` now. The claim policy is observable through
# `steal_fire_count()`:
#
#   * default options: the per-worker range walk. No steal can fire, so the
#     count stays 0 however the pulls interleave.
#   * `steal=True`: the two-level claim. With the fixed 32-morsel reserve (the
#     test-only oracle switch), worker 0 reserves morsels [0, 32) and consumes
#     one; worker 1 then reserves [32, 40), drains it, finds the shared cursor
#     exhausted and STEALS from worker 0's reserve. That is deterministic
#     without threads.
#
# Both arms must deliver every morsel exactly once.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)

from komira_op_sources.batch_morsel_source import (
    BatchMorselOptions,
    BatchMorselSource,
)


def _range_batch(n: Int) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Int64(i)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(sb.build())


def _pull_rows(src: BatchMorselSource, wid: Int, limit: Int) raises -> Int:
    """Pull up to `limit` morsels as worker `wid`; return the rows seen."""
    var rows = 0
    for _ in range(limit):
        var m = src.next_morsel(wid)
        if not m:
            break
        rows += m.value().num_rows()
    return rows


def test_default_options_never_steal() raises:
    var src = BatchMorselSource(_range_batch(40), morsel_rows=1)
    src.set_sched_c3_enabled_for_test(False)
    var rows = _pull_rows(src, 0, 1)
    rows += _pull_rows(src, 1, 100)
    rows += _pull_rows(src, 0, 100)
    if rows != 40:
        raise "default: expected 40 rows, got " + String(rows)
    if src.steal_fire_count() != 0:
        raise "default: a steal fired with the switch off"
    print("test_default_options_never_steal OK")


def test_steal_option_steals() raises:
    var src = BatchMorselSource(
        _range_batch(40), morsel_rows=1, options=BatchMorselOptions(steal=True)
    )
    src.set_sched_c3_enabled_for_test(False)
    var rows = _pull_rows(src, 0, 1)
    rows += _pull_rows(src, 1, 100)
    rows += _pull_rows(src, 0, 100)
    if rows != 40:
        raise "steal: expected 40 rows exactly once, got " + String(rows)
    if src.steal_fire_count() <= 0:
        raise "steal: the option was set but no steal fired"
    print("test_steal_option_steals OK")


def main() raises:
    test_default_options_never_steal()
    test_steal_option_steals()
    print("All BatchMorselOptions tests PASS")
