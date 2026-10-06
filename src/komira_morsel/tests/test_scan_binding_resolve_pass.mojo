"""The execution-time open-kind scan resolve pass
(`komira_morsel/scan_binding_resolve_pass.mojo`).

PLAN-LEVEL ONLY and EXECUTOR-FREE: a stub kind, hand-built plans, a real
`ScanRegistry`; nothing is executed. What it pins:
  * an open-kind leaf is re-rooted as a BOUND in-memory scan over the kind's
    payload, and the side channel is reported;
  * the cached plan's LIVE token stays 0, and two executions resolve two tokens;
  * a join with two open leaves AND a subquery's open leaf are all found;
  * an unregistered kind raises `SCAN_KIND_NOT_EXECUTABLE`, naming it and every
    registered kind; legacy binding arms and in-memory leaves are untouched;
  * the scan's WHOLE filter is KEPT, as a `PLAN_FILTER` node above an
    in-memory scan that carries none (so an aggregate over the leaf never sits
    on a filtered scan); only gate-accepted conjuncts reach the kind, and the
    projection names what the leaf needs;
  * a payload missing a needed column is refused; an empty drain is an empty
    relation;
  * EVERY `PLAN_*` and `EXPR_*` tag has an arm, and one past the last raises;
  * the pass is an ACQUIRE: a scope opened BEFORE it releases every slot it
    minted, on the success path and on the unwind path (asserted on
    `resident_payload_rows()`, with a no-scope CONTROL that must stay resident);
  * a leaf with no projection is the DECLARED relation whatever superset or
    column order the kind returns;
  * every payload guard fires by name — a later batch that renames, reorders,
    retypes or re-widens a column set, one that drifts only in a column the
    plan does not read, a retyped column only the filter reads, an
    output-shape change, and a drifted type PARAMETER (decimal scale, zone)
    in each of the three checks, and every nested-type arm of the one
    comparator (a list item's type, a union's type ids renumbered, fewer AND
    more, a struct child's name, a child count fewer AND more) — and each
    fires BEFORE the bind, so a refused leaf mints nothing; the controls (a
    decimal, a dictionary with INT8 indices) keep their parameters through
    the widest re-root;
  * a raise after the resolve leaves the plan's OWN leaf and token untouched
    (the falsifiable form of "the cached token stays 0");
  * every child and every Expr slot is DESCENDED, not merely dispatched: an
    open leaf under each one is found and re-rooted in place, and each table
    cross-checks that it covers every child-bearing tag.
"""

from std.memory import ArcPointer, OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.slab import Slab
from komira_core.plan.corr_subquery import corr_data_inner_plan_ref
from komira_core.plan.agg_expr import AggExpr, AGG_SUM
from komira_core.plan.expr import (
    Expr,
    WhenCaseData,
    BIN_AND,
    EXPR_BETWEEN,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_SORT_KEY,
    EXPR_TAG_COUNT,
    EXPR_WINDOW_FN,
    EXTRACT_YEAR,
    MATH2_ATAN2,
    MATH_SIN,
    REGEXP_LIKE,
    STRFNN_CONCAT,
    STRFN_UPPER,
    STR_CONTAINS,
    UN_NOT,
    expr_tag_name,
)
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ASOF_BACKWARD,
    AsofTolerance,
    CORR_KIND_EXISTS,
    JOIN_INNER,
    PLAN_CSE_REF,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_TAG_COUNT,
    PLAN_VIEW_REF,
    plan_tag_name,
)
from komira_core.plan.partition_expr import PartitionExpr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.source.in_memory_source import InMemorySource
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SNAPSHOT_LIVE,
    scan_kind_id,
)
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_registry import ScanRegistry
from komira_core.source.source_variant import (
    LEGACY_SOURCE_TYPE_CSV,
    SOURCE_VARIANT_BINDING,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_IN_MEMORY,
    SourceVariant,
)
from komira_morsel.scan_binding_resolve_pass import (
    ResolvedScanSnapshot,
    SCAN_OPENED_SCHEMA_MISMATCH,
    SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG,
    SCAN_RESOLVE_PASS_UNMODELLED_TAG,
    resolve_expr_binding_leaves,
    resolve_plan_binding_leaves,
)
from komira_morsel.scan_morsel_resolver import (
    ErasedScanMorselResolver,
    ScanMorselResolver,
    ScanMorselResolvers,
    ScanOpened,
    ScanRequest,
    SCAN_KIND_NOT_EXECUTABLE,
)


comptime _KIND_A: String = "komira.test.topic_a"
comptime _KIND_B: String = "komira.test.topic_b"

comptime _MODE_FULL: Int = 0
"""Return columns (a, b): 3 rows + 2 rows."""
comptime _MODE_ONLY_A: Int = 1
"""Return column a only, whatever the request says."""
comptime _MODE_EMPTY: Int = 2
"""Return zero batches."""
comptime _MODE_SUPERSET_REORDERED: Int = 3
"""Return columns (c, b, a): a SUPERSET of the binding's (a, b), in another
order — what `ScanRequest`'s doc permits. 3 rows + 2 rows."""
comptime _MODE_B_F64: Int = 4
"""Return (a int64, b FLOAT64) in every batch: `b` retyped against the binding."""
comptime _MODE_B1_RETYPED: Int = 5
"""Batch 0 is (a, b) int64; batch 1 retypes `b` to float64."""
comptime _MODE_B1_RENAMED: Int = 6
"""Batch 0 is (a, b); batch 1 is (a, c) — same column COUNT."""
comptime _MODE_B1_REORDERED: Int = 7
"""Batch 0 is (a, b); batch 1 is (b, a) — same names, same types."""
comptime _MODE_B1_WIDER: Int = 8
"""Batch 0 is (a, b); batch 1 is (a, b, c) — one column WIDER."""
comptime _MODE_B1_NARROWER: Int = 9
"""Batch 0 is (a, b); batch 1 is (a) — one column NARROWER."""
comptime _MODE_DEC: Int = 10
"""The binding declares (a int64, d DECIMAL128(18,2)); every batch is exactly
that. The control for the parametric modes below."""
comptime _MODE_DEC_SCALE: Int = 11
"""The binding declares d DECIMAL128(18,2); every batch carries d as
DECIMAL128(18,4) — the same `ArrowType` tag, every value off by 100x."""
comptime _MODE_B1_DEC_SCALE: Int = 12
"""The binding declares d DECIMAL128(18,2); batch 0 carries (18,2), batch 1
carries (18,4) — the same tag, read under batch 0's scale."""
comptime _MODE_B1_TZ: Int = 13
"""The binding declares t TIMESTAMP_US zoned 'UTC'; batch 0 carries that, batch
1 carries t NAIVE — the same tag, another meaning of every instant."""
comptime _MODE_DICT8: Int = 14
"""The binding declares (a int64, k DICTIONARY with INT8 indices); every batch
is exactly that."""
comptime _MODE_B1_DICT16: Int = 15
"""As `_MODE_DICT8`, but batch 1 carries k with INT16 indices — the same tag."""
comptime _MODE_B1_LIST_ITEM: Int = 16
"""The binding declares l LIST<INT64>; batch 0 carries that, batch 1 carries l
as LIST<STRING> — the same tag, child buffers read as the wrong type."""
comptime _MODE_B1_UNION_IDS: Int = 17
"""The binding declares u UNION_SPARSE with type ids [0, 1]; batch 0 carries
that, batch 1 carries u with ids [0, 2] — the same tag, and a type-id byte of 1
names no child of batch 1's union."""
comptime _MODE_B1_STRUCT_RENAMED: Int = 18
"""The binding declares s STRUCT{x int64, y int64}; batch 0 carries that, batch
1 carries s as STRUCT{z, y} — the same tag, child types and count; a struct
field is read by NAME."""
comptime _MODE_B1_STRUCT_FEWER: Int = 19
"""As `_MODE_B1_STRUCT_RENAMED`'s binding, but batch 1 carries s as STRUCT{x}
— one child FEWER."""
comptime _MODE_B1_STRUCT_MORE: Int = 20
"""As `_MODE_B1_STRUCT_RENAMED`'s binding, but batch 1 carries s as
STRUCT{x, y, w} — one child MORE."""
comptime _MODE_B1_UNION_FEWER: Int = 21
"""As `_MODE_B1_UNION_IDS`'s binding and batch 0, but batch 1 carries u with
type ids [0] — one id FEWER, and the one it keeps equals batch 0's first."""
comptime _MODE_B1_UNION_MORE: Int = 22
"""As `_MODE_B1_UNION_IDS`'s binding and batch 0, but batch 1 carries u with
type ids [0, 1, 2] — one id MORE, and the two it shares equal batch 0's."""


struct _Tally(Movable):
    var resolves: Int
    var opens: Int
    var last_predicate: String
    var last_projection: String

    def __init__(out self):
        self.resolves = 0
        self.opens = 0
        self.last_predicate = String("")
        self.last_projection = String("")


def _schema_ab() -> Schema:
    return Schema.from_fields_2(
        Field("a", DType.int64, True), Field("b", DType.int64, True)
    )


