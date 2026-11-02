# `MultiKeyJoinProbeOp`, the composite-key streaming INNER probe, against two
# independent answers:
#   1. RESIDENT: the whole-batch join (extract -> `probe_inner_into` ->
#      `assemble_join_result`), which the operator runs per morsel; the union
#      of its per-morsel outputs must be the same multiset of rows.
#   2. BRUTE FORCE: a nested-loop join with plain equality and no hashing,
#      written here. The operator shares its hash and equality with the
#      resident join, so only this answer can see a wrong match the two share
#      (a hash collision taken for a match).
# Every fixture runs at morsel sizes 1, 3 and whole. The matrix: two INT64
# keys with fan-out, the key order swapped, STRING keys, INT64 + STRING, one
# and three keys through one operator type, NULL keys of STRING and INT64
# type (a NULL matches nothing), an empty build side, and two collision-dense
# fixtures, which assert that two distinct keys really share a bucket.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_join_assembly.compiler_join_assembly import assemble_join_result
from komira_morsel.morsel import Morsel, split_record_batch
from komira_plan_ir.logical_plan import JOIN_INNER

from komira_op_join_probe.join_key_extract import extract_join_key_columns_serial
from komira_op_join_probe.join_multi_key import _composite_hash_int64
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp


comptime NULL_I: Int = -999
"""An INT64 entry written as NULL (its slot holds 0)."""


def _int_col(values: List[Int]) raises -> Column[HeapRegion]:
    var any_null = False
    for v in values:
        if v == NULL_I:
            any_null = True
    var arr = PrimitiveArray[DType.int64].allocate_nullable(
        len(values)
    ) if any_null else PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr._typed_ptr_mut()[i] = Int64(0) if values[i] == NULL_I else Int64(values[i])
        if values[i] == NULL_I:
            arr._set_null(i)
    return Column.from_primitive(arr^)


def _str_col(values: List[String], valid: List[Bool] = List[Bool]()) raises -> Column[HeapRegion]:
    if len(valid) == 0:
        return Column.from_string(StringArray.from_strings(values))
    return Column.from_string(StringArray.from_strings_with_validity(values, valid))


struct _Batch(Movable):
    """A fixture under construction: named columns of INT64 or STRING."""

    var sb: SchemaBuilder
    var rb: RecordBatchBuilder

    def __init__(out self):
        self.sb = SchemaBuilder()
        self.rb = RecordBatchBuilder()

    def ints(mut self, name: String, values: List[Int]) raises:
        self.sb.add_field(Field(name, ArrowType.INT64, True))
        self.rb.add_column(_int_col(values))

    def strs(mut self, name: String, values: List[String], valid: List[Bool] = List[Bool]()) raises:
        self.sb.add_field(Field(name, ArrowType.STRING, True))
        self.rb.add_column(_str_col(values, valid))

    def done(mut self) raises -> RecordBatch:
        return self.rb.build(self.sb.build())


def _cell(imm col: Column[HeapRegion], r: Int) raises -> String:
    """One cell as text; NULL as `<null>`."""
    if col.arrow_type == ArrowType.INT64:
        var a = col.as_primitive[DType.int64]()
        return String("<null>") if a.is_null(r) else String(Int(a.get(r)))
    var s = col.as_string()
    return String("<null>") if s.is_null(r) else s.get(r)


def _rows(imm batch: RecordBatch) raises -> List[String]:
    """Each row's cells joined with `|`, in row order."""
    var out = List[String]()
    for r in range(batch.num_rows()):
        var s = String("")
        for c in range(batch.num_columns()):
            if c > 0:
                s += "|"
            s += _cell(batch.column_at(c), r)
        out.append(s)
    return out^


def _assert_same_multiset(var a: List[String], var b: List[String], ctx: String) raises:
    assert_equal(len(a), len(b), ctx + ": row count")
    sort(a)
    sort(b)
    for i in range(len(a)):
        assert_equal(a[i], b[i], ctx + ": sorted row " + String(i))


