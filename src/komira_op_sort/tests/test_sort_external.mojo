# =============================================================================
# ExternalSorter: in memory, one spilled run, several spilled runs, and a mix
# =============================================================================
#
# Cases: everything in memory (one run), one batch over the budget (one
# spilled run), several batches over the budget (several runs, merged by the
# loser tree), runs both in memory and spilled, INT64 / INT32 / FLOAT64 keys,
# ASC and DESC, equal keys keeping input order, an empty sorter, and the
# refusal of a STRING key. Spill files go under $TEST_TMPDIR (unique per test
# execution), never a fixed path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_libc.posix import _read_env
from komira_op_sort.sort_external import ExternalSorter


def _scratch_dir() raises -> String:
    """The directory this execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _batch_i64(var values: List[Int64], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].from_list(values^)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_i32(var values: List[Int32], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int32].from_list(values^)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT32, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_f64(var values: List[Float64], name: String) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].from_list(values^)
    var col = Column.from_primitive(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_str(var values: List[String], name: String) raises -> RecordBatch:
    var arr = StringArray.from_strings(values^)
    var col = Column.from_string(arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema^)


def _batch_i64_pair(
    var keys: List[Int64], var vals: List[Int64],
    k_name: String, v_name: String,
) raises -> RecordBatch:
    var k_arr = PrimitiveArray[DType.int64].from_list(keys^)
    var v_arr = PrimitiveArray[DType.int64].from_list(vals^)
    var k_col = Column.from_primitive(k_arr)
    var v_col = Column.from_primitive(v_arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(k_name, ArrowType.INT64, False))
    sb.add_field(Field(v_name, ArrowType.INT64, False))
    var schema = sb.build()
    var b = RecordBatchBuilder()
    b.add_column(k_col^)
    b.add_column(v_col^)
    return b.build(schema^)


def _key_names(name: String) -> List[String]:
    var k = List[String]()
    k.append(name)
    return k^


def _desc(d: Bool) -> List[Bool]:
    var r = List[Bool]()
    r.append(d)
    return r^


def _flatten_int64_col(
    ref out_batches: Slab[RecordBatch], col_name: String
) raises -> List[Int64]:
    """Concatenate the named INT64 column across output batches into a List."""
    var out = List[Int64]()
    for i in range(len(out_batches)):
        ref b = out_batches[i]
        var idx = b.schema.column_index(col_name)
        ref col = b.column_at(idx)
        var arr = col.as_primitive[DType.int64]()
        for r in range(b.num_rows()):
            out.append(arr.get(r))
    return out^


def _flatten_int32_col(
    ref out_batches: Slab[RecordBatch], col_name: String
) raises -> List[Int32]:
    var out = List[Int32]()
    for i in range(len(out_batches)):
        ref b = out_batches[i]
        var idx = b.schema.column_index(col_name)
        ref col = b.column_at(idx)
        var arr = col.as_primitive[DType.int32]()
        for r in range(b.num_rows()):
            out.append(arr.get(r))
    return out^


def _flatten_f64_col(
    ref out_batches: Slab[RecordBatch], col_name: String
) raises -> List[Float64]:
    var out = List[Float64]()
    for i in range(len(out_batches)):
        ref b = out_batches[i]
        var idx = b.schema.column_index(col_name)
        ref col = b.column_at(idx)
        var arr = col.as_primitive[DType.float64]()
        for r in range(b.num_rows()):
            out.append(arr.get(r))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_in_memory_single_batch() raises:
    """Single batch absorbed under unlimited memory budget; output sorted."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var v = List[Int64]()
    v.append(Int64(3)); v.append(Int64(1)); v.append(Int64(2))
    s.absorb(_batch_i64(v^, "k"))
    var out = s^.finish()
    var values = _flatten_int64_col(out, "k")
    assert_equal(len(values), 3)
    assert_equal(values[0], Int64(1))
    assert_equal(values[1], Int64(2))
    assert_equal(values[2], Int64(3))