def _col(n: Int, base: Int) raises -> Column[]:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(base + i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    return Column.from_primitive[DType.int64](arr^)


def _batch_ab(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_2(_schema_ab(), _col(n, 0), _col(n, 10))


def _i64(name: String) -> Field:
    return Field(name, DType.int64, True)


def _col_f64(n: Int) raises -> Column[]:
    var vals = List[Scalar[DType.float64]]()
    for i in range(n):
        vals.append(Scalar[DType.float64](Float64(i) + 0.5))
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    return Column.from_primitive[DType.float64](arr^)


def _batch_cba(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_3(
        Schema.from_fields_3(_i64("c"), _i64("b"), _i64("a")),
        _col(n, 20),
        _col(n, 10),
        _col(n, 0),
    )


def _batch_a_bf64(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(_i64("a"), Field("b", DType.float64, True)),
        _col(n, 0),
        _col_f64(n),
    )


def _batch_ac(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(_i64("a"), _i64("c")), _col(n, 0), _col(n, 10)
    )


def _batch_ba(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(_i64("b"), _i64("a")), _col(n, 10), _col(n, 0)
    )


def _batch_abc(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_3(
        Schema.from_fields_3(_i64("a"), _i64("b"), _i64("c")),
        _col(n, 0),
        _col(n, 10),
        _col(n, 20),
    )


def _schema_ad(scale: Int) raises -> Schema:
    """(a int64, d DECIMAL128(18, `scale`))."""
    return Schema.from_fields_2(
        _i64("a"), Field.decimal128(String("d"), 18, scale, True)
    )


def _batch_ad(n: Int, scale: Int) raises -> RecordBatch:
    var vals = List[SIMD[DType.int128, 1]]()
    for i in range(n):
        vals.append(SIMD[DType.int128, 1](Int(i) * 100 + 25))
    var dec = Column.from_decimal128(
        Decimal128Array.from_i128_list(vals, 18, scale)
    )
    return RecordBatch.from_typed_columns_2(
        _schema_ad(scale), _col(n, 0), dec^
    )


def _schema_at(tz: String) raises -> Schema:
    """(a int64, t TIMESTAMP_US zoned `tz`; "" is naive)."""
    return Schema.from_fields_2(
        _i64("a"),
        Field.timestamp(String("t"), ArrowType.TIMESTAMP_US, tz, True),
    )


def _batch_at(n: Int, tz: String) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(1_000_000 * i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var ts = Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_US
    )
    return RecordBatch.from_typed_columns_2(_schema_at(tz), _col(n, 0), ts^)


def _schema_ak(index: ArrowType = ArrowType.INT8) raises -> Schema:
    """(a int64, k DICTIONARY with `index` indices)."""
    return Schema.from_fields_2(
        _i64("a"), Field.dictionary(String("k"), index, True)
    )


def _schema_al(item: ArrowType) -> Schema:
    """(a int64, l LIST<`item`>)."""
    return Schema.from_fields_2(
        _i64("a"), Field.list_of(String("l"), item, True)
    )


def _batch_al(n: Int, item: ArrowType) raises -> RecordBatch:
    # PLAN-LEVEL: the pass never reads a value, so `l` carries a stand-in
    # int64 buffer, not list offsets. The SCHEMA is what is under test.
    return RecordBatch.from_typed_columns_2(
        _schema_al(item), _col(n, 0), _col(n, 10)
    )


def _batch_ak16(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int16]]()
    for i in range(n):
        vals.append(Scalar[DType.int16](Int16(i % 2)))
    var arr = PrimitiveArray[DType.int16].from_list(vals^)
    var k = Column.from_primitive_with_arrow_type[DType.int16](
        arr, ArrowType.DICTIONARY
    )
    return RecordBatch.from_typed_columns_2(
        _schema_ak(ArrowType.INT16), _col(n, 0), k^
    )


def _batch_ak(n: Int) raises -> RecordBatch:
    # PLAN-LEVEL: the pass never reads a value, so `k` carries its INT8 index
    # buffer only (no dictionary values). The SCHEMA is what is under test.
    var vals = List[Scalar[DType.int8]]()
    for i in range(n):
        vals.append(Scalar[DType.int8](Int8(i % 2)))
    var arr = PrimitiveArray[DType.int8].from_list(vals^)
    var k = Column.from_primitive_with_arrow_type[DType.int8](
        arr, ArrowType.DICTIONARY
    )
    return RecordBatch.from_typed_columns_2(_schema_ak(), _col(n, 0), k^)


def _ids(*ids: Int) -> List[Int]:
    """A union type-id list, in order."""
    var out = List[Int]()
    for i in ids:
        out.append(i)
    return out^


def _schema_au(ids: List[Int]) raises -> Schema:
    """(a int64, u UNION_SPARSE with type ids `ids` and NO child fields —
    `Field.union` adds none, so a union's child count never refuses it and
    its type-id list is the only thing the comparator can see)."""
    return Schema.from_fields_2(
        _i64("a"),
        Field.union(String("u"), ArrowType.UNION_SPARSE, ids, True),
    )


def _batch_au(n: Int, ids: List[Int]) raises -> RecordBatch:
    # PLAN-LEVEL: the pass never reads a value, so `u` carries a stand-in
    # int64 buffer, not a union's type-id buffer. The SCHEMA is under test.
    return RecordBatch.from_typed_columns_2(
        _schema_au(ids), _col(n, 0), _col(n, 10)
    )


def _schema_as(children: List[String]) -> Schema:
    """(a int64, s STRUCT whose int64 children are `children`, in order)."""
    var s = Field(String("s"), ArrowType.STRUCT, True)
    for i in range(len(children)):
        s.add_child(children[i], ArrowType.INT64, True)
    return Schema.from_fields_2(_i64("a"), s)


def _batch_as(n: Int, children: List[String]) raises -> RecordBatch:
    # PLAN-LEVEL: `s` carries a stand-in int64 buffer, not struct children.
    return RecordBatch.from_typed_columns_2(
        _schema_as(children), _col(n, 0), _col(n, 10)
    )


def _binding_schema(mode: Int) raises -> Schema:
    """What the stub kind's binding DECLARES in `mode`: (a, b) int64, except
    the parametric modes, which declare the (18,2) decimal or the UTC
    timestamp their batches drift from."""
    if mode == _MODE_DEC or mode == _MODE_DEC_SCALE or mode == _MODE_B1_DEC_SCALE:
        return _schema_ad(2)
    if mode == _MODE_B1_TZ:
        return _schema_at(String("UTC"))
    if mode == _MODE_DICT8 or mode == _MODE_B1_DICT16:
        return _schema_ak()
    if mode == _MODE_B1_LIST_ITEM:
        return _schema_al(ArrowType.INT64)
    if (
        mode == _MODE_B1_UNION_IDS
        or mode == _MODE_B1_UNION_FEWER
        or mode == _MODE_B1_UNION_MORE
    ):
        return _schema_au(_ids(0, 1))
    if (
        mode == _MODE_B1_STRUCT_RENAMED
        or mode == _MODE_B1_STRUCT_FEWER
        or mode == _MODE_B1_STRUCT_MORE
    ):
        return _schema_as(_names("x", "y"))
    return _schema_ab()


def _batch_a(n: Int) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_1(
        Schema.from_fields_1(Field("a", DType.int64, True)), _col(n, 0)
    )


struct _StubTopic(ScanMorselResolver, Movable, Deinitable):
    """A LIVE kind: the token advances on every resolve, and `open_scan`
    records what it was asked for and reports the token it was handed."""

    var _tally: ArcPointer[_Tally]
    var _kind_name: String
    var _gate_accepts_comparisons: Bool
    var _mode: Int

    def __init__(
        out self,
        tally: ArcPointer[_Tally],
        var kind_name: String,
        gate_accepts_comparisons: Bool = False,
        mode: Int = _MODE_FULL,
    ):
        self._tally = tally.copy()
        self._kind_name = kind_name^
        self._gate_accepts_comparisons = gate_accepts_comparisons
        self._mode = mode

    def _gate(self) -> PushdownGate:
        if self._gate_accepts_comparisons:
            return PushdownGate.conjunctive_comparison(
                require_stat_friendly_col=False
            )
        return PushdownGate.reject_all()

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        self._tally[].resolves += 1
        return UInt64(100 + self._tally[].resolves)

    def descriptor(self) -> ScanKindDescriptor:
        return ScanKindDescriptor(
            kind_name=String(self._kind_name),
            gate=self._gate(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        var fp = params.hash_into(UInt64(scan_kind_id(self._kind_name)))
        return ScanBinding(
            kind_id=scan_kind_id(self._kind_name),
            kind_name=String(self._kind_name),
            name=params.get_str(String("topic")),
            params=params.copy(),
            schema=_binding_schema(self._mode),
            fingerprint=fp,
            structural_id=fp,
            gate=self._gate(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        self._tally[].opens += 1
        if req.predicate:
            self._tally[].last_predicate = String(req.predicate.value())
        else:
            self._tally[].last_predicate = String("<none>")
        if req.projection:
            var s = String("")
            for i in range(len(req.projection.value())):
                if i > 0:
                    s += String(",")
                s += req.projection.value()[i]
            self._tally[].last_projection = s^
        else:
            self._tally[].last_projection = String("<none>")
        var batches = Slab[RecordBatch]()
        if self._mode == _MODE_FULL:
            batches.append(_batch_ab(3))
            batches.append(_batch_ab(2))
        elif self._mode == _MODE_ONLY_A:
            batches.append(_batch_a(3))
        elif self._mode == _MODE_SUPERSET_REORDERED:
            batches.append(_batch_cba(3))
            batches.append(_batch_cba(2))
        elif self._mode == _MODE_B_F64:
            batches.append(_batch_a_bf64(3))
            batches.append(_batch_a_bf64(2))
        elif self._mode == _MODE_B1_RETYPED:
            batches.append(_batch_ab(3))
            batches.append(_batch_a_bf64(2))
        elif self._mode == _MODE_B1_RENAMED:
            batches.append(_batch_ab(3))
            batches.append(_batch_ac(2))
        elif self._mode == _MODE_B1_REORDERED:
            batches.append(_batch_ab(3))
            batches.append(_batch_ba(2))
        elif self._mode == _MODE_B1_WIDER:
            batches.append(_batch_ab(3))
            batches.append(_batch_abc(2))
        elif self._mode == _MODE_B1_NARROWER:
            batches.append(_batch_ab(3))
            batches.append(_batch_a(2))
        elif self._mode == _MODE_DEC:
            batches.append(_batch_ad(3, 2))
            batches.append(_batch_ad(2, 2))
        elif self._mode == _MODE_DEC_SCALE:
            batches.append(_batch_ad(3, 4))
            batches.append(_batch_ad(2, 4))
        elif self._mode == _MODE_B1_DEC_SCALE:
            batches.append(_batch_ad(3, 2))
            batches.append(_batch_ad(2, 4))
        elif self._mode == _MODE_B1_TZ:
            batches.append(_batch_at(3, String("UTC")))
            batches.append(_batch_at(2, String("")))
        elif self._mode == _MODE_DICT8:
            batches.append(_batch_ak(3))
            batches.append(_batch_ak(2))
        elif self._mode == _MODE_B1_DICT16:
            batches.append(_batch_ak(3))
            batches.append(_batch_ak16(2))
        elif self._mode == _MODE_B1_LIST_ITEM:
            batches.append(_batch_al(3, ArrowType.INT64))
            batches.append(_batch_al(2, ArrowType.STRING))
        elif self._mode == _MODE_B1_UNION_IDS:
            batches.append(_batch_au(3, _ids(0, 1)))
            batches.append(_batch_au(2, _ids(0, 2)))
        elif self._mode == _MODE_B1_UNION_FEWER:
            batches.append(_batch_au(3, _ids(0, 1)))
            batches.append(_batch_au(2, _ids(0)))
        elif self._mode == _MODE_B1_UNION_MORE:
            batches.append(_batch_au(3, _ids(0, 1)))
            batches.append(_batch_au(2, _ids(0, 1, 2)))
        elif self._mode == _MODE_B1_STRUCT_RENAMED:
            batches.append(_batch_as(3, _names("x", "y")))
            batches.append(_batch_as(2, _names("z", "y")))
        elif self._mode == _MODE_B1_STRUCT_FEWER:
            batches.append(_batch_as(3, _names("x", "y")))
            batches.append(_batch_as(2, _names("x")))
        elif self._mode == _MODE_B1_STRUCT_MORE:
            batches.append(_batch_as(3, _names("x", "y")))
            batches.append(_batch_as(2, _names("x", "y", "w")))
        var resolved = ScanParams()
        resolved.put_u64(String("high_watermark"), req.binding.snapshot_token)
        return ScanOpened(ArcPointer(batches^), resolved^)


def _set_of(var r: _StubTopic) raises -> ScanMorselResolvers:
    var set = ScanMorselResolvers()
    set.register(ErasedScanMorselResolver.erase(r^))
    return set^


def _leaf_of(
    r: ErasedScanMorselResolver,
    topic: String,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    var p = ScanParams()
    p.put_str(String("topic"), String(topic))
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(r.build_binding(p)),
        _schema_ab(),
        projection^,
        filter^,
    )


def _leaf(set: ScanMorselResolvers, topic: String) raises -> LogicalPlan:
    return _leaf_of(set.get(scan_kind_id(String(_KIND_A))), topic)


def _is_bound_inmem(plan: LogicalPlan, registry: ScanRegistry) -> Bool:
    if plan.tag != PLAN_SCAN or not plan._scan:
        return False
    ref src = plan._scan.value()[].source
    if src.tag != SOURCE_VARIANT_IN_MEMORY or not src.has_carrier_binding():
        return False
    ref b = src.carrier_binding_ref()
    return b.registry_epoch == registry.epoch() and registry.is_bound(
        b.kind_id, b.handle
    )


def test_an_open_leaf_is_rerooted_as_a_bound_inmem_scan() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var plan = _leaf(set, String("orders"))
    assert_equal(plan._scan.value()[].source.tag, SOURCE_VARIANT_BINDING)
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var n = resolve_plan_binding_leaves(plan, set, registry, snaps)
    assert_equal(n, 1)
    assert_true(_is_bound_inmem(plan, registry), "a BOUND in-memory leaf")
    assert_equal(registry.resident_payload_rows(), 5, "the kind's 3 + 2 rows")
    assert_equal(plan.output_schema.num_columns(), 2)
    assert_equal(plan.output_schema.field_name(0), String("a"))
    assert_equal(len(snaps), 1)
    assert_equal(snaps[0].kind_name, String(_KIND_A))
    assert_equal(snaps[0].name, String("orders"))
    assert_equal(snaps[0].snapshot_policy, SNAPSHOT_LIVE)
    assert_equal(snaps[0].snapshot_token, UInt64(101))
    assert_equal(snaps[0].rows, 5)
    assert_equal(
        snaps[0].resolved.get_u64(String("high_watermark")),
        UInt64(101),
        "the side channel carries what the kind resolved",
    )
    assert_equal(tally[].last_predicate, String("<none>"))
    assert_equal(tally[].last_projection, String("<none>"))


def test_the_cached_token_stays_zero_and_each_execution_resolves_its_own() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var cached = _leaf(set, String("orders"))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var exec1 = cached.copy()
    _ = resolve_plan_binding_leaves(exec1, set, registry, snaps)
    var exec2 = cached.copy()
    _ = resolve_plan_binding_leaves(exec2, set, registry, snaps)
    assert_equal(len(snaps), 2)
    assert_equal(snaps[0].snapshot_token, UInt64(101))
    assert_equal(snaps[1].snapshot_token, UInt64(102), "a fresh token per run")
    # ⚠ NOT THE FALSIFIER for "no write-back": `copy()` is deep, so `cached`
    # never entered the pass. That is
    # `test_a_raise_after_the_resolve_leaves_the_plans_own_leaf_and_token`.
    ref src = cached._scan.value()[].source
    assert_equal(src.tag, SOURCE_VARIANT_BINDING, "the cached plan keeps its leaf")
    assert_equal(
        src.binding_ref().snapshot_token,
        UInt64(0),
        "a LIVE token is never written back into the cached plan",
    )
    assert_equal(tally[].resolves, 2)
    assert_equal(tally[].opens, 2)


def test_a_join_of_two_open_leaves_and_a_subquery_leaf_are_all_resolved() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var refs = List[String]()
    refs.append(String("a"))
    var exists = Expr.correlated_subquery(
        _leaf(set, String("returns")), refs^, CORR_KIND_EXISTS
    )
    var right = LogicalPlan.filter(exists^, _leaf(set, String("items")))
    var lk = List[String]()
    lk.append(String("a"))
    var rk = List[String]()
    rk.append(String("a"))
    var plan = LogicalPlan.join(
        _leaf(set, String("orders")), right^, lk^, rk^, JOIN_INNER
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var n = resolve_plan_binding_leaves(plan, set, registry, snaps)
    assert_equal(n, 3, "both join sides AND the subquery's leaf")
    assert_equal(len(snaps), 3)
    assert_equal(snaps[0].name, String("orders"))
    assert_equal(snaps[1].name, String("returns"), "the predicate before the child")
    assert_equal(snaps[2].name, String("items"))
    assert_equal(registry.resident_payload_rows(), 15)
    ref j = plan._join.value()[]
    assert_true(_is_bound_inmem(j.left[], registry), "the left leaf")
    assert_equal(j.right[].tag, PLAN_FILTER)
    ref f = j.right[]._filter.value()[]
    assert_true(_is_bound_inmem(f.child[], registry), "the right leaf")
    ref cs = f.predicate._corr_subq.value()[]
    assert_true(
        _is_bound_inmem(corr_data_inner_plan_ref(cs), registry),
        "the subquery's leaf",
    )


def test_an_unregistered_kind_raises_naming_it_and_the_registered_kinds() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var b = ErasedScanMorselResolver.erase(_StubTopic(tally, String(_KIND_B)))
    var plan = _leaf_of(b, String("clicks"))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_KIND_NOT_EXECUTABLE) in msg, msg)
        assert_true(String(_KIND_B) in msg, "names the kind: " + msg)
        assert_true(String(_KIND_A) in msg, "names what IS registered: " + msg)
    assert_true(raised, "an open leaf with no resolver must not be skipped")
    assert_equal(tally[].opens, 0)
    var empty = ScanMorselResolvers()
    var plan2 = _leaf_of(b, String("clicks"))
    var raised2 = False
    try:
        _ = resolve_plan_binding_leaves(plan2, empty, registry, snaps)
    except e:
        raised2 = True
        assert_true("none registered" in String(e), String(e))
    assert_true(raised2)


def test_legacy_binding_arms_and_inmem_leaves_are_untouched() raises:
    var csv_binding = ScanBinding(
        kind_id=scan_kind_id(String("komira.csv")),
        kind_name=String("komira.csv"),
        name=String("/data/x.csv"),
        params=ScanParams(),
        schema=_schema_ab(),
        fingerprint=UInt64(7),
        structural_id=UInt64(7),
        gate=PushdownGate.reject_all(),
        legacy_source_type=LEGACY_SOURCE_TYPE_CSV,
    )
    var csv_leaf = LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_CSV, binding=csv_binding^),
        _schema_ab(),
    )
    var inmem_leaf = LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(_batch_ab(4))),
        _schema_ab(),
    )
    var lk = List[String]()
    lk.append(String("a"))
    var rk = List[String]()
    rk.append(String("a"))
    var plan = LogicalPlan.join(csv_leaf^, inmem_leaf^, lk^, rk^, JOIN_INNER)
    var empty = ScanMorselResolvers()
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    # With NO resolver registered: touching either leaf would raise.
    var n = resolve_plan_binding_leaves(plan, empty, registry, snaps)
    assert_equal(n, 0)
    assert_equal(len(snaps), 0)
    ref j = plan._join.value()[]
    assert_equal(j.left[]._scan.value()[].source.tag, SOURCE_VARIANT_CSV)
    assert_equal(j.right[]._scan.value()[].source.tag, SOURCE_VARIANT_IN_MEMORY)
    assert_false(
        j.right[]._scan.value()[].source.has_carrier_binding(),
        "this pass does not bind plain in-memory leaves; the bind pass does",
    )


def _filter_a_gt_5_and_a_gt_b() -> Expr:
    var lhs = Expr.col_ref(String("a")) > Expr.literal(ScalarValue.from_int64(Int64(5)))
    var rhs = Expr.col_ref(String("a")) > Expr.col_ref(String("b"))
    return lhs & rhs


def test_the_kept_filter_is_a_filter_node_above_an_unfiltered_scan() raises:
    """The WHOLE filter is kept, and kept as a `PLAN_FILTER` node, never as the
    re-rooted scan's own `filter`: an in-memory scan carrying a filter is a
    shape the optimizer never builds, and
    `subquery_executor._try_collect_scalar_inner_source` reads such a scan's
    batch without it — a scalar-subquery fold over a coarse-pruning kind would
    fold the UNFILTERED rows. Only the conjunct the gate accepts reaches the
    kind, and the scan projects what the filter reads, then a Project drops
    it again."""
    var tally = ArcPointer(_Tally())
    var set = _set_of(
        _StubTopic(tally, String(_KIND_A), gate_accepts_comparisons=True)
    )
    var proj = List[String]()
    proj.append(String("a"))
    var plan = _leaf_of(
        set.get(scan_kind_id(String(_KIND_A))),
        String("orders"),
        Optional(proj^),
        Optional(_filter_a_gt_5_and_a_gt_b()),
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    var only_lhs = Expr.col_ref(String("a")) > Expr.literal(
        ScalarValue.from_int64(Int64(5))
    )
    assert_equal(
        tally[].last_predicate,
        String(only_lhs),
        "only the conjunct the gate accepts reaches the kind",
    )
    assert_equal(
        tally[].last_projection,
        String("a,b"),
        "the projection plus the filter's columns, in schema order",
    )
    assert_equal(plan.output_schema.num_columns(), 1, "projection kept")
    assert_equal(plan.output_schema.field_name(0), String("a"))
    assert_equal(
        plan.tag, PLAN_PROJECT, "a Project back to the leaf's own (a)"
    )
    ref pd = plan._project.value()[]
    assert_equal(len(pd.exprs), 1)
    assert_equal(String(pd.exprs[0]), String(Expr.col_ref(String("a"))))
    ref filtered = pd.child[]
    assert_equal(filtered.tag, PLAN_FILTER, "the kept filter is a NODE")
    ref fd = filtered._filter.value()[]
    assert_equal(
        String(fd.predicate),
        String(_filter_a_gt_5_and_a_gt_b()),
        "the WHOLE filter, not only the pushed conjunct",
    )
    ref scan = fd.child[]
    assert_true(_is_bound_inmem(scan, registry), "over a BOUND in-memory scan")
    ref sd = scan._scan.value()[]
    assert_false(Bool(sd.filter), "which carries NO filter of its own")
    assert_equal(len(sd.projection.value()), 2, "a, then b for the filter")
    assert_equal(sd.projection.value()[0], String("a"))
    assert_equal(sd.projection.value()[1], String("b"))

    # THE READER'S SHAPE: an ungrouped aggregate over a filtered open leaf —
    # what `_try_run_ungrouped_fold_substrate` folds when its child is a
    # PLAN_SCAN. After the pass the child is the Filter, so the fold declines.
    var agg = LogicalPlan.aggregate(
        Slab[Expr](),
        _one_agg(_sum(Optional(Expr.col_ref(String("a"))))),
        _leaf_of(
            set.get(scan_kind_id(String(_KIND_A))),
            String("orders"),
            None,
            Optional(_filter_a_gt_5_and_a_gt_b()),
        ),
    )
    assert_equal(resolve_plan_binding_leaves(agg, set, registry, snaps), 1)
    assert_equal(agg.tag, PLAN_AGGREGATE)
    assert_equal(
        agg._aggregate.value()[].child[].tag,
        PLAN_FILTER,
        "no aggregate sits directly on a re-rooted scan that had a filter",
    )


def test_a_gate_that_rejects_pushes_nothing_and_keeps_the_filter() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var plan = _leaf_of(
        set.get(scan_kind_id(String(_KIND_A))),
        String("orders"),
        None,
        Optional(_filter_a_gt_5_and_a_gt_b()),
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    assert_equal(tally[].last_predicate, String("<none>"))
    assert_equal(tally[].last_projection, String("<none>"))
    # The filter reads only (a, b), the leaf's own columns: a Filter directly
    # over the scan, no Project.
    assert_equal(plan.tag, PLAN_FILTER)
    ref fd = plan._filter.value()[]
    assert_equal(String(fd.predicate), String(_filter_a_gt_5_and_a_gt_b()))
    ref scan = fd.child[]
    assert_true(_is_bound_inmem(scan, registry))
    assert_false(Bool(scan._scan.value()[].filter), "the scan carries none")
    assert_equal(plan.output_schema.num_columns(), 2)


def test_a_payload_missing_a_needed_column_is_refused() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=_MODE_ONLY_A))
    var proj = List[String]()
    proj.append(String("b"))
    var plan = _leaf_of(
        set.get(scan_kind_id(String(_KIND_A))), String("orders"), Optional(proj^)
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_OPENED_SCHEMA_MISMATCH) in msg, msg)
        assert_true("'b'" in msg, "names the missing column: " + msg)
    assert_true(raised, "a missing column is wrong rows downstream, not a pass")
    assert_equal(len(snaps), 0, "nothing is reported for a refused leaf")


def test_an_empty_drain_is_an_empty_relation() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=_MODE_EMPTY))
    var plan = _leaf(set, String("quiet"))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var n = resolve_plan_binding_leaves(plan, set, registry, snaps)
    assert_equal(n, 1)
    assert_true(_is_bound_inmem(plan, registry))
    assert_equal(registry.resident_payload_rows(), 0)
    assert_equal(snaps[0].rows, 0)
    assert_equal(plan.output_schema.num_columns(), 2, "the binding's schema")