def _out_schema(imm probe: RecordBatch, imm build: RecordBatch) raises -> Schema:
    """Probe columns `p_*` then build columns `b_*`."""
    var sb = SchemaBuilder()
    for c in range(probe.num_columns()):
        sb.add_field(Field("p_" + probe.schema.field_name(c), probe.schema.field_arrow_type(c), True))
    for c in range(build.num_columns()):
        sb.add_field(Field("b_" + build.schema.field_name(c), build.schema.field_arrow_type(c), True))
    return sb.build()


def _resident(imm probe: RecordBatch, imm build: RecordBatch, keys: List[String]) raises -> List[String]:
    var builder = MultiKeyHashJoinBuilder.build(extract_join_key_columns_serial(build, keys))
    var pkeys = extract_join_key_columns_serial(probe, keys)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(pkeys, bm, pm)
    return _rows(assemble_join_result(probe, build, pm^, bm^, _out_schema(probe, build)))


def _brute(imm probe: RecordBatch, imm build: RecordBatch, keys: List[String]) raises -> List[String]:
    """Nested loop: a pair matches iff every key is non-NULL on both sides
    and the two cells are equal as text."""
    var prow = _rows(probe)
    var brow = _rows(build)
    var out = List[String]()
    for pi in range(probe.num_rows()):
        for bi in range(build.num_rows()):
            var matched = True
            for k in range(len(keys)):
                var pv = _cell(probe.column_at(probe.schema.column_index(keys[k])), pi)
                var bv = _cell(build.column_at(build.schema.column_index(keys[k])), bi)
                if pv == "<null>" or bv == "<null>" or pv != bv:
                    matched = False
                    break
            if matched:
                out.append(prow[pi] + "|" + brow[bi])
    return out^


def _streaming(var probe: RecordBatch, var build: RecordBatch, keys: List[String], morsel: Int) raises -> List[String]:
    """The operator over `probe` cut into `morsel`-row morsels."""
    var schema = _out_schema(probe, build)
    var builder = MultiKeyHashJoinBuilder.build(extract_join_key_columns_serial(build, keys))
    var op = MultiKeyJoinProbeOp(
        ArcPointer[MultiKeyHashJoinBuilder](builder^),
        ArcPointer[RecordBatch](build^),
        keys.copy(),
        keys.copy(),
        ArcPointer[Schema](schema^),
        JOIN_INNER,
    )
    var morsels = split_record_batch(probe^, morsel)
    var slab = Slab[Morsel]()
    morsels.drain_morsels_into(slab)
    var out = List[String]()
    for i in range(len(slab)):
        _ = op.execute(slab[i])
        out.extend(_rows(slab[i].batch))
    return out^


def _q5_probe() raises -> RecordBatch:
    var b = _Batch()
    b.ints("ok", [1, 2, 2, 3, 9, 1])
    b.ints("sk", [1, 2, 9, 3, 9, 1])
    b.ints("pp", [10, 20, 30, 40, 50, 60])
    return b.done()


def _q5_build() raises -> RecordBatch:
    var b = _Batch()
    b.ints("ok", [1, 1, 2, 2, 3, 1])
    b.ints("sk", [1, 2, 1, 2, 3, 1])
    b.ints("bp", [100, 101, 102, 103, 104, 105])
    return b.done()


def test_two_int64_keys_with_fanout() raises:
    _check("2key", ["ok", "sk"], _Q5)


def test_key_order_swapped() raises:
    _check("swapped", ["sk", "ok"], _Q5)


def _str_probe() raises -> RecordBatch:
    var b = _Batch()
    b.strs("c", ["US", "DE", "FR", "JP", "US"])
    b.strs("cur", ["USD", "USD", "EUR", "JPY", "USD"])
    b.strs("pp", ["q0", "q1", "q2", "q3", "q4"])
    return b.done()


def _str_build() raises -> RecordBatch:
    var b = _Batch()
    b.strs("c", ["US", "DE", "JP", "US"])
    b.strs("cur", ["USD", "EUR", "JPY", "USD"])
    b.strs("bp", ["b0", "b1", "b2", "b3"])
    return b.done()


def test_string_keys() raises:
    _check("strings", ["c", "cur"], _STR)


def _mixed_probe() raises -> RecordBatch:
    var b = _Batch()
    b.strs("name", ["alice", "alice", "bob", "zoe", "alice"])
    b.ints("id", [1, 2, 2, 0, 1])
    b.ints("pay", [10, 20, 30, 40, 50])
    return b.done()


