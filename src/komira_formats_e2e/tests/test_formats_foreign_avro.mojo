# =============================================================================
# Avro Object Container Files another implementation wrote, read by value.
# =============================================================================
#
# Every other OCF test in this repo reads bytes komira_avro's own writer
# produced. These are Apache Avro's shared interop files (provenance, pins
# and license: //third_party/apache-avro), staged under avro/. The expected
# records are upstream's: lang/c++/test/DataFileTests.cc (testCompatibility)
# reads each of these files and checks exactly these five records, and
# share/test/data/weather.json lists them; test_upstream_json_agrees checks
# that the table spelled below is byte for byte that weather.json, so the
# oracle is upstream's and not komira's.
#
# What each test proves, and the defect it catches:
#   * test_upstream_json_agrees -- the expected table below, rendered as
#     JSON lines, equals upstream's weather.json. Catches a typo in the
#     oracle (a test that agrees with a wrong reader).
#   * test_weather_<codec> (null, deflate, snappy, zstandard) -- the header
#     starts with `Obj` 01 and its metadata (walked here byte by byte, not
#     by komira's header decoder) declares that codec and a `test.Weather`
#     schema with the doc "A weather reading."; komira's decoded header
#     agrees on the codec; then three reads -- identity (`read_avro_bytes`),
#     resolved against upstream's own reader schema (`order: ignore` on
#     station, as DataFileTests.cc spells it), and block-parallel
#     (`read_avro_bytes_parallel`) -- each give 5 rows, columns
#     station/time/temp typed STRING/INT64/INT32, no NULLs, every value as
#     upstream lists it. Catches a codec mix-up or framing slip (snappy's
#     big-endian CRC32 trailer, deflate's raw RFC 1951 stream, the zstd
#     frame), a sync marker misread, a zig-zag slip on the negative `time`
#     and `temp` values, and a reader-schema resolution that refuses or
#     reorders a foreign writer schema.
#
# Mutants planted and seen red here are listed in the BUCK file header.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_avro import (
    decode_ocf_header,
    read_avro_bytes,
    read_avro_bytes_parallel,
    read_avro_bytes_resolved,
)
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch

from komira_formats_e2e import Mismatches

comptime _ROWS: Int = 5

# The reader schema upstream's testCompatibility uses, verbatim.
comptime _UPSTREAM_READER_SCHEMA = (
    '{"type": "record", "name": "test.Weather", "fields":['
    + '{"name": "station", "type": "string", "order": "ignore"},'
    + '{"name": "time", "type": "long"},'
    + '{"name": "temp", "type": "int"}'
    + "]}"
)


def _stations() -> List[String]:
    var s = List[String]()
    s.append("011990-99999")
    s.append("011990-99999")
    s.append("011990-99999")
    s.append("012650-99999")
    s.append("012650-99999")
    return s^


def _times() -> List[Int64]:
    var t = List[Int64]()
    t.append(-619524000000)
    t.append(-619506000000)
    t.append(-619484400000)
    t.append(-655531200000)
    t.append(-655509600000)
    return t^


def _temps() -> List[Int32]:
    var t = List[Int32]()
    t.append(0)
    t.append(22)
    t.append(-11)
    t.append(111)
    t.append(78)
    return t^


def _find(hay: Span[UInt8, _], needle: String) -> Int:
    var nb = needle.as_bytes()
    var n = len(nb)
    for i in range(len(hay) - n + 1):
        var ok = True
        for k in range(n):
            if hay[i + k] != nb[k]:
                ok = False
                break
        if ok:
            return i
    return -1


def _varint_zigzag(b: Span[UInt8, _], mut pos: Int) raises -> Int:
    var v: UInt64 = 0
    var shift = 0
    while True:
        if pos >= len(b) or shift > 63:
            raise Error("varint runs off the header")
        var x = b[pos]
        pos += 1
        v |= UInt64(x & 0x7F) << UInt64(shift)
        if x < 0x80:
            break
        shift += 7
    return Int(Int64(v >> 1) ^ -Int64(v & 1))