def test_every_plan_tag_has_an_arm_and_one_past_the_last_raises() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    for t in range(PLAN_TAG_COUNT):
        # A node of tag `t` with no payload: every modelled arm answers 0.
        var p = _leaf(set, String("orders"))
        p._scan = None
        p.tag = UInt8(t)
        assert_equal(
            resolve_plan_binding_leaves(p, set, registry, snaps),
            0,
            "plan tag " + String(t) + " has an arm",
        )
    var q = _leaf(set, String("orders"))
    q._scan = None
    q.tag = UInt8(PLAN_TAG_COUNT)
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(q, set, registry, snaps)
    except e:
        raised = True
        assert_true(String(SCAN_RESOLVE_PASS_UNMODELLED_TAG) in String(e))
    assert_true(raised, "an unmodelled plan tag must raise, not return 0")


def test_every_expr_tag_has_an_arm_and_one_past_the_last_raises() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    for t in range(EXPR_TAG_COUNT):
        var e = Expr.col_ref(String("a"))
        e.tag = UInt8(t)
        assert_equal(
            resolve_expr_binding_leaves(e, set, registry, snaps),
            0,
            "expr tag " + String(t) + " has an arm",
        )
    var x = Expr.col_ref(String("a"))
    x.tag = UInt8(EXPR_TAG_COUNT)
    var raised = False
    try:
        _ = resolve_expr_binding_leaves(x, set, registry, snaps)
    except e:
        raised = True
        assert_true(String(SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG) in String(e))
    assert_true(raised, "an unmodelled expression tag must raise, not return 0")