def _mixed_build() raises -> RecordBatch:
    var b = _Batch()
    b.strs("name", ["alice", "bob", "carol", "alice"])
    b.ints("id", [1, 2, 3, 2])
    b.ints("pay", [100, 101, 102, 103])
    return b.done()


def test_int64_and_string_keys() raises:
    _check("mixed", ["name", "id"], _MIXED)


def _one_probe() raises -> RecordBatch:
    var b = _Batch()
    b.ints("k", [1, 2, 9, 3])
    b.ints("pp", [10, 20, 30, 40])
    return b.done()


def _one_build() raises -> RecordBatch:
    var b = _Batch()
    b.ints("k", [1, 2, 3, 2])
    b.ints("bp", [100, 101, 102, 103])
    return b.done()


def _three_probe() raises -> RecordBatch:
    var b = _Batch()
    b.ints("a", [1, 1, 2, 1, 9])
    b.strs("b", ["x", "y", "x", "x", "x"])
    b.ints("c", [7, 7, 7, 8, 7])
    b.ints("pay", [11, 12, 13, 14, 15])
    return b.done()


def _three_build() raises -> RecordBatch:
    var b = _Batch()
    b.ints("a", [1, 1, 2, 1])
    b.strs("b", ["x", "y", "x", "x"])
    b.ints("c", [7, 7, 7, 8])
    b.ints("pay", [200, 201, 202, 203])
    return b.done()


def test_one_and_three_keys() raises:
    _check("arity1", ["k"], _ONE)
    _check("arity3", ["a", "b", "c"], _THREE)


def _null_probe() raises -> RecordBatch:
    """Row 0: NULL `a`; row 1: NULL `b`; row 2: (a, x), the one match; row
    3: NULL INT64 `n` whose slot holds 0; row 4: (b, y) with n = 0."""
    var b = _Batch()
    b.strs("a", ["a", "a", "a", "b", "b"], [False, True, True, True, True])
    b.strs("b", ["x", "x", "x", "y", "y"], [True, False, True, True, True])
    b.ints("n", [5, 5, 5, NULL_I, 0])
    b.strs("pp", ["n0", "n1", "match", "n3", "zero"])
    return b.done()


def _null_build() raises -> RecordBatch:
    var b = _Batch()
    b.strs("a", ["a", "b"])
    b.strs("b", ["x", "y"])
    b.ints("n", [5, 0])
    b.strs("bp", ["b0", "b1"])
    return b.done()


def test_null_keys_match_nothing() raises:
    var keys: List[String] = ["a", "b", "n"]
    _check("nulls", keys, _NULLS)
    _assert_same_multiset(
        _streaming(_null_probe(), _null_build(), keys, 2),
        ["a|x|5|match|a|x|5|b0", "b|y|0|zero|b|y|0|b1"],
        "exactly the two non-NULL matches",
    )


def _empty_build() raises -> RecordBatch:
    var b = _Batch()
    b.ints("ok", List[Int]())
    b.ints("sk", List[Int]())
    b.ints("bp", List[Int]())
    return b.done()


def test_empty_build() raises:
    assert_equal(len(_resident(_q5_probe(), _empty_build(), ["ok", "sk"])), 0)
    assert_equal(len(_streaming(_q5_probe(), _empty_build(), ["ok", "sk"], 2)), 0)


def _collide_build() raises -> RecordBatch:
    """200 keys (i, 7i + 1), and (5, 36) once more: fan-out."""
    var ok = List[Int]()
    var sk = List[Int]()
    var bp = List[Int]()
    for i in range(200):
        ok.append(i)
        sk.append(i * 7 + 1)
        bp.append(1000 + i)
    ok.append(5)
    sk.append(36)
    bp.append(9999)
    var b = _Batch()
    b.ints("ok", ok)
    b.ints("sk", sk)
    b.ints("bp", bp)
    return b.done()


def _collide_probe() raises -> RecordBatch:
    """The 200 build keys, then 50 keys the build side does not have."""
    var ok = List[Int]()
    var sk = List[Int]()
    var pp = List[Int]()
    for i in range(200):
        ok.append(i)
        sk.append(i * 7 + 1)
        pp.append(i)
    for i in range(50):
        ok.append(1000 + i)
        sk.append(2000 + i)
        pp.append(5000 + i)
    var b = _Batch()
    b.ints("ok", ok)
    b.ints("sk", sk)
    b.ints("pp", pp)
    return b.done()