def _header_value(b: Span[UInt8, _], key: String) raises -> String:
    """The metadata value after the Avro string `key` (its zig-zag length,
    then the bytes): found by searching, since a key is never a substring of
    another value in these headers."""
    var at = _find(b, key)
    if at < 0:
        raise Error("header has no " + key)
    var pos = at + key.byte_length()
    var n = _varint_zigzag(b, pos)
    if n < 0 or pos + n > len(b):
        raise Error(key + ": bad value length " + String(n))
    return String(StringSlice(unsafe_from_utf8=b[pos : pos + n]))


def _check_batch(mut m: Mismatches, batch: RecordBatch, at: String) raises:
    if batch.num_rows() != _ROWS:
        m.add(at + ": " + String(batch.num_rows()) + " rows, want 5")
        return
    if batch.num_columns() != 3:
        m.add(at + ": " + String(batch.num_columns()) + " columns, want 3")
        return
    var names = List[String]()
    names.append("station")
    names.append("time")
    names.append("temp")
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT32)
    for c in range(3):
        if batch.schema.field_name(c) != names[c]:
            m.add(at + " column " + String(c) + ": named " + batch.schema.field_name(c) + ", want " + names[c])
            return
        if batch.schema.field_arrow_type(c) != types[c]:
            m.add(at + " " + names[c] + ": type " + String(batch.schema.field_arrow_type(c)) + ", want " + String(types[c]))
            return
    var st = batch.column_as_string(0)
    var ti = batch.column_as_primitive_int64(1)
    var te = batch.column_as_primitive_int32(2)
    var ws = _stations()
    var wti = _times()
    var wte = _temps()
    for r in range(_ROWS):
        var row = at + " row " + String(r)
        if st.is_null(r) or ti.is_null(r) or te.is_null(r):
            m.add(row + ": a NULL in a record with no nullable field")
            continue
        if st.get(r) != ws[r]:
            m.add(row + " station: got '" + st.get(r) + "' want '" + ws[r] + "'")
        if ti.get(r) != wti[r]:
            m.add(row + " time: got " + String(ti.get(r)) + " want " + String(wti[r]))
        if te.get(r) != wte[r]:
            m.add(row + " temp: got " + String(te.get(r)) + " want " + String(wte[r]))


def _check_file(name: String, codec: String) raises:
    var m = Mismatches()
    var bytes = Path("avro/" + name).read_bytes()
    var b = Span(bytes)
    var magic = len(bytes) >= 4 and b[0] == 0x4F and b[1] == 0x62 and b[2] == 0x6A and b[3] == 0x01
    m.check(magic, name + ": does not start with Obj 01")
    var got_codec = _header_value(b, "avro.codec")
    m.check(got_codec == codec, name + ": header avro.codec '" + got_codec + "', want '" + codec + "'")
    var schema = _header_value(b, "avro.schema")
    for part in [
        '"name":"Weather"',
        '"namespace":"test"',
        '"doc":"A weather reading."',
        '{"name":"station","type":"string"}',
        '{"name":"time","type":"long"}',
        '{"name":"temp","type":"int"}',
    ]:
        m.check(
            _find(Span(schema.as_bytes()), part) >= 0,
            name + ": writer schema lacks " + part + " in " + schema,
        )
    var h = decode_ocf_header(b)
    m.check(h.codec_name() == codec, name + ": decode_ocf_header codec '" + h.codec_name() + "', want '" + codec + "'")

    _check_batch(m, read_avro_bytes(b), name + " identity")
    _check_batch(m, read_avro_bytes_resolved(b, _UPSTREAM_READER_SCHEMA), name + " resolved")
    _check_batch(m, read_avro_bytes_parallel(b), name + " parallel")
    m.raise_if_any(name)


def test_upstream_json_agrees() raises:
    var want = String()
    var ws = _stations()
    var wti = _times()
    var wte = _temps()
    for r in range(_ROWS):
        want += (
            '{"station":"' + ws[r] + '","time":' + String(wti[r])
            + ',"temp":' + String(wte[r]) + "}\n"
        )
    var got = Path("avro/weather.json").read_text()
    assert_equal(got, want, "the oracle table is not upstream's weather.json")


def test_weather_null() raises:
    _check_file("weather.avro", "null")


def test_weather_deflate() raises:
    _check_file("weather-deflate.avro", "deflate")


def test_weather_snappy() raises:
    _check_file("weather-snappy.avro", "snappy")


def test_weather_zstandard() raises:
    _check_file("weather-zstd.avro", "zstandard")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