# =============================================================================
# RETENTION — the pass is an ACQUIRE; a scope opened BEFORE it is the release
# =============================================================================


def _names(*names: String) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(String(n))
    return out^


def test_the_pass_is_an_acquire_and_a_scope_opened_before_it_releases_it() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var snaps = List[ResolvedScanSnapshot]()

    # THE CONTROL. With no scope, destroying the only plan naming the payload
    # does NOT release it: the per-leaf bind took the registry's OWN reference.
    # If this ever reads 0 the assertions below measure nothing.
    var bare_registry = ScanRegistry()
    var bare = _leaf(set, String("orders"))
    _ = resolve_plan_binding_leaves(bare, set, bare_registry, snaps)
    _ = bare^
    assert_equal(
        bare_registry.resident_payload_rows(),
        5,
        "the pass is an ACQUIRE: the registry still holds the drained payload",
    )

    var registry = ScanRegistry()
    var scope = registry.open_scan_bind_scope()
    var plan = LogicalPlan.join(
        _leaf(set, String("orders")),
        _leaf(set, String("items")),
        _names("a"),
        _names("a"),
        JOIN_INNER,
    )
    assert_equal(resolve_plan_binding_leaves(plan, set, registry, snaps), 2)
    assert_equal(
        registry.resident_payload_rows(),
        10,
        "held across the execution while the scope is open",
    )
    _ = scope^
    assert_equal(
        registry.resident_payload_rows(),
        0,
        "a scope opened BEFORE the pass releases every slot the pass minted",
    )
    _ = plan^