def test_in_memory_multi_batch() raises:
    """Multiple batches absorbed under unlimited budget; cross-batch merge."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var a = List[Int64](); a.append(Int64(5)); a.append(Int64(2))
    var b = List[Int64](); b.append(Int64(6)); b.append(Int64(1))
    var c = List[Int64](); c.append(Int64(4)); c.append(Int64(3))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    s.absorb(_batch_i64(c^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    assert_equal(len(v), 6)
    for i in range(6):
        assert_equal(v[i], Int64(i + 1))


def test_descending() raises:
    """Descending sort over multiple batches."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(True),
    )
    var a = List[Int64](); a.append(Int64(1)); a.append(Int64(4))
    var b = List[Int64](); b.append(Int64(2)); b.append(Int64(3))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    assert_equal(len(v), 4)
    assert_equal(v[0], Int64(4))
    assert_equal(v[1], Int64(3))
    assert_equal(v[2], Int64(2))
    assert_equal(v[3], Int64(1))


def test_int32_dtype() raises:
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var a = List[Int32](); a.append(Int32(8)); a.append(Int32(3)); a.append(Int32(5))
    var b = List[Int32](); b.append(Int32(1)); b.append(Int32(4))
    s.absorb(_batch_i32(a^, "k"))
    s.absorb(_batch_i32(b^, "k"))
    var out = s^.finish()
    var v = _flatten_int32_col(out, "k")
    assert_equal(len(v), 5)
    assert_equal(v[0], Int32(1))
    assert_equal(v[1], Int32(3))
    assert_equal(v[2], Int32(4))
    assert_equal(v[3], Int32(5))
    assert_equal(v[4], Int32(8))


def test_float64_dtype() raises:
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var a = List[Float64](); a.append(2.5); a.append(1.5); a.append(3.5)
    s.absorb(_batch_f64(a^, "k"))
    var out = s^.finish()
    var v = _flatten_f64_col(out, "k")
    assert_equal(len(v), 3)
    assert_true(v[0] == 1.5)
    assert_true(v[1] == 2.5)
    assert_true(v[2] == 3.5)


