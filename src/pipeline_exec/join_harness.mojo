# =============================================================================
# join_harness -- join plans by hand, small tables to join, and the oracle
# =============================================================================
#
# What a test needs to run a join of any kind through `run_plan` and
# `RealBuilder`, or through `HashProbeOp` alone:
#
#   * segment descriptors: `build_segment` (a resident batch collected for a
#     join, ending in SINK_HASH_BUILD), `as_build_sink` (any segment turned
#     into a build side), `probe_op` (an OP_JOIN_PROBE of the chain),
#     `with_build_dep` (a segment that depends on a build side) and
#     `probe_segment` (a resident probe side with one probe);
#   * tables, each cell a function of its row number r:
#
#       orders_batch(start, rows)
#         o_id       INT64, no NULL, r
#         o_custkey  INT64, NULL where r % 11 == 4, else (r * 7) % 13
#         o_total    INT64, no NULL, r * 10 + 3
#       customer_batch(rows)
#         c_custkey  INT32, NULL where r % 7 == 3, else r % 10. The key 0 of
#                    row 10 is NULL with 0 stored under it; rows 0 and 20 hold
#                    a real 0.
#         c_name     STRING, no NULL, "c" followed by r
#         c_nation   INT64, NULL where r % 6 == 5, else r % 3
#       null_key_customer_batch(rows)
#         customer_batch's columns, c_custkey NULL in every row, c_nation
#         r % 3 with no NULL
#       nation_batch(rows)
#         n_nationkey  INT64, r
#         n_name       STRING, "n" followed by r
#       refund_batch(rows)
#         o_id       INT64, r * 2 (names that collide with the orders' columns)
#         o_total    INT64, r * 100
#         reason     STRING, "r" followed by r % 3
#       tag_probe_batch(start, rows)
#         p_id       INT64, r
#         p_tag      STRING, NULL where r % 9 == 2, else "t" followed by r % 5
#       tag_build_batch(rows)
#         b_tag      STRING, NULL where r % 4 == 3, else "t" followed by r % 3
#         b_val      INT64, r * 100
#       float_probe_batch(rows)
#         f_id       INT64, r
#         f_key      FLOAT64 by r % 6: -0.0, 0.0, NaN, 1.5, NULL, -1.5
#       float_build_batch()
#         g_key      FLOAT64: 0.0, NaN (another bit pattern), 1.5, NULL, 1.5
#         g_val      INT64, r * 100
#       pair_probe_batch(rows) and pair_build_batch(rows)
#         two INT64 keys k1, k2 (NULL where r % 8 == 5 in k2) for a composite
#         key, with a payload column each: pv and bv.
#
#   * the oracle: `table_of` reads a batch into text, `oracle_join` is the
#     nested-loop inner join of two such tables on named key columns (a NULL
#     key matches nothing; a FLOAT64 key's NaN equals NaN and -0.0 equals
#     0.0; integer keys of any width compare by value), `select_columns` and
#     `keep_rows` reduce a table, and `sorted_rows`
#     gives a table's rows as sorted strings so that two results compare as
#     multisets whatever order the workers produced them in; `expect_rows`
#     asserts two such lists equal; `oracle_join_kind` is the nested-loop join
#     of any kind (INNER, LEFT, RIGHT, FULL, SEMI, ANTI, and CROSS when the key
#     lists are empty), a padded side's cells shown as NULL_TEXT.

from std.memory import bitcast
from std.testing import assert_equal

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from containers.slab import Slab
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    MorselOp,
    SegmentDescPod,
    SINK_HASH_BUILD,
    SINK_ORIENT_COLUMNAR,
)
from plan_ir.logical_plan import (
    JOIN_ANTI,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)

from .plan_harness import batch_segment, chain

comptime NULL_TEXT = "<null>"
"""How the oracle's tables show a NULL cell."""


# ---- segment descriptors ------------------------------------------------------