def test_a_scope_opened_before_the_pass_releases_on_the_unwind_path() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var b = ErasedScanMorselResolver.erase(_StubTopic(tally, String(_KIND_B)))
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var scope = registry.open_scan_bind_scope()
    # Leaf 1 (left, walked first) is registered and binds; leaf 2 is not.
    var plan = LogicalPlan.join(
        _leaf(set, String("orders")),
        _leaf_of(b, String("clicks")),
        _names("a"),
        _names("a"),
        JOIN_INNER,
    )
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    except e:
        raised = True
        assert_true(String(SCAN_KIND_NOT_EXECUTABLE) in String(e), String(e))
    assert_true(raised, "leaf 2 has no resolver")
    assert_equal(
        registry.resident_payload_rows(),
        5,
        "leaf 1 was ACQUIRED before leaf 2 raised: the slot the unwind owes",
    )
    _ = scope^
    assert_equal(
        registry.resident_payload_rows(),
        0,
        "the scope's destructor releases on the unwind path too",
    )
    _ = plan^


# =============================================================================
# THE DECLARED RELATION — a leaf with no projection re-projects to the binding
# =============================================================================


def test_a_superset_or_reordered_payload_is_the_declared_relation() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(
        _StubTopic(tally, String(_KIND_A), mode=_MODE_SUPERSET_REORDERED)
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var want = _schema_ab()

    # NO projection (the SELECT * shape): the request asks for everything, the
    # kind returns (c, b, a), and the leaf still produces exactly (a, b).
    var plan = _leaf(set, String("orders"))
    assert_equal(resolve_plan_binding_leaves(plan, set, registry, snaps), 1)
    assert_equal(tally[].last_projection, String("<none>"))
    assert_true(_is_bound_inmem(plan, registry))
    assert_equal(plan.output_schema.num_columns(), 2, "not the payload's 3")
    for i in range(2):
        assert_equal(plan.output_schema.field_name(i), want.field_name(i))
        assert_true(
            plan.output_schema.field_arrow_type(i) == want.field_arrow_type(i)
        )
    ref sd = plan._scan.value()[]
    assert_true(Bool(sd.projection), "re-projected to the binding's columns")
    assert_equal(len(sd.projection.value()), 2)
    assert_equal(sd.projection.value()[0], String("a"))
    assert_equal(sd.projection.value()[1], String("b"))

    # WITH a projection: the same kind, the same payload, the same acceptance.
    var proj = _names("b")
    var plan2 = _leaf_of(
        set.get(scan_kind_id(String(_KIND_A))), String("orders"), Optional(proj^)
    )
    assert_equal(resolve_plan_binding_leaves(plan2, set, registry, snaps), 1)
    assert_equal(plan2.output_schema.num_columns(), 1)
    assert_equal(plan2.output_schema.field_name(0), String("b"))


# =============================================================================
# THE PAYLOAD CHECKS — every branch fires, and every one fires BEFORE the bind
# =============================================================================


def _leaf_schema(
    set: ScanMorselResolvers,
    topic: String,
    var schema: Schema,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    """A binding leaf whose PLAN schema is `schema` — which a well-formed plan
    makes equal to the binding's; the output-shape guard is for one that is
    not."""
    var p = ScanParams()
    p.put_str(String("topic"), String(topic))
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(
            set.get(scan_kind_id(String(_KIND_A))).build_binding(p)
        ),
        schema^,
        projection^,
        filter^,
    )


def _assert_refused(
    mode: Int,
    var schema: Schema,
    var projection: Optional[List[String]],
    var filter: Optional[Expr],
    want: String,
    what: String,
    also: String = "",
) raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=mode))
    var plan = _leaf_schema(
        set, String("orders"), schema^, projection^, filter^
    )
    # NO scope, on purpose: a refused leaf must mint nothing, so there is
    # nothing for a scope to release.
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    except e:
        raised = True
        var msg = String(e)
        assert_true(String(SCAN_OPENED_SCHEMA_MISMATCH) in msg, what + ": " + msg)
        assert_true(want in msg, what + ": names what is wrong: " + msg)
        assert_true(also in msg, what + ": and how: " + msg)
    assert_true(raised, what + ": must be refused, not executed")
    assert_equal(tally[].opens, 1, what + ": refused by the payload checks")
    assert_equal(len(snaps), 0, what + ": nothing reported for a refused leaf")
    assert_equal(
        registry.resident_payload_rows(),
        0,
        what + ": every check runs BEFORE the bind, so no slot was minted",
    )


def test_every_batch_must_carry_batch_zeros_schema() raises:
    _assert_refused(
        _MODE_B1_RETYPED,
        _schema_ab(),
        None,
        None,
        String("batch 1"),
        String("batch 1 retypes b"),
    )
    _assert_refused(
        _MODE_B1_RENAMED,
        _schema_ab(),
        None,
        None,
        String("batch 1"),
        String("batch 1 renames b to c"),
    )
    _assert_refused(
        _MODE_B1_REORDERED,
        _schema_ab(),
        None,
        None,
        String("batch 1"),
        String("batch 1 reorders (a, b) to (b, a)"),
    )


def test_a_later_batch_of_another_width_is_refused_by_name() raises:
    # WIDER: without the width branch the per-column loop indexes batch 0's
    # schema past its last field — an out-of-bounds read, not a refusal.
    _assert_refused(
        _MODE_B1_WIDER,
        _schema_ab(),
        None,
        None,
        String("batch 1 carrying 3 columns where batch 0 carries 2"),
        String("batch 1 is (a, b, c) under batch 0's (a, b)"),
    )
    # NARROWER: without it, core's `from_shared_batches` column-count error —
    # which is not this pass's named refusal.
    _assert_refused(
        _MODE_B1_NARROWER,
        _schema_ab(),
        None,
        None,
        String("batch 1 carrying 1 columns where batch 0 carries 2"),
        String("batch 1 is (a) under batch 0's (a, b)"),
    )


def test_every_batch_is_checked_over_columns_the_plan_does_not_read() raises:
    # The leaf reads only a; only b drifts in batch 1. Still refused: the
    # in-memory source's one schema would be false, and a reader that
    # bypasses the projection reads the batch whole.
    _assert_refused(
        _MODE_B1_RETYPED,
        _schema_ab(),
        Optional(_names("a")),
        None,
        String("batch 1 carrying column 1 as 'b'"),
        String("batch 1 retypes b, which the plan does not read"),
    )