def _bucket(a: Int64, b: Int64, cap: Int) -> Int:
    var buf: List[Int64] = [a, b]
    var h = _composite_hash_int64(buf.unsafe_ptr(), 2)
    _ = buf
    return Int(h & UInt64(cap - 1))


def test_colliding_int64_keys() raises:
    """At least one bucket of the build's table holds two distinct keys
    (the table's capacity: the power of two at or above 1.4 x 201 rows, so
    512), so the chain walk's equality check is exercised."""
    var cap = 512
    var seen = List[Int](length=cap, fill=-1)
    var collisions = 0
    for i in range(200):
        var bk = _bucket(Int64(i), Int64(i * 7 + 1), cap)
        if seen[bk] >= 0:
            collisions += 1
        seen[bk] = i
    assert_true(collisions >= 1, "no two distinct keys share a bucket")
    _check("collide", ["ok", "sk"], _COLLIDE)


def _xd_build() raises -> RecordBatch:
    """Every (i, s) for i in 0..15, s in aa..hh."""
    var iv = List[Int]()
    var sv = List[String]()
    var pay = List[Int]()
    var alpha: List[String] = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh"]
    for i in range(16):
        for s in range(len(alpha)):
            iv.append(i)
            sv.append(alpha[s])
            pay.append(1000 + i * 8 + s)
    var b = _Batch()
    b.ints("i", iv)
    b.strs("s", sv)
    b.ints("pay", pay)
    return b.done()


def _xd_probe() raises -> RecordBatch:
    """The build's keys, then seen integers with an unseen string, then an
    unseen integer with seen strings."""
    var iv = List[Int]()
    var sv = List[String]()
    var pay = List[Int]()
    var alpha: List[String] = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh"]
    for i in range(16):
        for s in range(len(alpha)):
            iv.append(i)
            sv.append(alpha[s])
            pay.append(i * 8 + s)
    for i in range(16):
        iv.append(i)
        sv.append("ZZ")
        pay.append(9000 + i)
    for s in range(len(alpha)):
        iv.append(999)
        sv.append(alpha[s])
        pay.append(8000 + s)
    var b = _Batch()
    b.ints("i", iv)
    b.strs("s", sv)
    b.ints("pay", pay)
    return b.done()


def test_cross_type_keys_dense() raises:
    _check("cross-type", ["i", "s"], _XD)


comptime _Q5 = 0
comptime _STR = 1
comptime _MIXED = 2
comptime _ONE = 3
comptime _THREE = 4
comptime _NULLS = 5
comptime _COLLIDE = 6
comptime _XD = 7


def _fixture(which: Int, probe: Bool) raises -> RecordBatch:
    """Fixture `which`, its probe side or its build side."""
    if which == _Q5:
        return _q5_probe() if probe else _q5_build()
    if which == _STR:
        return _str_probe() if probe else _str_build()
    if which == _MIXED:
        return _mixed_probe() if probe else _mixed_build()
    if which == _ONE:
        return _one_probe() if probe else _one_build()
    if which == _THREE:
        return _three_probe() if probe else _three_build()
    if which == _NULLS:
        return _null_probe() if probe else _null_build()
    if which == _COLLIDE:
        return _collide_probe() if probe else _collide_build()
    return _xd_probe() if probe else _xd_build()


def _check(ctx: String, keys: List[String], which: Int) raises:
    """resident == brute force, and the operator at morsels 1, 3 and whole
    equals both."""
    var resident = _resident(_fixture(which, True), _fixture(which, False), keys)
    var brute = _brute(_fixture(which, True), _fixture(which, False), keys)
    _assert_same_multiset(resident.copy(), brute.copy(), ctx + " resident==brute")
    for ms in [1, 3, 100_000]:
        _assert_same_multiset(
            _streaming(_fixture(which, True), _fixture(which, False), keys, ms),
            brute.copy(),
            ctx + " operator (morsel " + String(ms) + ")==brute",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