def test_forced_single_spill() raises:
    """Force a single spill via a tiny budget, then merge in-memory + spilled."""
    var s = ExternalSorter.create(
        memory_budget=1,
        key_names=_key_names("k"),
        descending=_desc(False),
        spill_dir=(_scratch_dir() + String("/sort_external_spill_a")),
    )
    var a = List[Int64](); a.append(Int64(9)); a.append(Int64(2)); a.append(Int64(7))
    var b = List[Int64](); b.append(Int64(4)); b.append(Int64(1)); b.append(Int64(8))
    var c = List[Int64](); c.append(Int64(3)); c.append(Int64(5)); c.append(Int64(6))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    s.absorb(_batch_i64(c^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    assert_equal(len(v), 9)
    for i in range(9):
        assert_equal(v[i], Int64(i + 1))


def test_multi_run_spill() raises:
    """Several spills + a final in-memory tail."""
    var s = ExternalSorter.create(
        memory_budget=1,
        key_names=_key_names("k"),
        descending=_desc(False),
        spill_dir=(_scratch_dir() + String("/sort_external_spill_b")),
    )
    var a = List[Int64](); a.append(Int64(50)); a.append(Int64(10))
    var b = List[Int64](); b.append(Int64(30)); b.append(Int64(20))
    var c = List[Int64](); c.append(Int64(40)); c.append(Int64(60))
    var d = List[Int64](); d.append(Int64(70)); d.append(Int64(5))
    var e = List[Int64](); e.append(Int64(80)); e.append(Int64(15))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    s.absorb(_batch_i64(c^, "k"))
    s.absorb(_batch_i64(d^, "k"))
    s.absorb(_batch_i64(e^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    var exp = List[Int64]()
    exp.append(Int64(5)); exp.append(Int64(10)); exp.append(Int64(15))
    exp.append(Int64(20)); exp.append(Int64(30)); exp.append(Int64(40))
    exp.append(Int64(50)); exp.append(Int64(60)); exp.append(Int64(70))
    exp.append(Int64(80))
    assert_equal(len(v), len(exp))
    for i in range(len(exp)):
        assert_equal(v[i], exp[i])


def test_descending_with_spill() raises:
    """Descending sort with forced spilling — ensures _cmp + descending flag
    flow correctly through the cross-run merge."""
    var s = ExternalSorter.create(
        memory_budget=1,
        key_names=_key_names("k"),
        descending=_desc(True),
        spill_dir=(_scratch_dir() + String("/sort_external_spill_d")),
    )
    var a = List[Int64](); a.append(Int64(1)); a.append(Int64(4))
    var b = List[Int64](); b.append(Int64(2)); b.append(Int64(3))
    var c = List[Int64](); c.append(Int64(7)); c.append(Int64(5))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    s.absorb(_batch_i64(c^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    assert_equal(len(v), 6)
    assert_equal(v[0], Int64(7))
    assert_equal(v[1], Int64(5))
    assert_equal(v[2], Int64(4))
    assert_equal(v[3], Int64(3))
    assert_equal(v[4], Int64(2))
    assert_equal(v[5], Int64(1))


def test_stability_on_equal_keys() raises:
    """Equal keys must preserve insertion order."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var k1 = List[Int64](); k1.append(Int64(1)); k1.append(Int64(1)); k1.append(Int64(1))
    var v1 = List[Int64](); v1.append(Int64(10)); v1.append(Int64(20)); v1.append(Int64(30))
    var k2 = List[Int64](); k2.append(Int64(1)); k2.append(Int64(1))
    var v2 = List[Int64](); v2.append(Int64(40)); v2.append(Int64(50))
    s.absorb(_batch_i64_pair(k1^, v1^, "k", "v"))
    s.absorb(_batch_i64_pair(k2^, v2^, "k", "v"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "v")
    assert_equal(len(v), 5)
    assert_equal(v[0], Int64(10))
    assert_equal(v[1], Int64(20))
    assert_equal(v[2], Int64(30))
    assert_equal(v[3], Int64(40))
    assert_equal(v[4], Int64(50))


def test_empty_sorter() raises:
    """No batches absorbed -> empty output."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var out = s^.finish()
    assert_equal(len(out), 0)


def test_mixed_in_memory_and_spilled() raises:
    var s = ExternalSorter.create(
        memory_budget=1,
        key_names=_key_names("k"),
        descending=_desc(False),
        spill_dir=(_scratch_dir() + String("/sort_external_spill_c")),
    )
    var a = List[Int64](); a.append(Int64(100)); a.append(Int64(50))
    var b = List[Int64](); b.append(Int64(75)); b.append(Int64(25))
    var c = List[Int64](); c.append(Int64(60)); c.append(Int64(40))
    s.absorb(_batch_i64(a^, "k"))
    s.absorb(_batch_i64(b^, "k"))
    s.absorb(_batch_i64(c^, "k"))
    var out = s^.finish()
    var v = _flatten_int64_col(out, "k")
    var exp = List[Int64]()
    exp.append(Int64(25)); exp.append(Int64(40)); exp.append(Int64(50))
    exp.append(Int64(60)); exp.append(Int64(75)); exp.append(Int64(100))
    assert_equal(len(v), len(exp))
    for i in range(len(exp)):
        assert_equal(v[i], exp[i])


# =============================================================================
# Main
# =============================================================================


def test_string_key_refused() raises:
    """A STRING key is refused on the first batch, by name."""
    var s = ExternalSorter.create(
        memory_budget=0,
        key_names=_key_names("k"),
        descending=_desc(False),
    )
    var v: List[String] = ["b", "a"]
    var refused = False
    try:
        s.absorb(_batch_str(v^, "k"))
    except e:
        refused = "unsupported sort key dtype" in String(e)
    assert_true(refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