def test_a_drifted_type_parameter_is_refused_by_every_check() raises:
    """`ArrowType` is a bare tag: DECIMAL128 is 18 whatever its (p, s), and a
    zoned and a naive timestamp share one. Each check compares the FULL type."""
    # (a) batch 1 carries d as (18,4) under batch 0's (18,2).
    _assert_refused(
        _MODE_B1_DEC_SCALE,
        _schema_ad(2),
        None,
        None,
        String("batch 1 carrying column 1 as 'd'"),
        String("batch 1 rescales d from (18,2) to (18,4)"),
        String("decimal (precision, scale) (18,4) vs (18,2)"),
    )
    # (b) the payload carries d as (18,4) where the binding declared (18,2).
    _assert_refused(
        _MODE_DEC_SCALE,
        _schema_ad(2),
        None,
        None,
        String("the declared type of column 'd'"),
        String("the kind returns d as (18,4), its binding declared (18,2)"),
        String("returned vs declared: decimal (precision, scale) (18,4) vs (18,2)"),
    )
    # (c) the payload and the binding agree at (18,2); the plan leaf promised
    # its parents (18,4). Only `_check_same_output` can see it.
    _assert_refused(
        _MODE_DEC,
        _schema_ad(4),
        None,
        None,
        String("output column 'd'"),
        String("the plan leaf promised d as (18,4)"),
        String("re-rooted vs promised: decimal (precision, scale) (18,2) vs (18,4)"),
    )
    # (d) batch 1 carries t naive under batch 0's 'UTC'.
    _assert_refused(
        _MODE_B1_TZ,
        _schema_at(String("UTC")),
        None,
        None,
        String("batch 1 carrying column 1 as 't'"),
        String("batch 1 drops t's zone"),
        String("timestamp timezone '' vs 'UTC'"),
    )


def test_a_later_batch_with_another_dictionary_index_type_is_refused() raises:
    _assert_refused(
        _MODE_B1_DICT16,
        _schema_ak(),
        None,
        None,
        String("batch 1 carrying column 1 as 'k'"),
        String("batch 1 widens k's dictionary indices from INT8 to INT16"),
        String("dictionary index type"),
    )


def test_a_later_batch_with_another_list_item_type_is_refused() raises:
    _assert_refused(
        _MODE_B1_LIST_ITEM,
        _schema_al(ArrowType.INT64),
        None,
        None,
        String("batch 1 carrying column 1 as 'l'"),
        String("batch 1 changes l from LIST<INT64> to LIST<STRING>"),
        String("child 0 type"),
    )


def test_a_later_batch_with_other_union_type_ids_is_refused() raises:
    """The UNION arm of `_field_type_diff`: UNION_SPARSE is one tag whatever
    its type ids, and the ids are what map a slot's type byte to a child."""
    _assert_refused(
        _MODE_B1_UNION_IDS,
        _schema_au(_ids(0, 1)),
        None,
        None,
        String("batch 1 carrying column 1 as 'u'"),
        String("batch 1 renumbers u's union type ids from [0, 1] to [0, 2]"),
        String("union type ids"),
    )


def test_a_later_batch_with_fewer_union_type_ids_is_refused() raises:
    """The UNION arm's LENGTH compare, FEWER: the element loop walks batch 1's
    ids and indexes batch 0's by the same k, so without the length compare it
    walks batch 1's ONE id, finds it equal to batch 0's first, and returns "":
    a union of [0] read under [0, 1] — and a union here has no child fields,
    so the child count cannot catch it either — accepted silently. The
    equal-length [0, 2] case above cannot see this: its element compare
    refuses it on its own."""
    _assert_refused(
        _MODE_B1_UNION_FEWER,
        _schema_au(_ids(0, 1)),
        None,
        None,
        String("batch 1 carrying column 1 as 'u'"),
        String("batch 1 drops u's union type id 1"),
        String("union type ids"),
    )


def test_a_later_batch_with_more_union_type_ids_is_refused() raises:
    """The UNION arm's LENGTH compare, MORE, and the `if same:` that guards
    the element loop with it: without either, the loop reads batch 0's id 2,
    past its last — an out-of-bounds abort, never a refusal by name."""
    _assert_refused(
        _MODE_B1_UNION_MORE,
        _schema_au(_ids(0, 1)),
        None,
        None,
        String("batch 1 carrying column 1 as 'u'"),
        String("batch 1 adds a union type id 2 to u"),
        String("union type ids"),
    )


def test_a_later_batch_with_a_renamed_struct_child_is_refused() raises:
    """The STRUCT child-NAME arm: the child's tag, and the child count, are
    unchanged, and a struct field is read by name."""
    _assert_refused(
        _MODE_B1_STRUCT_RENAMED,
        _schema_as(_names("x", "y")),
        None,
        None,
        String("batch 1 carrying column 1 as 's'"),
        String("batch 1 renames s's child x to z"),
        String("struct child 0 name 'z' vs 'x'"),
    )


def test_a_later_batch_with_fewer_struct_children_is_refused() raises:
    """The CHILD-COUNT arm, which must run BEFORE the per-child loop: the loop
    walks `a`'s children and indexes `b`'s by the same k. FEWER: without the
    count compare, the loop walks batch 1's ONE child, finds it equal to batch
    0's child 0, and returns "": STRUCT{x} read under STRUCT{x, y}, accepted
    silently."""
    _assert_refused(
        _MODE_B1_STRUCT_FEWER,
        _schema_as(_names("x", "y")),
        None,
        None,
        String("batch 1 carrying column 1 as 's'"),
        String("batch 1 drops s's child y"),
        String("child count 1 vs 2"),
    )


def test_a_later_batch_with_more_struct_children_is_refused() raises:
    """The CHILD-COUNT arm, MORE: without the count compare, the loop reads
    batch 0's child 2, past its last (`Schema.field_child_arrow_type` does
    no range check of its own) — an out-of-bounds abort in fastbuild and an
    unchecked read in an optimized build, never a refusal."""
    _assert_refused(
        _MODE_B1_STRUCT_MORE,
        _schema_as(_names("x", "y")),
        None,
        None,
        String("batch 1 carrying column 1 as 's'"),
        String("batch 1 adds a child w to s"),
        String("child count 3 vs 2"),
    )


def test_a_decimal_keeps_its_parameters_through_the_filter_and_project() raises:
    """The CONTROL for the parametric refusals: the same kind, batches that
    agree with the binding, is ACCEPTED — through the widest re-root (scan,
    Filter, Project), whose output must still be DECIMAL128(18,2), or
    `_check_same_output` refuses it."""
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=_MODE_DEC))
    var pred = Expr.col_ref(String("a")) > Expr.literal(
        ScalarValue.from_int64(Int64(0))
    )
    var plan = _leaf_schema(
        set, String("prices"), _schema_ad(2), Optional(_names("d")),
        Optional(pred^),
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    assert_equal(resolve_plan_binding_leaves(plan, set, registry, snaps), 1)
    assert_equal(plan.tag, PLAN_PROJECT, "a is read by the filter only")
    assert_equal(plan.output_schema.num_columns(), 1)
    assert_equal(plan.output_schema.field_name(0), String("d"))
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.DECIMAL128)
    assert_equal(plan.output_schema.field_decimal_precision(0), 18)
    assert_equal(plan.output_schema.field_decimal_scale(0), 2)
    assert_equal(registry.resident_payload_rows(), 5)


def test_a_dictionary_keeps_its_index_type_through_the_project() raises:
    """The Project the re-root adds when the filter reads another column must
    not narrow a type: `LogicalPlan.project`'s own inference drops a
    dictionary's index type (INT8 would become the INT32 default), and the
    full-type `_check_same_output` would then refuse a CORRECT plan."""
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=_MODE_DICT8))
    var pred = Expr.col_ref(String("a")) > Expr.literal(
        ScalarValue.from_int64(Int64(0))
    )
    var plan = _leaf_schema(
        set, String("tags"), _schema_ak(), Optional(_names("k")),
        Optional(pred^),
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    assert_equal(resolve_plan_binding_leaves(plan, set, registry, snaps), 1)
    assert_equal(plan.tag, PLAN_PROJECT)
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.DICTIONARY)
    assert_true(
        plan.output_schema.field_dict_index_type(0) == ArrowType.INT8,
        "the dictionary's INT8 index type survives the Project",
    )


def test_a_retyped_column_that_only_the_filter_reads_is_refused() raises:
    var pred = Expr.col_ref(String("b")) > Expr.literal(
        ScalarValue.from_int64(Int64(5))
    )
    _assert_refused(
        _MODE_B_F64,
        _schema_ab(),
        Optional(_names("a")),
        Optional(pred^),
        String("the declared type of column 'b'"),
        String("b is float64, declared int64, and only the filter reads it"),
    )


def test_an_output_shape_change_is_refused_before_anything_is_bound() raises:
    # The payload matches the BINDING; the plan leaf promised its parents
    # something else. Only `_check_same_output` can see this.
    _assert_refused(
        _MODE_FULL,
        Schema.from_fields_2(_i64("a"), Field("b", DType.float64, True)),
        None,
        None,
        String("output column 'b'"),
        String("the plan leaf promised b as float64"),
    )
    _assert_refused(
        _MODE_FULL,
        Schema.from_fields_3(_i64("a"), _i64("b"), _i64("c")),
        None,
        None,
        String("from 3 to 2 columns"),
        String("the plan leaf promised three columns"),
    )


