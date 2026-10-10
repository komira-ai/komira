# =============================================================================
# Every file of the Hive tree, read back with a projection, against the source.
# =============================================================================
#
# The tree is written by `write_hive_tree` (ORC, Avro OCF, JSONL, CSV via
# CsvSink) and discovered with `PrunedHiveDiscovery.open` over the real
# `LocalFs`. For each discovered file the partition value comes from
# discovery, and the source rows compared against are the rows of THAT value:
# a mangled partition value selects no rows and the file fails.
#
# Each file is read twice, each time with a strict subset of the columns in a
# different order than written (written: id, score, name, flag):
#   A = (name, score, id)    B = (flag, id)
# so every column is compared once and `id` twice. The Avro file is read a
# third time, C = (id, name), with the reader's unions in the reverse branch
# order (["long","null"]) from the writer's (["null","long"]), so schema
# resolution must match union branches by type, not by index. Per reader, the projection
# is the reader's own public API:
#   ORC   `read_orc_bytes_projected` with root-child indices [2, 1, 0] / [3, 0];
#   Avro  `read_avro_file_resolved` with a reader schema naming the fields in
#         the projected order (Avro schema resolution drops the others);
#   JSONL `materialize_jsonl_to_batch` with a schema of the projected fields;
#   CSV   `read_csv_bytes_to_batch[Rfc4180]` with `with_projection` per name.
# ORC, Avro and JSONL return the columns in the requested order (asserted);
# the CSV reader returns projected columns in file order, so columns are found
# by name everywhere.
#
# Per cell: a NULL must read as NULL and a value as that value, exactly (the
# floats included: each is exact in binary or has a shortest round-trip form).
# ONE stated exception, CSV only: `CsvSink` writes NULL as an empty field and
# also writes the empty string as an empty field, and the reader's default
# null spellings include the empty field, so the empty string in row 1 reads
# back as NULL. That is the CSV convention this sink documents (pandas
# parity), not a value this test lets drift: the expected cell is spelled out
# below, and every other CSV cell is held to the source.
#
# What this test cannot see: every leg is a SELF-round-trip. The bytes are
# written by komira's writer and read back by komira's reader for the same
# format, so a writer and reader that agree on a wrong encoding (PRESENT
# polarity inverted on both sides, swapped Avro union branches, a NULL token
# both sides accept) still go green here. The writer side is pinned against
# literals spelled from the format specs in test_formats_golden_bytes (exact
# CSV and JSONL bytes; Avro OCF framing and writer schema; ORC magic,
# per-stripe stats and stream sizes); no file written by another
# implementation is read here.
#
# Defects this reds on (each planted in product code and seen red on the
# farm): a readdir decode that re-encodes bytes (no Zürich rows are found);
# CsvSink leaving a field with a comma unquoted (row 0 splits into an extra
# cell) or not doubling an embedded quote; CsvSink not quoting a value whose
# only trigger is an opening quote, LF or CR (rows 7, 6, 8); the ORC writer
# skipping PRESENT for a DOUBLE column and writing the NULL slots'
# placeholder values into DATA ("orc Oslo A score row 4 should be NULL").
# Two other ORC defects red here as decode errors (a stream overrun), not as
# a cell compare: the writer marking every slot present while DATA still
# omits NULL slots, and the reader ignoring PRESENT.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_avro import read_avro_file_resolved
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.reader import read_csv_bytes_to_batch
from komira_fs.local_fs import LocalFs
from komira_fs.pruned_hive_discovery import PrunedHiveDiscovery
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_orc import read_orc_bytes_projected
from komira_runtime_paths import test_tmpdir

from komira_formats_e2e import (
    cities,
    flag_at,
    format_exts,
    id_at,
    name_at,
    rows_of,
    score_at,
    write_hive_tree,
)


comptime _Fs = LocalFs[NoopSink]

comptime _AVRO_A = (
    '{"type":"record","name":"topLevelRecord","fields":['
    '{"name":"name","type":["null","string"]},'
    '{"name":"score","type":["null","double"]},'
    '{"name":"id","type":["null","long"]}]}'
)
comptime _AVRO_B = (
    '{"type":"record","name":"topLevelRecord","fields":['
    '{"name":"flag","type":["null","boolean"]},'
    '{"name":"id","type":["null","long"]}]}'
)
comptime _AVRO_C = (
    '{"type":"record","name":"topLevelRecord","fields":['
    '{"name":"id","type":["long","null"]},'
    '{"name":"name","type":["string","null"]}]}'
)


