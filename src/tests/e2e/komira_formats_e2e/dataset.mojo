# =============================================================================
# The source dataset every format leg writes and compares against.
# =============================================================================
#
#   row  city     id                  score   name                   flag
#   0    Zürich   1                   1.5     Grüße, Welt            true
#   1    Zürich   NULL                -2.25   "" (empty string)      false
#   2    Zürich   9007199254740993    NULL    NULL                   NULL
#   3    Oslo     -42                 0.1     Ålesund "Å"            NULL
#   4    Oslo     7                   NULL    NULL                   true
#   5    Oslo     NULL                100.0   東京                   false
#   6    Zürich   3                   0.5     Zeile1<LF>Zeile2 😀    true
#   7    Oslo     -1                  2.0     "Å" Ålesund            false
#   8    Oslo     8                   -0.5    Linje1<CR>Linje2       true
#   9    Zürich   9                   4.25    Ende<CR><LF>Zeile      false
#
# Why these values:
#   * every column has a NULL, in both partitions;
#   * `name` carries each RFC 4180 quoting trigger ALONE in one value, so
#     dropping any one trigger from a CSV writer leaves that value unquoted:
#     row 0 the delimiter (a comma), row 7 a quote that opens the field (a
#     reader only enters the quoted state on a quote at the start of a cell,
#     so a mid-field quote alone, row 3, cannot show a missing quote
#     trigger), row 6 a bare LF, row 8 a bare CR; row 9 holds CRLF inside a
#     field; row 3 and row 7 need each embedded quote doubled;
#   * 2-byte (rows 0, 3, 7), 3-byte (row 5) and 4-byte UTF-8 (row 6, U+1F600,
#     F0 9F 98 80: a JSON codec that \u-escapes must emit a surrogate pair);
#     row 1 is the empty string, which a typed format must keep distinct
#     from NULL;
#   * `id` row 2 is 2^53 + 1, which a reader that goes through a double
#     (a JSON number parsed as float) cannot reproduce;
#   * the floats are exact in binary except 0.1, whose shortest round-trip
#     text is "0.1".
#
# `Zürich` is spelled with the precomposed U+00FC (bytes 5A C3 BC 72 69 63
# 68). On a normalizing file system (macOS APFS can return names in a
# different normalization) the byte assertions in the tests could red for a
# reason that is not a komira defect; the build runs on Linux, which stores
# and returns the bytes it was given.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion


comptime NUM_ROWS: Int = 10


def city_zurich() -> String:
    """`Zürich`, precomposed: 5A C3 BC 72 69 63 68."""
    return String("Zürich")


def city_oslo() -> String:
    return String("Oslo")


def cities() -> List[String]:
    """The partition values, in the order the tree is written."""
    var out = List[String]()
    out.append(city_zurich())
    out.append(city_oslo())
    return out^


def row_city(r: Int) -> String:
    """The `city` partition value of source row `r`."""
    if r < 3 or r == 6 or r == 9:
        return city_zurich()
    return city_oslo()


def rows_of(city: String) -> List[Int]:
    """The source rows of partition `city`, in order; empty for an unknown
    value (so a mangled partition value finds no rows)."""
    var out = List[Int]()
    for r in range(NUM_ROWS):
        if row_city(r) == city:
            out.append(r)
    return out^


def id_at(r: Int) -> Optional[Int64]:
    if r == 0:
        return Optional[Int64](Int64(1))
    if r == 2:
        return Optional[Int64](Int64(9007199254740993))
    if r == 3:
        return Optional[Int64](Int64(-42))
    if r == 4:
        return Optional[Int64](Int64(7))
    if r == 6:
        return Optional[Int64](Int64(3))
    if r == 7:
        return Optional[Int64](Int64(-1))
    if r == 8:
        return Optional[Int64](Int64(8))
    if r == 9:
        return Optional[Int64](Int64(9))
    return Optional[Int64](None)