def as_build_sink(var desc: SegmentDescPod) -> SegmentDescPod:
    """`desc` with its sink changed to SINK_HASH_BUILD: the join's build side,
    which collects its rows for the probe that names the segment."""
    desc.sink_kind = SINK_HASH_BUILD
    desc.sink_key_dtype = KEY_DTYPE_NONE
    desc.sink_orientation = SINK_ORIENT_COLUMNAR
    desc.sink_param_id = -1
    return desc^


def build_segment(
    seg_id: Int,
    handle: Int,
    var ops: Slab[MorselOp] = Slab[MorselOp](),
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that reads resident batch `handle` and is a join's build
    side."""
    return as_build_sink(batch_segment(seg_id, handle, ops^, morsel_rows))


def key_names(a: String, b: String = "") -> List[String]:
    """A key list of one name, or of two when `b` is given."""
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def probe_op(
    build_seg: Int, probe_keys: List[String], build_keys: List[String]
) -> MorselOp:
    """An OP_JOIN_PROBE, INNER, over the rows segment `build_seg` published:
    `probe_keys[k]` of the chain's rows against `build_keys[k]` of the build
    side."""
    return MorselOp.join_probe(
        build_seg, probe_keys.copy(), build_keys.copy(), JOIN_INNER
    )


def with_build_dep(var desc: SegmentDescPod, build_seg: Int) -> SegmentDescPod:
    """`desc` depending on segment `build_seg`, with an edge that waits for it
    to publish, as a segment that probes it must."""
    desc.deps.append(build_seg)
    desc.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
    return desc^


def probe_segment(
    seg_id: Int,
    handle: Int,
    build_seg: Int,
    probe_keys: List[String],
    build_keys: List[String],
    morsel_rows: Int = 0,
) -> SegmentDescPod:
    """A segment that reads resident batch `handle`, probes the build side
    `build_seg` and collects, depending on `build_seg`."""
    var ops = chain(probe_op(build_seg, probe_keys, build_keys))
    return with_build_dep(
        batch_segment(seg_id, handle, ops^, morsel_rows), build_seg
    )


# ---- tables ---------------------------------------------------------------------


def order_custkey_null(r: Int) -> Bool:
    return r % 11 == 4


def order_custkey(r: Int) -> Int:
    return (r * 7) % 13


def customer_key_null(r: Int) -> Bool:
    return r % 7 == 3


def customer_key(r: Int) -> Int:
    return r % 10


def customer_nation_null(r: Int) -> Bool:
    return r % 6 == 5


def customer_nation(r: Int) -> Int:
    return r % 3


def tag_probe_null(r: Int) -> Bool:
    return r % 9 == 2


def tag_build_null(r: Int) -> Bool:
    return r % 4 == 3


def pair_k2_null(r: Int) -> Bool:
    return r % 8 == 5


def orders_batch(start: Int, rows: Int) raises -> RecordBatch:
    var oid = ColumnBuilder[DType.int64].with_capacity(rows)
    var key = ColumnBuilder[DType.int64].with_capacity(rows)
    var total = ColumnBuilder[DType.int64].with_capacity(rows)
    for i in range(rows):
        var r = start + i
        oid.append(Int64(r))
        if order_custkey_null(r):
            key.append_null()
        else:
            key.append(Int64(order_custkey(r)))
        total.append(Int64(r * 10 + 3))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("o_id", ArrowType.INT64, False))
    rb.add_column(oid^.materialize())
    sb.add_field(Field("o_custkey", ArrowType.INT64, True))
    rb.add_column(key^.materialize())
    sb.add_field(Field("o_total", ArrowType.INT64, False))
    rb.add_column(total^.materialize())
    return rb.build(sb.build())


def customer_batch(rows: Int) raises -> RecordBatch:
    var key = ColumnBuilder[DType.int32].with_capacity(rows)
    var names = List[String]()
    var nation = ColumnBuilder[DType.int64].with_capacity(rows)
    for r in range(rows):
        if customer_key_null(r):
            key.append_null()
        else:
            key.append(Int32(customer_key(r)))
        names.append(String("c") + String(r))
        if customer_nation_null(r):
            nation.append_null()
        else:
            nation.append(Int64(customer_nation(r)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("c_custkey", ArrowType.INT32, True))
    rb.add_column(key^.materialize())
    sb.add_field(Field("c_name", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    sb.add_field(Field("c_nation", ArrowType.INT64, True))
    rb.add_column(nation^.materialize())
    return rb.build(sb.build())


def null_key_customer_batch(rows: Int) raises -> RecordBatch:
    """The columns of `customer_batch`, with every `c_custkey` NULL (0 stored
    under each)."""
    var key = ColumnBuilder[DType.int32].with_capacity(rows)
    var names = List[String]()
    var nation = ColumnBuilder[DType.int64].with_capacity(rows)
    for r in range(rows):
        key.append_null()
        names.append(String("c") + String(r))
        nation.append(Int64(customer_nation(r)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("c_custkey", ArrowType.INT32, True))
    rb.add_column(key^.materialize())
    sb.add_field(Field("c_name", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    sb.add_field(Field("c_nation", ArrowType.INT64, False))
    rb.add_column(nation^.materialize())
    return rb.build(sb.build())


def nation_batch(rows: Int) raises -> RecordBatch:
    var key = ColumnBuilder[DType.int64].with_capacity(rows)
    var names = List[String]()
    for r in range(rows):
        key.append(Int64(r))
        names.append(String("n") + String(r))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("n_nationkey", ArrowType.INT64, False))
    rb.add_column(key^.materialize())
    sb.add_field(Field("n_name", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rb.build(sb.build())


def refund_batch(rows: Int) raises -> RecordBatch:
    var oid = ColumnBuilder[DType.int64].with_capacity(rows)
    var total = ColumnBuilder[DType.int64].with_capacity(rows)
    var reason = List[String]()
    for r in range(rows):
        oid.append(Int64(r * 2))
        total.append(Int64(r * 100))
        reason.append(String("r") + String(r % 3))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("o_id", ArrowType.INT64, False))
    rb.add_column(oid^.materialize())
    sb.add_field(Field("o_total", ArrowType.INT64, False))
    rb.add_column(total^.materialize())
    sb.add_field(Field("reason", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(reason)))
    return rb.build(sb.build())


def tag_probe_batch(start: Int, rows: Int) raises -> RecordBatch:
    var pid = ColumnBuilder[DType.int64].with_capacity(rows)
    var tags = List[String]()
    var valid = List[Bool]()
    for i in range(rows):
        var r = start + i
        pid.append(Int64(r))
        tags.append(String("t") + String(r % 5))
        valid.append(not tag_probe_null(r))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("p_id", ArrowType.INT64, False))
    rb.add_column(pid^.materialize())
    sb.add_field(Field("p_tag", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(tags, valid)
        )
    )
    return rb.build(sb.build())


def tag_build_batch(rows: Int) raises -> RecordBatch:
    var tags = List[String]()
    var valid = List[Bool]()
    var val = ColumnBuilder[DType.int64].with_capacity(rows)
    for r in range(rows):
        tags.append(String("t") + String(r % 3))
        valid.append(not tag_build_null(r))
        val.append(Int64(r * 100))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("b_tag", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(tags, valid)
        )
    )
    sb.add_field(Field("b_val", ArrowType.INT64, False))
    rb.add_column(val^.materialize())
    return rb.build(sb.build())


def float_probe_batch(rows: Int) raises -> RecordBatch:
    var fid = ColumnBuilder[DType.int64].with_capacity(rows)
    var key = ColumnBuilder[DType.float64].with_capacity(rows)
    for r in range(rows):
        fid.append(Int64(r))
        var c = r % 6
        if c == 0:
            key.append(-0.0)
        elif c == 1:
            key.append(0.0)
        elif c == 2:
            key.append(bitcast[DType.float64](UInt64(0x7FF8000000000000)))
        elif c == 3:
            key.append(1.5)
        elif c == 4:
            key.append_null()
        else:
            key.append(-1.5)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("f_id", ArrowType.INT64, False))
    rb.add_column(fid^.materialize())
    sb.add_field(Field("f_key", ArrowType.FLOAT64, True))
    rb.add_column(key^.materialize())
    return rb.build(sb.build())


def float_build_batch() raises -> RecordBatch:
    var key = ColumnBuilder[DType.float64].with_capacity(5)
    var val = ColumnBuilder[DType.int64].with_capacity(5)
    key.append(0.0)
    key.append(bitcast[DType.float64](UInt64(0x7FF8000000000123)))
    key.append(1.5)
    key.append_null()
    key.append(1.5)
    for r in range(5):
        val.append(Int64(r * 100))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("g_key", ArrowType.FLOAT64, True))
    rb.add_column(key^.materialize())
    sb.add_field(Field("g_val", ArrowType.INT64, False))
    rb.add_column(val^.materialize())
    return rb.build(sb.build())


def _pair_batch(
    rows: Int, names: List[String], payload: String, step: Int
) raises -> RecordBatch:
    var k1 = ColumnBuilder[DType.int64].with_capacity(rows)
    var k2 = ColumnBuilder[DType.int64].with_capacity(rows)
    var pv = ColumnBuilder[DType.int64].with_capacity(rows)
    for r in range(rows):
        k1.append(Int64((r * step) % 3))
        if pair_k2_null(r):
            k2.append_null()
        else:
            k2.append(Int64((r * step) % 2))
        pv.append(Int64(r))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field(names[0], ArrowType.INT64, False))
    rb.add_column(k1^.materialize())
    sb.add_field(Field(names[1], ArrowType.INT64, True))
    rb.add_column(k2^.materialize())
    sb.add_field(Field(payload, ArrowType.INT64, False))
    rb.add_column(pv^.materialize())
    return rb.build(sb.build())


def pair_probe_batch(rows: Int) raises -> RecordBatch:
    """Keys `k1` and `k2` of a probe side, payload `pv` (the row number)."""
    return _pair_batch(rows, key_names("k1", "k2"), "pv", 1)


def pair_build_batch(rows: Int) raises -> RecordBatch:
    """Keys `j1` and `j2` of a build side, payload `bv` (the row number)."""
    return _pair_batch(rows, key_names("j1", "j2"), "bv", 5)


# ---- the oracle -------------------------------------------------------------------


struct JoinTable(Movable):
    """A table as text: column names, each cell as shown, and each cell as it
    compares when it is a join key (NULL as `NULL_TEXT`, every NaN one text,
    -0.0 as 0.0)."""

    var names: List[String]
    var shown: List[List[String]]
    var keyed: List[List[String]]

    def __init__(out self):
        self.names = List[String]()
        self.shown = List[List[String]]()
        self.keyed = List[List[String]]()

    def num_rows(self) -> Int:
        return len(self.shown)

    def column(self, name: String) raises -> Int:
        for c in range(len(self.names)):
            if self.names[c] == name:
                return c
        raise Error("join_harness: no column named " + name)


def _shown(ref batch: RecordBatch, c: Int, r: Int) raises -> String:
    ref col = batch.column_at(c)
    if col.is_null_at(r):
        return String(NULL_TEXT)
    if col.arrow_type == ArrowType.INT64:
        var values = col.as_primitive[DType.int64]()
        return String(Int(values.get(r)))
    if col.arrow_type == ArrowType.INT32:
        var values = col.as_primitive[DType.int32]()
        return String(Int(values.get(r)))
    if col.arrow_type == ArrowType.FLOAT64:
        var values = col.as_primitive[DType.float64]()
        return String(values.get(r))
    if col.arrow_type == ArrowType.STRING:
        var values = col.as_string()
        return values.get(r)
    raise Error("join_harness: column " + String(c) + " has a type it cannot show")


def _keyed(ref batch: RecordBatch, c: Int, r: Int) raises -> String:
    ref col = batch.column_at(c)
    if not col.is_null_at(r) and col.arrow_type == ArrowType.FLOAT64:
        var values = col.as_primitive[DType.float64]()
        var v = values.get(r)
        if v != v:
            return String("nan")
        if v == 0.0:
            return String("0.0")
        return String(v)
    return _shown(batch, c, r)


def table_of(ref batch: RecordBatch) raises -> JoinTable:
    """`batch` read into text: INT64, INT32, FLOAT64 and STRING columns."""
    var out = JoinTable()
    for c in range(batch.num_columns()):
        out.names.append(batch.schema.field_name(c))
    for r in range(batch.num_rows()):
        var shown = List[String]()
        var keyed = List[String]()
        for c in range(batch.num_columns()):
            shown.append(_shown(batch, c, r))
            keyed.append(_keyed(batch, c, r))
        out.shown.append(shown^)
        out.keyed.append(keyed^)
    return out^


def _output_names(ref probe: JoinTable, ref build: JoinTable) -> List[String]:
    """The probe's names, then the build's, a build name the probe uses
    suffixed `_right`."""
    var names = probe.names.copy()
    for c in range(len(build.names)):
        var name = build.names[c].copy()
        var taken = False
        for p in range(len(probe.names)):
            if probe.names[p] == name:
                taken = True
        names.append(name + "_right" if taken else name)
    return names^


def oracle_join(
    ref probe: JoinTable,
    ref build: JoinTable,
    probe_keys: List[String],
    build_keys: List[String],
) raises -> JoinTable:
    """The inner equi join of `probe` and `build` by a nested loop: a pair
    joins when every key pair is non-NULL on both sides and equal."""
    var pcols = List[Int]()
    var bcols = List[Int]()
    for k in range(len(probe_keys)):
        pcols.append(probe.column(probe_keys[k]))
        bcols.append(build.column(build_keys[k]))
    var out = JoinTable()
    out.names = _output_names(probe, build)
    for p in range(probe.num_rows()):
        for b in range(build.num_rows()):
            var matched = True
            for k in range(len(pcols)):
                var pv = probe.keyed[p][pcols[k]].copy()
                var bv = build.keyed[b][bcols[k]].copy()
                if pv == NULL_TEXT or bv == NULL_TEXT or pv != bv:
                    matched = False
                    break
            if not matched:
                continue
            var shown = probe.shown[p].copy()
            shown.extend(build.shown[b].copy())
            var keyed = probe.keyed[p].copy()
            keyed.extend(build.keyed[b].copy())
            out.shown.append(shown^)
            out.keyed.append(keyed^)
    return out^


def _null_cells(n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(String(NULL_TEXT))
    return out^


def _push_row(mut out: JoinTable, var cells: List[String]):
    out.shown.append(cells.copy())
    out.keyed.append(cells^)


def _pair_matches(
    ref probe: JoinTable,
    ref build: JoinTable,
    pcols: List[Int],
    bcols: List[Int],
    p: Int,
    b: Int,
) -> Bool:
    """True when every key pair of probe row `p` and build row `b` is non-NULL
    on both sides and equal; with no key, every pair matches."""
    for k in range(len(pcols)):
        var pv = probe.keyed[p][pcols[k]].copy()
        var bv = build.keyed[b][bcols[k]].copy()
        if pv == NULL_TEXT or bv == NULL_TEXT or pv != bv:
            return False
    return True


def oracle_join_kind(
    kind: UInt8,
    ref probe: JoinTable,
    ref build: JoinTable,
    probe_keys: List[String],
    build_keys: List[String],
) raises -> JoinTable:
    """The join of `kind` of `probe` and `build` by a nested loop: matched
    pairs, probe rows without a partner padded with NULL for LEFT and FULL,
    build rows without a partner padded with NULL for RIGHT and FULL, the
    probe rows with (SEMI) or without (ANTI) a partner alone. With no key
    every pair matches (CROSS). The columns are the probe's then the build's,
    the probe's alone for SEMI and ANTI."""
    var pcols = List[Int]()
    var bcols = List[Int]()
    for k in range(len(probe_keys)):
        pcols.append(probe.column(probe_keys[k]))
        bcols.append(build.column(build_keys[k]))
    var out = JoinTable()
    if kind == JOIN_SEMI or kind == JOIN_ANTI:
        out.names = probe.names.copy()
    else:
        var inner = oracle_join(probe, build, probe_keys, build_keys)
        out.names = inner.names.copy()
    var build_matched = List[Bool](length=build.num_rows(), fill=False)
    for p in range(probe.num_rows()):
        var found = False
        for b in range(build.num_rows()):
            if not _pair_matches(probe, build, pcols, bcols, p, b):
                continue
            found = True
            build_matched[b] = True
            if kind != JOIN_SEMI and kind != JOIN_ANTI:
                var cells = probe.shown[p].copy()
                cells.extend(build.shown[b].copy())
                _push_row(out, cells^)
        if (kind == JOIN_SEMI and found) or (kind == JOIN_ANTI and not found):
            _push_row(out, probe.shown[p].copy())
        if (kind == JOIN_LEFT or kind == JOIN_FULL) and not found:
            var cells = probe.shown[p].copy()
            cells.extend(_null_cells(len(build.names)))
            _push_row(out, cells^)
    if kind == JOIN_RIGHT or kind == JOIN_FULL:
        for b in range(build.num_rows()):
            if not build_matched[b]:
                var cells = _null_cells(len(probe.names))
                cells.extend(build.shown[b].copy())
                _push_row(out, cells^)
    return out^


def select_columns(ref table: JoinTable, names: List[String]) raises -> JoinTable:
    """`table` reduced to the columns `names`, in that order."""
    var at = List[Int]()
    for i in range(len(names)):
        at.append(table.column(names[i]))
    var out = JoinTable()
    out.names = names.copy()
    for r in range(table.num_rows()):
        var shown = List[String]()
        var keyed = List[String]()
        for i in range(len(at)):
            shown.append(table.shown[r][at[i]].copy())
            keyed.append(table.keyed[r][at[i]].copy())
        out.shown.append(shown^)
        out.keyed.append(keyed^)
    return out^


def keep_rows(ref table: JoinTable, keep: List[Bool]) -> JoinTable:
    """`table` reduced to the rows whose entry of `keep` is True, in order."""
    var out = JoinTable()
    out.names = table.names.copy()
    for r in range(table.num_rows()):
        if keep[r]:
            out.shown.append(table.shown[r].copy())
            out.keyed.append(table.keyed[r].copy())
    return out^


def sorted_rows(ref table: JoinTable) -> List[String]:
    """Each row's cells joined with `|`, the rows sorted."""
    var out = List[String]()
    for r in range(table.num_rows()):
        var s = String("")
        for c in range(len(table.shown[r])):
            if c > 0:
                s += "|"
            s += table.shown[r][c]
        out.append(s^)
    sort(out)
    return out^


def rows_of(ref batch: RecordBatch) raises -> List[String]:
    """The rows of `batch` as sorted strings."""
    return sorted_rows(table_of(batch))


def expected_rows(
    ref probe: RecordBatch,
    ref build: RecordBatch,
    probe_keys: List[String],
    build_keys: List[String],
) raises -> List[String]:
    """The sorted rows of the inner join of two batches, by the oracle."""
    return sorted_rows(
        oracle_join(table_of(probe), table_of(build), probe_keys, build_keys)
    )


def expect_rows(got: List[String], want: List[String], what: String) raises:
    """Assert that two sorted row lists are equal, naming `what` and the first
    row that differs."""
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": sorted row " + String(i))
