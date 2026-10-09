# =============================================================================
# CsvSink: the exact text written for every column type it supports.
# =============================================================================
#
# test_csv_sink_quoting pins the quoting of STRING cells; nothing pinned the
# other arms of `_format_column_cells_packed`. One three-row batch holds one
# column per arm (and, for INT64, FLOAT64 and LARGE_STRING, a second column
# without nulls, since those arms branch on it), row 1 null wherever the
# column is nullable, and the whole file is compared byte for byte against
# the value encoding stated in csv_sink.mojo's header (`String(value)` for
# numbers, `true`/`false`, the empty field for null, RFC 4180 quoting). The
# header row carries a name with a quote, one with a line feed and one with
# the delimiter, the three header quoting triggers.
#
# Mutants planted (each red, see the PR body): drop the `\n` trigger from the
# header check, write a null INT16 or FLOAT16 cell as its zero value, write
# `true` as `frue`, drop the dictionary index-null check, drop the
# multi-column format-error raise.
# =============================================================================

from std.io import FileHandle
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_csv.csv_sink import CsvSink
from komira_runtime_paths import test_tmpdir


def _nullable[dt: DType](a: Scalar[dt], c: Scalar[dt]) raises -> Column[HeapRegion]:
    """Three rows `a, NULL, c`."""
    var arr = PrimitiveArray[dt].allocate_nullable(3)
    arr.set(0, a)
    arr.set(2, c)
    arr.validity.value().clear(1)
    arr.null_count = 1
    return Column.from_primitive[dt](arr)


def _dense[dt: DType](a: Scalar[dt], b: Scalar[dt], c: Scalar[dt]) -> Column[HeapRegion]:
    var vals = List[Scalar[dt]]()
    vals.append(a)
    vals.append(b)
    vals.append(c)
    return Column.from_primitive[dt](PrimitiveArray[dt].from_list(vals))