def _names_a() -> List[String]:
    var out = List[String]()
    out.append(String("name"))
    out.append(String("score"))
    out.append(String("id"))
    return out^


def _names_b() -> List[String]:
    var out = List[String]()
    out.append(String("flag"))
    out.append(String("id"))
    return out^


def _names_c() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("name"))
    return out^


def _type_of(name: String) -> ArrowType:
    if name == "id":
        return ArrowType.INT64
    if name == "score":
        return ArrowType.FLOAT64
    if name == "name":
        return ArrowType.STRING
    return ArrowType.BOOL


# =============================================================================
# Comparison against the source dataset.
# =============================================================================


def _col(batch: RecordBatch, name: String, label: String) raises -> Int:
    for c in range(batch.num_columns()):
        if batch.schema.field_name(c) == name:
            return c
    raise Error(label + ": no column " + name)


def _check_type(batch: RecordBatch, c: Int, want: ArrowType, label: String) raises:
    var got = batch.schema.field_arrow_type(c)
    if got != want:
        raise Error(
            label + ": column " + batch.schema.field_name(c) + " is "
            + String(got) + ", want " + String(want)
        )


def _check_id(batch: RecordBatch, rows: List[Int], label: String) raises:
    var c = _col(batch, "id", label)
    _check_type(batch, c, ArrowType.INT64, label)
    var a = batch.column_as_primitive_int64(c)
    for i in range(len(rows)):
        var want = id_at(rows[i])
        var at = label + " id row " + String(rows[i])
        if want:
            assert_true(not a.is_null(i), at + " is NULL, want a value")
            assert_equal(a.get(i), want.value(), at)
        else:
            assert_true(a.is_null(i), at + " should be NULL")


def _check_score(batch: RecordBatch, rows: List[Int], label: String) raises:
    var c = _col(batch, "score", label)
    _check_type(batch, c, ArrowType.FLOAT64, label)
    var a = batch.column_as_primitive_float64(c)
    for i in range(len(rows)):
        var want = score_at(rows[i])
        var at = label + " score row " + String(rows[i])
        if want:
            assert_true(not a.is_null(i), at + " is NULL, want a value")
            assert_true(
                a.get(i) == want.value(),
                at + ": got " + String(a.get(i)) + " want " + String(want.value()),
            )
        else:
            assert_true(a.is_null(i), at + " should be NULL")


def _check_name(
    batch: RecordBatch, rows: List[Int], csv: Bool, label: String
) raises:
    var c = _col(batch, "name", label)
    _check_type(batch, c, ArrowType.STRING, label)
    var a = batch.column_as_string(c)
    for i in range(len(rows)):
        var want = name_at(rows[i])
        # CSV only: the empty string is written as an empty field and reads
        # back as NULL (see the header).
        if csv and want and want.value().byte_length() == 0:
            want = Optional[String](None)
        var at = label + " name row " + String(rows[i])
        if want:
            assert_true(not a.is_null(i), at + " is NULL, want a value")
            var got = a.get(i)
            if got != want.value():
                raise Error(at + ": got '" + got + "' want '" + want.value() + "'")
        else:
            assert_true(a.is_null(i), at + " should be NULL")


def _check_flag(batch: RecordBatch, rows: List[Int], label: String) raises:
    var c = _col(batch, "flag", label)
    _check_type(batch, c, ArrowType.BOOL, label)
    var a = batch.column_as_boolean(c)
    for i in range(len(rows)):
        var want = flag_at(rows[i])
        var at = label + " flag row " + String(rows[i])
        if want:
            assert_true(not a.is_null(i), at + " is NULL, want a value")
            assert_equal(a.get(i), want.value(), at)
        else:
            assert_true(a.is_null(i), at + " should be NULL")


