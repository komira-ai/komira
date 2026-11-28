# =============================================================================
# source_generate_series -- SOURCE_GENERATE_SERIES, the rows of generate_series
# =============================================================================
#
# `GenerateSeriesSource` serves the one column a `SeriesSpec` describes, a
# morsel at a time, and reads no input. Workers claim morsel indices from one
# shared atomic cursor; claim `c` computes the rows `c * morsel_rows ..` of the
# series with `series_values`, which costs O(morsel_rows) whatever `c` is, so a
# series of 2^62 rows is never held and a LIMIT above it ends the run after
# the morsels it needs. The morsel's partition id is its claim index, so a
# collect sink keeps the series' order under any number of workers.
#
# A series of no row (a NULL bound, a step pointing away from the bound) is one
# empty batch at the spec's schema, delivered by claim 0, so the collect sink's
# empty output carries the column; every other claim past the end is None.
# The batch schema is `SeriesSpec.schema()`: INT64, or TIMESTAMP in
# microseconds, never NULL.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import RecordBatchBuilder, Schema
from atomic_alias import AtomicI64
from column_kernels.compiler_helpers import empty_batch_like_schema
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from physical_plan.physical_plan import SourceSpecPod
from plan_stats.source_statistics import SourceStatistics
from scan_source.series_scan import SeriesSpec, series_values

comptime _MAX_PARTITION_HINT: Int = 1 << 30


struct _State:
    """The shared claim cursor and the morsel id stamp; atomic fields, so it
    lives once in a slab and is mutated through a borrowed `self`."""

    var cursor: AtomicI64
    var morsel_counter: AtomicI64


struct GenerateSeriesSource(MorselSourceImpl):
    """The morsels of one generated series, computed as they are claimed."""

    var _spec: SeriesSpec
    var _morsel_rows: Int
    var _state: Slab[_State]

    def __init__(out self, var spec: SeriesSpec, morsel_rows: Int) raises:
        if morsel_rows <= 0:
            raise Error(
                "pipeline_exec: a generate_series source needs a positive"
                " morsel size, not " + String(morsel_rows)
            )
        spec.check()
        self._spec = spec^
        self._morsel_rows = morsel_rows
        self._state = Slab[_State].create_prefilled(1)
        self._state.get_mut_interior(0).cursor = AtomicI64(0)
        self._state.get_mut_interior(0).morsel_counter = AtomicI64(0)

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        var c = Int(self._state.get_mut_interior(0).cursor.fetch_add(Int64(1)))
        var values = series_values(
            self._spec, UInt64(c) * UInt64(self._morsel_rows), self._morsel_rows
        )
        if len(values) == 0:
            if c != 0:
                return None
            var mid = Int(
                self._state.get_mut_interior(0).morsel_counter.fetch_add(
                    Int64(1)
                )
            )
            return Morsel(
                empty_batch_like_schema(self._spec.schema()), mid, c, 0
            )
        var arr = PrimitiveArray[DType.int64].from_list(values)
        var builder = RecordBatchBuilder()
        if self._spec.timestamp:
            builder.add_column(
                Column.from_primitive_with_arrow_type[DType.int64](
                    arr, ArrowType.TIMESTAMP_US
                )
            )
        else:
            builder.add_column(Column.from_primitive[DType.int64](arr))
        var mid = Int(
            self._state.get_mut_interior(0).morsel_counter.fetch_add(Int64(1))
        )
        return Morsel(builder.build(self._spec.schema()), mid, c, 0)

    def output_schema(self) -> Schema:
        return self._spec.schema()

    def partition_hint(self) -> Int:
        """The morsels of the series, at least one; a month step, whose count
        is not computed ahead, hints one."""
        var n = self._spec.row_count()
        if not n:
            return 1
        var rows = UInt64(self._morsel_rows)
        var morsels = n.value() // rows
        if n.value() % rows != 0:
            morsels += 1
        if morsels < 1:
            return 1
        if morsels > UInt64(_MAX_PARTITION_HINT):
            return _MAX_PARTITION_HINT
        return Int(morsels)

    def row_count_hint(self) -> Int:
        """The rows of the series, saturating at the largest Int; a month
        step hints one morsel's rows."""
        var n = self._spec.row_count()
        if not n:
            return self._morsel_rows
        if n.value() > UInt64(Int.MAX):
            return Int.MAX
        return Int(n.value())

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities(
            supports_projection=False,
            supports_decode_filter=False,
            supports_dict_preservation=False,
            supports_dynamic_filter=False,
            supports_row_group_pruning=False,
            supports_bypass_columns=False,
            supports_as_source=False,
        )

    def statistics(self) -> SourceStatistics:
        return SourceStatistics()


def build_generate_series_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> GenerateSeriesSource:
    """The morsels of the series `spec` names."""
    return GenerateSeriesSource(spec.series_spec.copy(), morsel_rows)