def score_at(r: Int) -> Optional[Float64]:
    if r == 0:
        return Optional[Float64](Float64(1.5))
    if r == 1:
        return Optional[Float64](Float64(-2.25))
    if r == 3:
        return Optional[Float64](Float64(0.1))
    if r == 5:
        return Optional[Float64](Float64(100.0))
    if r == 6:
        return Optional[Float64](Float64(0.5))
    if r == 7:
        return Optional[Float64](Float64(2.0))
    if r == 8:
        return Optional[Float64](Float64(-0.5))
    if r == 9:
        return Optional[Float64](Float64(4.25))
    return Optional[Float64](None)


def name_at(r: Int) -> Optional[String]:
    if r == 0:
        return Optional[String](String("Grüße, Welt"))
    if r == 1:
        return Optional[String](String(""))
    if r == 3:
        return Optional[String](String('Ålesund "Å"'))
    if r == 5:
        return Optional[String](String("東京"))
    if r == 6:
        return Optional[String](String("Zeile1\nZeile2 😀"))
    if r == 7:
        return Optional[String](String('"Å" Ålesund'))
    if r == 8:
        return Optional[String](String("Linje1\rLinje2"))
    if r == 9:
        return Optional[String](String("Ende\r\nZeile"))
    return Optional[String](None)


def flag_at(r: Int) -> Optional[Bool]:
    if r == 0 or r == 4 or r == 6 or r == 8:
        return Optional[Bool](True)
    if r == 1 or r == 5 or r == 7 or r == 9:
        return Optional[Bool](False)
    return Optional[Bool](None)


def batch_for_city(city: String) raises -> RecordBatch:
    """The rows of partition `city` as a RecordBatch with the schema
    (id INT64, score FLOAT64, name STRING, flag BOOL), all nullable. The
    partition column itself is not stored in the files (Hive layout)."""
    var rows = rows_of(city)
    var n = len(rows)
    if n == 0:
        raise Error("batch_for_city: no rows for partition value " + city)

    var ids = PrimitiveArray[DType.int64].allocate_nullable(n)
    var ids_valid = Bitmap.create_all_valid(n)
    var ids_nulls = 0
    var scores = PrimitiveArray[DType.float64].allocate_nullable(n)
    var scores_valid = Bitmap.create_all_valid(n)
    var scores_nulls = 0
    var flags = BooleanArray.allocate_nullable(n)
    var flags_valid = Bitmap.create_all_valid(n)
    var flags_nulls = 0
    var names = List[String]()
    var names_valid = List[Bool]()

    for i in range(n):
        var r = rows[i]
        var idv = id_at(r)
        if idv:
            ids.set(i, idv.value())
        else:
            ids.set(i, Int64(0))
            ids_valid.clear(i)
            ids_nulls += 1
        var sv = score_at(r)
        if sv:
            scores.set(i, sv.value())
        else:
            scores.set(i, Float64(0))
            scores_valid.clear(i)
            scores_nulls += 1
        var fv = flag_at(r)
        if fv:
            flags.set(i, fv.value())
        else:
            flags.set(i, False)
            flags_valid.clear(i)
            flags_nulls += 1
        var nv = name_at(r)
        if nv:
            names.append(nv.value())
            names_valid.append(True)
        else:
            names.append(String(""))
            names_valid.append(False)

    ids.validity = Optional[Bitmap[HeapRegion]](ids_valid^)
    ids.null_count = ids_nulls
    scores.validity = Optional[Bitmap[HeapRegion]](scores_valid^)
    scores.null_count = scores_nulls
    flags.validity = Optional[Bitmap[HeapRegion]](flags_valid^)
    flags.null_count = flags_nulls
    var name_arr = StringArray.from_strings_with_validity(names, names_valid)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))

    var builder = RecordBatchBuilder.with_capacity(4)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](ids^, ArrowType.INT64)
    )
    builder.add_column(Column.from_primitive[DType.float64](scores^))
    builder.add_column(Column.from_string(name_arr^))
    builder.add_column(Column.from_boolean(flags))
    return builder.build(sb.build())