def _check_projection(
    batch: RecordBatch,
    names: List[String],
    rows: List[Int],
    ordered: Bool,
    csv: Bool,
    label: String,
) raises:
    assert_equal(batch.num_rows(), len(rows), label + ": row count")
    assert_equal(batch.num_columns(), len(names), label + ": column count")
    if ordered:
        for i in range(len(names)):
            assert_equal(
                batch.schema.field_name(i), names[i], label + ": column order"
            )
    for i in range(len(names)):
        if names[i] == "id":
            _check_id(batch, rows, label)
        elif names[i] == "score":
            _check_score(batch, rows, label)
        elif names[i] == "name":
            _check_name(batch, rows, csv, label)
        else:
            _check_flag(batch, rows, label)


# =============================================================================
# Per-format projected reads.
# =============================================================================


def _read_orc(path: String, projection: List[Int]) raises -> RecordBatch:
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    return read_orc_bytes_projected(
        buf.view_range_ro(0, buf.len()).into_span(), projection
    )


def _read_jsonl(path: String, names: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], _type_of(names[i]), True))
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    return materialize_jsonl_to_batch(
        buf.view_range_ro(0, buf.len()).into_span(), sb.build()
    )


def _read_csv(path: String, names: List[String]) raises -> RecordBatch:
    var opts = CsvReadOptions()
    for i in range(len(names)):
        opts.with_projection(names[i])
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    return read_csv_bytes_to_batch[Rfc4180](
        buf.view_range_ro(0, buf.len()).into_span(), opts
    )


def _ext_of(path: String) -> String:
    var dot = path.rfind(".")
    return String(path[byte = dot + 1 : path.byte_length()])


def _check_file(path: String, city: String) raises -> String:
    """Read `path` twice with projections A and B and compare with the source
    rows of `city`. Returns the extension checked."""
    var rows = rows_of(city)
    if len(rows) == 0:
        raise Error(
            path + ": partition value '" + city + "' names no source rows"
        )
    var ext = _ext_of(path)
    var la = ext + " " + city + " A"
    var lb = ext + " " + city + " B"
    if ext == "orc":
        _check_projection(_read_orc(path, [2, 1, 0]), _names_a(), rows, True, False, la)
        _check_projection(_read_orc(path, [3, 0]), _names_b(), rows, True, False, lb)
    elif ext == "avro":
        _check_projection(read_avro_file_resolved(path, _AVRO_A), _names_a(), rows, True, False, la)
        _check_projection(read_avro_file_resolved(path, _AVRO_B), _names_b(), rows, True, False, lb)
        _check_projection(
            read_avro_file_resolved(path, _AVRO_C), _names_c(), rows, True, False,
            ext + " " + city + " C",
        )
    elif ext == "jsonl":
        _check_projection(_read_jsonl(path, _names_a()), _names_a(), rows, True, False, la)
        _check_projection(_read_jsonl(path, _names_b()), _names_b(), rows, True, False, lb)
    elif ext == "csv":
        _check_projection(_read_csv(path, _names_a()), _names_a(), rows, False, True, la)
        _check_projection(_read_csv(path, _names_b()), _names_b(), rows, False, True, lb)
    else:
        raise Error("unexpected file in the tree: " + path)
    return ext^


def test_every_file_projected_roundtrip() raises:
    var base = test_tmpdir()
    var root = base + "/formats_e2e_roundtrip"
    write_hive_tree(root)

    var fs = _Fs.new()
    var d = PrunedHiveDiscovery.open(fs, root)
    assert_equal(d.num_paths(), 8, "two partitions x four formats")

    # Keyed by (format, partition value): a discovery that returned one
    # partition's file twice and the other's not at all must not pass.
    var counts = Dict[String, Int]()
    for i in range(d.num_paths()):
        var path = d.path_at(i)
        var pv = d.partition_values_at(i)
        assert_equal(pv.num_pairs(), 1, path + ": one partition pair")
        assert_equal(pv.keys[0], String("city"), path + ": partition key")
        var ext = _check_file(path, pv.values[0])
        var key = ext + "|" + pv.values[0]
        counts[key] = counts.get(key, 0) + 1

    var exts = format_exts()
    var cs = cities()
    assert_equal(len(counts), len(exts) * len(cs), "distinct (format, city) pairs")
    for i in range(len(exts)):
        for j in range(len(cs)):
            var key = exts[i] + "|" + cs[j]
            assert_equal(counts.get(key, 0), 1, key + ": checked exactly once")


def main() raises:
    test_every_file_projected_roundtrip()
    print("test_formats_projected_roundtrip: ALL PASS")