def _strs(a: String, b: String, c: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _mid_null() -> List[Bool]:
    var v = List[Bool]()
    v.append(True)
    v.append(False)
    v.append(True)
    return v^


struct _Cols(Movable):
    """Accumulates (name, column) pairs into a schema and a batch builder."""

    var sb: SchemaBuilder
    var b: RecordBatchBuilder

    def __init__(out self):
        self.sb = SchemaBuilder()
        self.b = RecordBatchBuilder()

    def add(mut self, name: String, var col: Column[HeapRegion]):
        self.sb.add_field(Field(name, col.arrow_type, True))
        self.b.add_column(col^)

    def batch(mut self) raises -> RecordBatch:
        return self.b.build(self.sb.build())


def _write(name: String, var rb: RecordBatch) raises -> String:
    var sink = CsvSink(test_tmpdir() + "/" + name)
    var path = sink.path
    sink.init_sink(rb.schema.copy())
    sink.accept_batch(rb^)
    sink.finish()
    var f = FileHandle(path, "r")
    var text = f.read()
    f.close()
    return text^


def test_every_supported_column_type() raises:
    var c = _Cols()
    c.add('q"x', _dense[DType.int64](1, -2, 3))
    c.add("l\nf", _nullable[DType.int64](7, -9))
    c.add("c,m", _dense[DType.int32](10, 20, -30))
    c.add("i32n", _nullable[DType.int32](-1, 2))
    c.add("i16n", _nullable[DType.int16](300, -300))
    c.add("i8n", _nullable[DType.int8](5, -5))
    c.add("u64n", _nullable[DType.uint64](UInt64.MAX, 0))
    c.add("u32n", _nullable[DType.uint32](4000000000, 1))
    c.add("u16n", _nullable[DType.uint16](65535, 2))
    c.add("u8n", _nullable[DType.uint8](255, 3))
    c.add("f64", _dense[DType.float64](2.5, -0.5, 4.0))
    c.add("f64n", _nullable[DType.float64](1.25, 8.0))
    c.add("f32n", _nullable[DType.float32](-1.5, 0.5))
    c.add("f16n", _nullable[DType.float16](1.5, -2.0))

    var bo = BooleanArray.allocate_nullable(3)
    bo.set(0, True)
    bo._set_null(1)
    bo.set(2, False)
    c.add("b", Column.from_boolean(bo))

    c.add(
        "ls",
        Column.from_large_string(LargeStringArray.from_strings(_strs("a", "b,c", "d"))),
    )
    c.add(
        "lsn",
        Column.from_large_string(
            LargeStringArray.from_strings_with_validity(
                _strs("x", "", 'q"q'), _mid_null()
            )
        ),
    )
    c.add(
        "sn",
        Column.from_string(
            StringArray.from_strings_with_validity(_strs("s", "", "t"), _mid_null())
        ),
    )

    var idx = PrimitiveArray[DType.int32].allocate_nullable(3)
    idx.set(0, 1)
    idx.set(2, 0)
    idx.validity.value().clear(1)
    idx.null_count = 1
    var dict_vals = List[String]()
    dict_vals.append("p")
    dict_vals.append("q")
    c.add(
        "dict",
        Column.from_dictionary(
            StringDictionaryArray.from_parts(idx^, StringArray.from_strings(dict_vals))
        ),
    )

    var codes = PrimitiveArray[DType.int32].from_list([0, 1, 0])
    var values: List[Int64] = [100, -5]
    c.add("nd", Column.from_numeric_dict[DType.int32, DType.int64](codes^, values^))

    var dec = Decimal128Array.allocate_nullable(3, 9, 1)
    dec.set_from_int(0, 15)
    dec.set_null(1)
    dec.set_from_int(2, -25)
    c.add("dec", Column.from_decimal128(dec))

    c.add(
        "nul",
        Column[HeapRegion](
            arrow_type=ArrowType.NULL,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=None,
            length=3,
            null_count=3,
            offset=0,
        ),
    )

    var text = _write("cov_sink_types.csv", c.batch())
    var want = String(
        '"q""x","l\nf","c,m",i32n,i16n,i8n,u64n,u32n,u16n,u8n,f64,f64n,f32n,'
        "f16n,b,ls,lsn,sn,dict,nd,dec,nul\n"
        "1,7,10,-1,300,5,18446744073709551615,4000000000,65535,255,2.5,1.25,"
        "-1.5,1.5,true,a,x,s,q,100,1.5,\n"
        '-2,,20,,,,,,,,-0.5,,,,,"b,c",,,,-5,,\n'
        '3,-9,-30,2,-300,-5,0,1,2,3,4.0,8.0,0.5,-2.0,false,d,"q""q",t,p,100,'
        "-2.5,\n"
    )
    assert_equal(text, want)


def _ts_col() -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].from_list([1, 2, 3])
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_NS
    )


def _refusal(name: String, var rb: RecordBatch) raises -> String:
    var sink = CsvSink(test_tmpdir() + "/" + name)
    sink.init_sink(rb.schema.copy())
    try:
        sink.accept_batch(rb^)
    except e:
        sink.finish()
        return String(e)
    sink.finish()
    return String("no refusal")


def test_unsupported_type_is_refused_alone_and_among_others() raises:
    """A TIMESTAMP_NS column is refused, naming its index, whether it is the
    batch's only column (formatted directly) or the second of two (the
    per-column error is collected and raised after every column). Mutant:
    drop the collected-error raise (red: the two-column batch writes)."""
    var one = _Cols()
    one.add("t", _ts_col())
    var m1 = _refusal("cov_sink_ts1.csv", one.batch())
    assert_true(
        m1.find("CsvSink: unsupported ArrowType") >= 0
        and m1.find("at column index 0") >= 0,
        m1,
    )
    var two = _Cols()
    two.add("i", _dense[DType.int64](1, 2, 3))
    two.add("t", _ts_col())
    var m2 = _refusal("cov_sink_ts2.csv", two.batch())
    assert_true(
        m2.find("CsvSink: column 1 format (packed) failed:") >= 0, m2
    )


def main() raises:
    test_every_supported_column_type()
    test_unsupported_type_is_refused_alone_and_among_others()
    print("test_csv_cov_sink_types: 2 tests PASS")
