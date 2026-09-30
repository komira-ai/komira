# =============================================================================
# test_assemble_join_gather_parallel_param.mojo — the join assemble's
# `gather_parallel_min_rows` parameter drives EVERY output column
# =============================================================================
#
# The parallel gather is chosen per column by a row threshold the caller
# passes (`gather_parallel_min_rows`, default `GATHER_PARALLEL_MIN_ROWS`), not
# by a process-global switch. This suite runs the same multi-column
# `assemble_join_result` twice in ONE process — once with the threshold at 1
# (every column eligible for the parallel arm) and once at
# `GATHER_SERIAL_ONLY` (no column reaches it) — and asserts the two results
# are byte-identical on every output column. The parameter is forwarded per
# column, so a column that ignored it would show up here as a divergence.
#
# Encapsulation: public surfaces only; no UnsafePointer, no wildcard origin,
# no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.helpers.compiler_helpers import GATHER_SERIAL_ONLY
from komira_core.helpers.compiler_join_assembly import assemble_join_result


def _build_str_i64_batch(
    s_name: String,
    i_name: String,
    var keys: List[String],
    var vals: List[Scalar[DType.int64]],
) raises -> RecordBatch:
    var sa = StringArray.from_strings(keys^)
    var ck = Column.from_string(sa^)
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var ci = Column.from_primitive[DType.int64](arr^)
    var schema = Schema.from_fields_2(
        Field(s_name, ArrowType.STRING, True),
        Field(i_name, DType.int64, True),
    )
    return RecordBatch.from_typed_columns_2(schema^, ck^, ci^)


def _side(prefix: String, s_name: String, i_name: String) raises -> RecordBatch:
    var n = 200
    var keys = List[String](capacity=n)
    var vals = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        var rep = i % 21
        var s = prefix
        for _ in range(rep):
            s += chr(ord("a") + (i % 26))
        keys.append(s)
        vals.append(Int64(i * 3 - 7))
    return _build_str_i64_batch(s_name, i_name, keys^, vals^)


def _out_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s_l", ArrowType.STRING, True))
    sb.add_field(Field("i_l", DType.int64, True))
    sb.add_field(Field("s_r", ArrowType.STRING, True))
    sb.add_field(Field("i_r", DType.int64, True))
    return sb.build()


def _scatter(n: Int, src_n: Int) -> List[Int]:
    var idx = List[Int](capacity=n)
    for i in range(n):
        idx.append(src_n - 1 - ((i * 7) % src_n))
    return idx^


def _string_at(imm batch: RecordBatch, col: Int, row: Int) raises -> String:
    ref c = batch.column_at(col)
    var offs = c._offsets.value().view_ro()
    var data = c._data.view_ro()
    var o = c._offset + row
    var start = Int(offs.get_typed[Int32](o))
    var end = Int(offs.get_typed[Int32](o + 1))
    var out = String("")
    for i in range(start, end):
        out += chr(Int(data.get_typed[UInt8](i)))
    return out


def test_assemble_join_gather_param_matches_serial() raises:
    """A 4-column (2 string + 2 int64) INNER-join assemble: the run with
    `gather_parallel_min_rows=1` must equal the run with
    `gather_parallel_min_rows=GATHER_SERIAL_ONLY` (the serial reference),
    proving the parameter correctly drives EVERY output column."""
    var n = 256
    var li = _scatter(n, 200)
    var ri = _scatter(n, 200)
    var out_schema = _out_schema()

    # Serial reference: a threshold no gather reaches.
    var l_ser = _side("L", "s_l", "i_l")
    var r_ser = _side("R", "s_r", "i_r")
    var ser = assemble_join_result(
        l_ser,
        r_ser,
        li.copy(),
        ri.copy(),
        out_schema,
        gather_parallel_min_rows=GATHER_SERIAL_ONLY,
    )

    # Every column eligible for the parallel arm.
    var l_par = _side("L", "s_l", "i_l")
    var r_par = _side("R", "s_r", "i_r")
    var par = assemble_join_result(
        l_par, r_par, li^, ri^, out_schema, gather_parallel_min_rows=1
    )

    assert_equal(par.num_columns(), 4)
    assert_equal(par.num_rows(), ser.num_rows())
    # Spot-check every column type on both sides.
    for r in range(par.num_rows()):
        assert_equal(_string_at(par, 0, r), _string_at(ser, 0, r))
        assert_equal(_string_at(par, 2, r), _string_at(ser, 2, r))
    var pi1 = par.column_at(1).as_primitive[DType.int64]()
    var si1 = ser.column_at(1).as_primitive[DType.int64]()
    var pi3 = par.column_at(3).as_primitive[DType.int64]()
    var si3 = ser.column_at(3).as_primitive[DType.int64]()
    assert_equal(pi1.length, si1.length)
    for i in range(pi1.length):
        assert_equal(
            Int(pi1.get_typed[Scalar[DType.int64]](i)),
            Int(si1.get_typed[Scalar[DType.int64]](i)),
        )
        assert_equal(
            Int(pi3.get_typed[Scalar[DType.int64]](i)),
            Int(si3.get_typed[Scalar[DType.int64]](i)),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