def test_a_raise_after_the_resolve_leaves_the_plans_own_leaf_and_token() raises:
    """The falsifiable form of "the cached plan's LIVE token stays 0": hand the
    pass the plan ITSELF (not a copy) and make it raise AFTER it resolved."""
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A), mode=_MODE_ONLY_A))
    var plan = _leaf_of(
        set.get(scan_kind_id(String(_KIND_A))),
        String("orders"),
        Optional(_names("b")),
    )
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    var raised = False
    try:
        _ = resolve_plan_binding_leaves(plan, set, registry, snaps)
    except e:
        raised = True
        assert_true(String(SCAN_OPENED_SCHEMA_MISMATCH) in String(e))
    assert_true(raised)
    assert_equal(
        tally[].resolves, 1, "the LIVE token WAS resolved: a write-back had its chance"
    )
    assert_equal(tally[].opens, 1)
    ref src = plan._scan.value()[].source
    assert_equal(src.tag, SOURCE_VARIANT_BINDING, "the plan keeps its leaf")
    assert_equal(
        src.binding_ref().snapshot_token,
        UInt64(0),
        "the per-execution token (101) was never written into the plan",
    )


# =============================================================================
# DESCENT — every child and every Expr slot is WALKED, not merely dispatched
# =============================================================================


def _plain() raises -> LogicalPlan:
    """An in-memory leaf this pass leaves alone (and does not bind)."""
    return LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(_batch_ab(4))),
        _schema_ab(),
    )


def _exists(set: ScanMorselResolvers) raises -> Expr:
    """EXISTS over an open leaf: the only way an `Expr` holds a plan."""
    return Expr.correlated_subquery(
        _leaf(set, String("sub")), _names("a"), CORR_KIND_EXISTS
    )


def _c() -> Expr:
    return Expr.col_ref(String("a"))


def _assert_plan_descends(
    var plan: LogicalPlan,
    set: ScanMorselResolvers,
    what: String,
    mut seen: List[Bool],
    want: Int = 1,
) raises:
    seen[Int(plan.tag)] = True
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    assert_equal(
        resolve_plan_binding_leaves(plan, set, registry, snaps),
        want,
        what + ": the open leaf under it is found",
    )
    assert_equal(len(snaps), want, what)
    assert_equal(
        registry.resident_payload_rows(), 5 * want, what + ": and bound"
    )
    assert_equal(
        resolve_plan_binding_leaves(plan, set, registry, snaps),
        0,
        what + ": and re-rooted IN the plan (a second pass finds nothing)",
    )


def _assert_expr_descends(
    var expr: Expr,
    set: ScanMorselResolvers,
    what: String,
    mut seen: List[Bool],
) raises:
    seen[Int(expr.tag)] = True
    var registry = ScanRegistry()
    var snaps = List[ResolvedScanSnapshot]()
    assert_equal(
        resolve_expr_binding_leaves(expr, set, registry, snaps),
        1,
        what + ": the subquery's open leaf is found",
    )
    assert_equal(registry.resident_payload_rows(), 5, what + ": and bound")
    assert_equal(
        resolve_expr_binding_leaves(expr, set, registry, snaps),
        0,
        what + ": and re-rooted IN the expression (a second pass finds nothing)",
    )


def _one_agg(var ae: AggExpr) -> Slab[AggExpr]:
    var out = Slab[AggExpr]()
    out.append(ae^)
    return out^


def _sum(var child: Optional[Expr]) -> AggExpr:
    return AggExpr(AGG_SUM, child^, Optional[String](String("s")))


def test_every_child_bearing_plan_arm_descends_to_an_open_leaf() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var seen = List[Bool](length=PLAN_TAG_COUNT, fill=False)
    var pred = Expr.col_ref(String("a")) > Expr.literal(
        ScalarValue.from_int64(Int64(5))
    )

    # ---- SCAN: its pushed filter is an Expr, so a scan is not a leaf here.
    _assert_plan_descends(
        LogicalPlan.scan_from_source(
            SourceVariant(InMemorySource.from_record_batch(_batch_ab(4))),
            _schema_ab(),
            None,
            Optional(_exists(set)),
        ),
        set,
        "SCAN(in-memory).filter",
        seen,
    )
    _assert_plan_descends(
        _leaf_of(
            set.get(scan_kind_id(String(_KIND_A))),
            String("outer"),
            None,
            Optional(_exists(set)),
        ),
        set,
        "SCAN(open).filter AND the scan itself",
        seen,
        want=2,
    )

    # ---- FILTER / PROJECT / AGGREGATE: the child AND every Expr slot.
    _assert_plan_descends(
        LogicalPlan.filter(pred.copy(), _leaf(set, String("t"))),
        set,
        "FILTER.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.filter(_exists(set), _plain()),
        set,
        "FILTER.predicate",
        seen,
    )
    var pe = Slab[Expr]()
    pe.append(_c())
    _assert_plan_descends(
        LogicalPlan.project(pe^, _leaf(set, String("t"))),
        set,
        "PROJECT.child",
        seen,
    )
    var pe2 = Slab[Expr]()
    pe2.append(_c())
    pe2.append(_exists(set))
    _assert_plan_descends(
        LogicalPlan.project(pe2^, _plain()), set, "PROJECT.exprs[1]", seen
    )
    _assert_plan_descends(
        LogicalPlan.aggregate(
            Slab[Expr](), _one_agg(_sum(Optional(_c()))), _leaf(set, String("t"))
        ),
        set,
        "AGGREGATE.child",
        seen,
    )
    var gb = Slab[Expr]()
    gb.append(_exists(set))
    _assert_plan_descends(
        LogicalPlan.aggregate(gb^, Slab[AggExpr](), _plain()),
        set,
        "AGGREGATE.group_by[0]",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.aggregate(
            Slab[Expr](), _one_agg(_sum(Optional(_exists(set)))), _plain()
        ),
        set,
        "AGGREGATE.agg_exprs[0].child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.aggregate(
            Slab[Expr](),
            _one_agg(
                AggExpr(
                    AGG_SUM,
                    Optional(_c()),
                    Optional(_exists(set)),
                    Optional[String](String("s")),
                )
            ),
            _plain(),
        ),
        set,
        "AGGREGATE.agg_exprs[0].child1",
        seen,
    )
    var a2 = _sum(Optional(_c()))
    a2.child2 = Optional(_exists(set))
    _assert_plan_descends(
        LogicalPlan.aggregate(Slab[Expr](), _one_agg(a2^), _plain()),
        set,
        "AGGREGATE.agg_exprs[0].child2",
        seen,
    )
    var a3 = _sum(Optional(_c()))
    a3.child3 = Optional(_exists(set))
    _assert_plan_descends(
        LogicalPlan.aggregate(Slab[Expr](), _one_agg(a3^), _plain()),
        set,
        "AGGREGATE.agg_exprs[0].child3",
        seen,
    )
    var two = Slab[AggExpr]()
    two.append(_sum(Optional(_c())))
    two.append(_sum(Optional(_exists(set))))
    _assert_plan_descends(
        LogicalPlan.aggregate(Slab[Expr](), two^, _plain()),
        set,
        "AGGREGATE.agg_exprs[1].child",
        seen,
    )

    # ---- SINGLE CHILD, NO EXPRESSIONS.
    _assert_plan_descends(
        LogicalPlan.sort(_names("a"), [False], _leaf(set, String("t"))),
        set,
        "SORT.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.limit(3, _leaf(set, String("t"))), set, "LIMIT.child", seen
    )
    _assert_plan_descends(
        LogicalPlan.distinct(None, _leaf(set, String("t"))),
        set,
        "DISTINCT.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.topn(_names("a"), [False], 3, _leaf(set, String("t"))),
        set,
        "TOPN.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.partition_by(
            _names("a"),
            _names("b"),
            [False],
            List[PartitionExpr](),
            _leaf(set, String("t")),
        ),
        set,
        "PARTITION_BY.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.partition_topn(
            _names("a"), _names("b"), [False], 2, _leaf(set, String("t"))
        ),
        set,
        "PARTITION_TOPN.child",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.cast_to_varchar(_leaf(set, String("t"))),
        set,
        "CAST_TO_VARCHAR.child",
        seen,
    )

    # ---- TWO OR MORE CHILDREN.
    _assert_plan_descends(
        LogicalPlan.join(
            _leaf(set, String("t")), _plain(), _names("a"), _names("a"), JOIN_INNER
        ),
        set,
        "JOIN.left",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.join(
            _plain(), _leaf(set, String("t")), _names("a"), _names("a"), JOIN_INNER
        ),
        set,
        "JOIN.right",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.join(
            _plain(),
            _plain(),
            _names("a"),
            _names("a"),
            JOIN_INNER,
            residual=Optional(OwnedPointer(_exists(set))),
        ),
        set,
        "JOIN.residual",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.asof_join(
            _leaf(set, String("t")),
            _plain(),
            List[String](),
            List[String](),
            String("a"),
            String("a"),
            ASOF_BACKWARD,
            AsofTolerance.none(),
        ),
        set,
        "ASOF_JOIN.left",
        seen,
    )
    _assert_plan_descends(
        LogicalPlan.asof_join(
            _plain(),
            _leaf(set, String("t")),
            List[String](),
            List[String](),
            String("a"),
            String("a"),
            ASOF_BACKWARD,
            AsofTolerance.none(),
        ),
        set,
        "ASOF_JOIN.right",
        seen,
    )
    var u0 = List[OwnedPointer[LogicalPlan]]()
    u0.append(OwnedPointer(_leaf(set, String("t"))))
    u0.append(OwnedPointer(_plain()))
    _assert_plan_descends(
        LogicalPlan.union(u0^, _schema_ab()), set, "UNION.children[0]", seen
    )
    var u1 = List[OwnedPointer[LogicalPlan]]()
    u1.append(OwnedPointer(_plain()))
    u1.append(OwnedPointer(_leaf(set, String("t"))))
    _assert_plan_descends(
        LogicalPlan.union(u1^, _schema_ab()), set, "UNION.children[1]", seen
    )

    # A new child-bearing tag reds this table, not only the unmodelled-tag test.
    for t in range(PLAN_TAG_COUNT):
        if t == Int(PLAN_VIEW_REF) or t == Int(PLAN_CSE_REF):
            continue
        assert_true(
            seen[t],
            "plan tag "
            + String(t)
            + " ("
            + plan_tag_name(UInt8(t))
            + ") has no descent case in this table",
        )


def test_every_expr_slot_descends_to_an_open_leaf() raises:
    var tally = ArcPointer(_Tally())
    var set = _set_of(_StubTopic(tally, String(_KIND_A)))
    var seen = List[Bool](length=EXPR_TAG_COUNT, fill=False)

    _assert_expr_descends(_exists(set), set, "CORRELATED_SUBQUERY", seen)
    _assert_expr_descends(
        Expr.binary(BIN_AND, _exists(set), _c()), set, "BINARY_OP.left", seen
    )
    _assert_expr_descends(
        Expr.binary(BIN_AND, _c(), _exists(set)), set, "BINARY_OP.right", seen
    )
    _assert_expr_descends(Expr.unary(UN_NOT, _exists(set)), set, "UNARY_OP", seen)
    _assert_expr_descends(
        Expr.cast(_exists(set), DType.int64), set, "CAST", seen
    )
    _assert_expr_descends(
        Expr.alias(_exists(set), String("x")), set, "ALIAS", seen
    )
    _assert_expr_descends(
        Expr.string_op(STR_CONTAINS, _exists(set), String("p")),
        set,
        "STRING_OP",
        seen,
    )
    var w0 = List[WhenCaseData]()
    w0.append(WhenCaseData(_exists(set), _c()))
    _assert_expr_descends(
        Expr.when(w0^, _c()), set, "WHEN.cases[0].condition", seen
    )
    var w1 = List[WhenCaseData]()
    w1.append(WhenCaseData(_c(), _exists(set)))
    _assert_expr_descends(Expr.when(w1^, _c()), set, "WHEN.cases[0].result", seen)
    var w2 = List[WhenCaseData]()
    w2.append(WhenCaseData(_c(), _c()))
    w2.append(WhenCaseData(_c(), _exists(set)))
    _assert_expr_descends(Expr.when(w2^, _c()), set, "WHEN.cases[1].result", seen)
    var w3 = List[WhenCaseData]()
    w3.append(WhenCaseData(_c(), _c()))
    _assert_expr_descends(
        Expr.when(w3^, _exists(set)), set, "WHEN.default", seen
    )
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(1)))
    # `in_list_node`, NOT `in_list`: the SQL factory lowers a short list to an
    # OR-chain of BINARY_OPs and never builds tag 9 (measured: the coverage
    # check below caught this table exercising BINARY_OP twice instead).
    _assert_expr_descends(
        Expr.in_list_node(_exists(set), vals^), set, "IN_LIST", seen
    )
    _assert_expr_descends(Expr.agg_fn(AGG_SUM, _exists(set)), set, "AGG_FN", seen)
    _assert_expr_descends(
        Expr.regexp(REGEXP_LIKE, _exists(set), String("p")), set, "REGEXP", seen
    )
    _assert_expr_descends(
        Expr.struct_field(_exists(set), String("f")), set, "STRUCT_FIELD", seen
    )
    _assert_expr_descends(
        Expr.struct_field_idx(_exists(set), 0), set, "STRUCT_FIELD_IDX", seen
    )
    _assert_expr_descends(
        Expr.map_get(_exists(set), _c()), set, "MAP_GET.parent", seen
    )
    _assert_expr_descends(
        Expr.map_get(_c(), _exists(set)), set, "MAP_GET.key", seen
    )
    _assert_expr_descends(
        Expr.json_extract_from_parts(
            _exists(set), _names("k"), ArrowType.STRING, False
        ),
        set,
        "JSON_EXTRACT",
        seen,
    )
    _assert_expr_descends(
        Expr.extract(EXTRACT_YEAR, _exists(set)), set, "EXTRACT", seen
    )
    _assert_expr_descends(
        Expr.math_fn(MATH_SIN, _exists(set)), set, "MATH_FN", seen
    )
    _assert_expr_descends(
        Expr.math_fn2(MATH2_ATAN2, _exists(set), _c()),
        set,
        "MATH_FN2.left",
        seen,
    )
    _assert_expr_descends(
        Expr.math_fn2(MATH2_ATAN2, _c(), _exists(set)),
        set,
        "MATH_FN2.right",
        seen,
    )
    _assert_expr_descends(
        Expr.substring(_exists(set), 1, 2), set, "SUBSTRING", seen
    )
    _assert_expr_descends(
        Expr.string_fn(STRFN_UPPER, _exists(set)), set, "STRING_FN", seen
    )
    var args = List[Expr]()
    args.append(_c())
    args.append(_exists(set))
    _assert_expr_descends(
        Expr.string_fn_n(STRFNN_CONCAT, args^), set, "STRING_FN_N.args[1]", seen
    )
    _assert_expr_descends(
        Expr.udf_call(
            String("f"), None, ArrowType.INT64, ArrowType.INT64, _exists(set)
        ),
        set,
        "UDF_CALL",
        seen,
    )

    for t in range(EXPR_TAG_COUNT):
        var tag = UInt8(t)
        if (
            tag == EXPR_COL_REF
            or tag == EXPR_COL_IDX
            or tag == EXPR_LITERAL
            or tag == EXPR_WINDOW_FN
            or tag == EXPR_BETWEEN
            or tag == EXPR_SORT_KEY
        ):
            continue
        assert_true(
            seen[t],
            "expr tag "
            + String(t)
            + " ("
            + expr_tag_name(tag)
            + ") can hold a child Expr and has no descent case in this table",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_an_open_leaf_is_rerooted_as_a_bound_inmem_scan]()
    suite.test[
        test_the_cached_token_stays_zero_and_each_execution_resolves_its_own
    ]()
    suite.test[
        test_a_join_of_two_open_leaves_and_a_subquery_leaf_are_all_resolved
    ]()
    suite.test[
        test_an_unregistered_kind_raises_naming_it_and_the_registered_kinds
    ]()
    suite.test[test_legacy_binding_arms_and_inmem_leaves_are_untouched]()
    suite.test[
        test_the_kept_filter_is_a_filter_node_above_an_unfiltered_scan
    ]()
    suite.test[test_a_gate_that_rejects_pushes_nothing_and_keeps_the_filter]()
    suite.test[test_a_payload_missing_a_needed_column_is_refused]()
    suite.test[test_an_empty_drain_is_an_empty_relation]()
    suite.test[test_every_plan_tag_has_an_arm_and_one_past_the_last_raises]()
    suite.test[test_every_expr_tag_has_an_arm_and_one_past_the_last_raises]()
    suite.test[
        test_the_pass_is_an_acquire_and_a_scope_opened_before_it_releases_it
    ]()
    suite.test[
        test_a_scope_opened_before_the_pass_releases_on_the_unwind_path
    ]()
    suite.test[test_a_superset_or_reordered_payload_is_the_declared_relation]()
    suite.test[test_every_batch_must_carry_batch_zeros_schema]()
    suite.test[test_a_later_batch_of_another_width_is_refused_by_name]()
    suite.test[
        test_every_batch_is_checked_over_columns_the_plan_does_not_read
    ]()
    suite.test[test_a_drifted_type_parameter_is_refused_by_every_check]()
    suite.test[
        test_a_later_batch_with_another_dictionary_index_type_is_refused
    ]()
    suite.test[test_a_later_batch_with_another_list_item_type_is_refused]()
    suite.test[test_a_later_batch_with_other_union_type_ids_is_refused]()
    suite.test[test_a_later_batch_with_fewer_union_type_ids_is_refused]()
    suite.test[test_a_later_batch_with_more_union_type_ids_is_refused]()
    suite.test[test_a_later_batch_with_a_renamed_struct_child_is_refused]()
    suite.test[test_a_later_batch_with_fewer_struct_children_is_refused]()
    suite.test[test_a_later_batch_with_more_struct_children_is_refused]()
    suite.test[
        test_a_decimal_keeps_its_parameters_through_the_filter_and_project
    ]()
    suite.test[test_a_dictionary_keeps_its_index_type_through_the_project]()
    suite.test[test_a_retyped_column_that_only_the_filter_reads_is_refused]()
    suite.test[
        test_an_output_shape_change_is_refused_before_anything_is_bound
    ]()
    suite.test[
        test_a_raise_after_the_resolve_leaves_the_plans_own_leaf_and_token
    ]()
    suite.test[test_every_child_bearing_plan_arm_descends_to_an_open_leaf]()
    suite.test[test_every_expr_slot_descends_to_an_open_leaf]()
    suite^.run()
