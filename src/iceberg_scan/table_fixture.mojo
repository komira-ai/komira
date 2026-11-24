# =============================================================================
# iceberg_scan/table_fixture.mojo -- the files an Iceberg table is made of, as bytes
# =============================================================================
#
# WHAT THIS IS. Builders of the metadata.json text, the manifest list and the
# manifests of a small Iceberg table, laid out as Iceberg Java lays them out:
# the Java Avro schemas (field ids, `["null", T]` unions, an int-keyed map as an
# array of {key, value} records, or an Avro map when asked), any codec the avro
# package writes, pretty-printed JSON. They are in the library, as
# iceberg_catalog's test catalog is, so that the welded tests of this package
# and of the packages that scan tables (each test is compiled from one file)
# share one writer. They read and write no file, use no clock and no entropy:
# the sync marker is fixed.
#
# It also builds the Arrow columns a test writes data files from (with
# parquet_writer): one `fixture_*_column` per column type of a table, each with
# the rows that are null. A test writes the returned bytes where the metadata
# names them (a bare path or a `file:` URI under a location of its choosing).
#
# Dates in the JSON are on or after 2026-09-01.
# =============================================================================

from std.memory import bitcast

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray
from avro.ocf_block_emit import emit_ocf_block, emit_ocf_header_kv
from avro.ocf_header import OCF_SYNC_LEN
from avro.varint_encode import (
    encode_boolean,
    encode_bytes,
    encode_double,
    encode_float,
    encode_int,
    encode_long,
    encode_string,
)
from byte_buffer.heap_region import HeapRegion


comptime FIXTURE_TIMESTAMP_MS: Int64 = 1788300000000
"""2026-09-01 and a few hours: the `timestamp-ms` of every fixture snapshot."""


# =============================================================================
# Single values (the table spec's Appendix D) for bounds and partition keys.
# =============================================================================


def fixture_int_bytes(v: Int32) -> List[UInt8]:
    """4 little-endian bytes: an int or date bound."""
    var out = List[UInt8]()
    var bits = bitcast[DType.uint32, 1](v)
    for k in range(4):
        out.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))
    return out^


def fixture_long_bytes(v: Int64) -> List[UInt8]:
    """8 little-endian bytes: a long or timestamp bound."""
    var out = List[UInt8]()
    var bits = bitcast[DType.uint64, 1](v)
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
    return out^


def fixture_double_bytes(v: Float64) -> List[UInt8]:
    """8 little-endian bytes of the IEEE double: a double bound."""
    var out = List[UInt8]()
    var bits = bitcast[DType.uint64, 1](v)
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
    return out^


def fixture_float_bytes(v: Float32) -> List[UInt8]:
    """4 little-endian bytes of the IEEE float: a float bound."""
    var out = List[UInt8]()
    var bits = bitcast[DType.uint32, 1](v)
    for k in range(4):
        out.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))
    return out^


def fixture_text_bytes(s: String) -> List[UInt8]:
    """The UTF-8 bytes of a string bound."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


# =============================================================================
# The values a manifest holds.
# =============================================================================


struct FixtureValue(Copyable, Movable):
    """One partition value: null, an int, a long, a string, a boolean, a double
    or a float."""

    var kind: Int
    var i: Int64
    var s: String
    var f: Float64

    def __init__(out self, kind: Int, i: Int64, var s: String, f: Float64):
        self.kind = kind
        self.i = i
        self.s = s^
        self.f = f

    @staticmethod
    def null_value() -> FixtureValue:
        return FixtureValue(0, 0, String(""), 0.0)

    @staticmethod
    def of_int(v: Int) -> FixtureValue:
        return FixtureValue(1, Int64(v), String(""), 0.0)

    @staticmethod
    def of_long(v: Int64) -> FixtureValue:
        return FixtureValue(2, v, String(""), 0.0)

    @staticmethod
    def of_text(var v: String) -> FixtureValue:
        return FixtureValue(3, 0, v^, 0.0)

    @staticmethod
    def of_bool(v: Bool) -> FixtureValue:
        return FixtureValue(4, Int64(1) if v else Int64(0), String(""), 0.0)

    @staticmethod
    def of_double(v: Float64) -> FixtureValue:
        return FixtureValue(5, 0, String(""), v)

    @staticmethod
    def of_float(v: Float32) -> FixtureValue:
        return FixtureValue(6, 0, String(""), Float64(v))


struct FixtureCounts(Copyable, Movable):
    """A map of field id to a count."""

    var ids: List[Int]
    var values: List[Int64]

    def __init__(out self):
        self.ids = List[Int]()
        self.values = List[Int64]()

    def add(mut self, id: Int, value: Int64):
        self.ids.append(id)
        self.values.append(value)


struct FixtureBounds(Copyable, Movable):
    """A map of field id to a serialized bound."""

    var ids: List[Int]
    var values: List[List[UInt8]]

    def __init__(out self):
        self.ids = List[Int]()
        self.values = List[List[UInt8]]()

    def add(mut self, id: Int, var value: List[UInt8]):
        self.ids.append(id)
        self.values.append(value^)


struct FixtureEntry(Copyable, Movable):
    """One manifest entry: a data or delete file and what is known of it."""

    var status: Int
    """0 EXISTING, 1 ADDED, 2 DELETED."""
    var sequence_number: Optional[Int64]
    """None writes a null: the entry inherits its manifest's."""
    var content: Int
    var path: String
    var format: String
    var partition: List[FixtureValue]
    var record_count: Int64
    var value_counts: FixtureCounts
    var null_counts: FixtureCounts
    var nan_counts: FixtureCounts
    var lower: FixtureBounds
    var upper: FixtureBounds
    var equality_ids: List[Int]
    var referenced_data_file: Optional[String]

    def __init__(out self, var path: String):
        self.status = 1
        self.sequence_number = None
        self.content = 0
        self.path = path^
        self.format = String("PARQUET")
        self.partition = List[FixtureValue]()
        self.record_count = 0
        self.value_counts = FixtureCounts()
        self.null_counts = FixtureCounts()
        self.nan_counts = FixtureCounts()
        self.lower = FixtureBounds()
        self.upper = FixtureBounds()
        self.equality_ids = List[Int]()
        self.referenced_data_file = None


struct FixtureSummary(Copyable, Movable):
    """The manifest list's summary of one partition field."""

    var contains_null: Bool
    var contains_nan: Optional[Bool]
    var lower: Optional[List[UInt8]]
    var upper: Optional[List[UInt8]]

    def __init__(out self):
        self.contains_null = False
        self.contains_nan = None
        self.lower = None
        self.upper = None


struct FixtureManifest(Copyable, Movable):
    """One line of a manifest list."""

    var path: String
    var spec_id: Int
    var content: Int
    var sequence_number: Int64
    var min_sequence_number: Int64
    var added_snapshot_id: Int64
    var summaries: List[FixtureSummary]
    """Empty writes a null `partitions`."""

    def __init__(out self, var path: String):
        self.path = path^
        self.spec_id = 0
        self.content = 0
        self.sequence_number = 1
        self.min_sequence_number = 1
        self.added_snapshot_id = 1
        self.summaries = List[FixtureSummary]()


# =============================================================================
# Avro.
# =============================================================================


def _sync() -> Array[UInt8, OCF_SYNC_LEN]:
    return Array[UInt8, OCF_SYNC_LEN](fill=7)


def _optional(avro_type: String) -> String:
    return '["null",' + avro_type + ']'


def _kv_type(name: String, value_type: String, as_map: Bool) -> String:
    """An optional map of int field id to `value_type`: an array of
    {key, value} records, or an Avro map when `as_map`."""
    if as_map:
        return _optional('{"type":"map","values":"' + value_type + '"}')
    return _optional(
        '{"type":"array","items":{"type":"record","name":"'
        + name
        + '","fields":[{"name":"key","type":"int"},{"name":"value","type":"'
        + value_type
        + '"}]}}'
    )


def _entry_schema(
    partition_names: List[String],
    partition_types: List[String],
    v1: Bool,
    as_map: Bool,
) -> String:
    var part = String("")
    for k in range(len(partition_names)):
        if k > 0:
            part += ","
        part += (
            '{"name":"'
            + partition_names[k]
            + '","type":'
            + _optional('"' + partition_types[k] + '"')
            + ',"default":null,"field-id":'
            + String(1000 + k)
            + "}"
        )
    var s = String('{"type":"record","name":"manifest_entry","fields":[')
    s += '{"name":"status","type":"int","field-id":0},'
    s += '{"name":"snapshot_id","type":["null","long"],"default":null,"field-id":1},'
    if not v1:
        s += '{"name":"sequence_number","type":["null","long"],"default":null,"field-id":3},'
        s += '{"name":"file_sequence_number","type":["null","long"],"default":null,"field-id":4},'
    s += '{"name":"data_file","field-id":2,"type":{"type":"record","name":"r2","fields":['
    if not v1:
        s += '{"name":"content","type":"int","field-id":134},'
    s += '{"name":"file_path","type":"string","field-id":100},'
    s += '{"name":"file_format","type":"string","field-id":101},'
    s += '{"name":"partition","field-id":102,"type":{"type":"record","name":"r102","fields":['
    s += part
    s += "]}},"
    s += '{"name":"record_count","type":"long","field-id":103},'
    s += '{"name":"file_size_in_bytes","type":"long","field-id":104},'
    s += '{"name":"column_sizes","type":' + _kv_type("k117_v118", "long", as_map) + ',"default":null,"field-id":108},'
    s += '{"name":"value_counts","type":' + _kv_type("k119_v120", "long", as_map) + ',"default":null,"field-id":109},'
    s += '{"name":"null_value_counts","type":' + _kv_type("k121_v122", "long", as_map) + ',"default":null,"field-id":110},'
    s += '{"name":"nan_value_counts","type":' + _kv_type("k138_v139", "long", as_map) + ',"default":null,"field-id":137},'
    s += '{"name":"lower_bounds","type":' + _kv_type("k126_v127", "bytes", as_map) + ',"default":null,"field-id":125},'
    s += '{"name":"upper_bounds","type":' + _kv_type("k129_v130", "bytes", as_map) + ',"default":null,"field-id":128},'
    s += '{"name":"key_metadata","type":["null","bytes"],"default":null,"field-id":131},'
    s += '{"name":"split_offsets","type":["null",{"type":"array","items":"long"}],"default":null,"field-id":132}'
    if not v1:
        s += ',{"name":"equality_ids","type":["null",{"type":"array","items":"int"}],"default":null,"field-id":135}'
        s += ',{"name":"sort_order_id","type":["null","int"],"default":null,"field-id":140}'
        s += ',{"name":"referenced_data_file","type":["null","string"],"default":null,"field-id":143}'
    s += "]}}]}"
    return s^


def _put_counts(c: FixtureCounts, as_map: Bool, mut out: List[UInt8]):
    if len(c.ids) == 0:
        encode_long(0, out)  # the null branch
        return
    encode_long(1, out)
    encode_long(Int64(len(c.ids)), out)
    for k in range(len(c.ids)):
        if as_map:
            encode_string(String(c.ids[k]), out)
        else:
            encode_int(Int32(c.ids[k]), out)
        encode_long(c.values[k], out)
    encode_long(0, out)


def _put_bounds(b: FixtureBounds, as_map: Bool, mut out: List[UInt8]):
    if len(b.ids) == 0:
        encode_long(0, out)
        return
    encode_long(1, out)
    encode_long(Int64(len(b.ids)), out)
    for k in range(len(b.ids)):
        if as_map:
            encode_string(String(b.ids[k]), out)
        else:
            encode_int(Int32(b.ids[k]), out)
        encode_bytes(Span(b.values[k]), out)
    encode_long(0, out)


def _put_value(v: FixtureValue, mut out: List[UInt8]):
    if v.kind == 0:
        encode_long(0, out)
        return
    encode_long(1, out)
    if v.kind == 1:
        encode_int(Int32(v.i), out)
    elif v.kind == 2:
        encode_long(v.i, out)
    elif v.kind == 3:
        encode_string(v.s, out)
    elif v.kind == 4:
        encode_boolean(v.i != 0, out)
    elif v.kind == 5:
        encode_double(v.f, out)
    else:
        encode_float(Float32(v.f), out)


def _put_entry(e: FixtureEntry, v1: Bool, as_map: Bool, mut out: List[UInt8]):
    encode_int(Int32(e.status), out)
    encode_long(1, out)  # snapshot_id: a long
    encode_long(1, out)
    if not v1:
        if e.sequence_number:
            encode_long(1, out)
            encode_long(e.sequence_number.value(), out)
        else:
            encode_long(0, out)
        encode_long(0, out)  # file_sequence_number: null
        encode_int(Int32(e.content), out)
    encode_string(e.path, out)
    encode_string(e.format, out)
    for k in range(len(e.partition)):
        _put_value(e.partition[k], out)
    encode_long(e.record_count, out)
    encode_long(1024, out)  # file_size_in_bytes
    encode_long(0, out)  # column_sizes: null
    _put_counts(e.value_counts, as_map, out)
    _put_counts(e.null_counts, as_map, out)
    _put_counts(e.nan_counts, as_map, out)
    _put_bounds(e.lower, as_map, out)
    _put_bounds(e.upper, as_map, out)
    encode_long(0, out)  # key_metadata: null
    encode_long(0, out)  # split_offsets: null
    if not v1:
        if len(e.equality_ids) == 0:
            encode_long(0, out)
        else:
            encode_long(1, out)
            encode_long(Int64(len(e.equality_ids)), out)
            for k in range(len(e.equality_ids)):
                encode_int(Int32(e.equality_ids[k]), out)
            encode_long(0, out)
        encode_long(0, out)  # sort_order_id: null
        if e.referenced_data_file:
            encode_long(1, out)
            encode_string(e.referenced_data_file.value(), out)
        else:
            encode_long(0, out)


def fixture_manifest(
    entries: List[FixtureEntry],
    partition_names: List[String],
    partition_types: List[String],
    codec: Int,
    v1: Bool = False,
    as_map: Bool = False,
) raises -> List[UInt8]:
    """A manifest (an Avro OCF file) of `entries` whose partition tuples are
    `partition_names` of the Avro `partition_types`. `v1` writes the v1 layout
    (no content, sequence numbers, equality ids or referenced data file);
    `as_map` writes the six metric maps as Avro maps."""
    var keys = List[String]()
    var values = List[String]()
    keys.append("format-version")
    values.append("1" if v1 else "2")
    keys.append("content")
    values.append("data")
    var out = List[UInt8]()
    emit_ocf_header_kv(
        _entry_schema(partition_names, partition_types, v1, as_map),
        codec,
        _sync(),
        keys,
        values,
        out,
    )
    var payload = List[UInt8]()
    for i in range(len(entries)):
        _put_entry(entries[i], v1, as_map, payload)
    if len(entries) > 0:
        emit_ocf_block(Span(payload), len(entries), codec, _sync(), out)
    return out^


def _list_schema(v1: Bool) -> String:
    var s = String('{"type":"record","name":"manifest_file","fields":[')
    s += '{"name":"manifest_path","type":"string","field-id":500},'
    s += '{"name":"manifest_length","type":"long","field-id":501},'
    s += '{"name":"partition_spec_id","type":"int","field-id":502},'
    if not v1:
        s += '{"name":"content","type":"int","field-id":517},'
        s += '{"name":"sequence_number","type":"long","field-id":515},'
        s += '{"name":"min_sequence_number","type":"long","field-id":516},'
    s += '{"name":"added_snapshot_id","type":"long","field-id":503},'
    s += '{"name":"added_data_files_count","type":["null","int"],"default":null,"field-id":504},'
    s += '{"name":"partitions","field-id":507,"type":["null",{"type":"array","items":{"type":"record","name":"r508","fields":['
    s += '{"name":"contains_null","type":"boolean","field-id":509},'
    s += '{"name":"contains_nan","type":["null","boolean"],"default":null,"field-id":518},'
    s += '{"name":"lower_bound","type":["null","bytes"],"default":null,"field-id":510},'
    s += '{"name":"upper_bound","type":["null","bytes"],"default":null,"field-id":511}'
    s += ']}}],"default":null}]}'
    return s^


def fixture_manifest_list(
    manifests: List[FixtureManifest], codec: Int, v1: Bool = False
) raises -> List[UInt8]:
    """A manifest list (an Avro OCF file) of `manifests`; `v1` writes the v1
    layout (no content or sequence numbers)."""
    var keys = List[String]()
    var values = List[String]()
    keys.append("format-version")
    values.append("1" if v1 else "2")
    var out = List[UInt8]()
    emit_ocf_header_kv(_list_schema(v1), codec, _sync(), keys, values, out)
    var payload = List[UInt8]()
    for i in range(len(manifests)):
        ref m = manifests[i]
        encode_string(m.path, payload)
        encode_long(4096, payload)
        encode_int(Int32(m.spec_id), payload)
        if not v1:
            encode_int(Int32(m.content), payload)
            encode_long(m.sequence_number, payload)
            encode_long(m.min_sequence_number, payload)
        encode_long(m.added_snapshot_id, payload)
        encode_long(1, payload)  # added_data_files_count: the int branch
        encode_int(5, payload)
        if len(m.summaries) == 0:
            encode_long(0, payload)
        else:
            encode_long(1, payload)
            encode_long(Int64(len(m.summaries)), payload)
            for k in range(len(m.summaries)):
                ref s = m.summaries[k]
                encode_boolean(s.contains_null, payload)
                if s.contains_nan:
                    encode_long(1, payload)
                    encode_boolean(s.contains_nan.value(), payload)
                else:
                    encode_long(0, payload)
                if s.lower:
                    encode_long(1, payload)
                    encode_bytes(Span(s.lower.value()), payload)
                else:
                    encode_long(0, payload)
                if s.upper:
                    encode_long(1, payload)
                    encode_bytes(Span(s.upper.value()), payload)
                else:
                    encode_long(0, payload)
            encode_long(0, payload)
    if len(manifests) > 0:
        emit_ocf_block(Span(payload), len(manifests), codec, _sync(), out)
    return out^


# =============================================================================
# metadata.json.
# =============================================================================


def fixture_snapshot_json(
    snapshot_id: Int64,
    sequence_number: Int64,
    manifest_list: String,
    schema_id: Int,
) -> String:
    """One snapshot object of a v2 metadata.json."""
    return (
        '{\n      "snapshot-id": ' + String(snapshot_id)
        + ',\n      "sequence-number": ' + String(sequence_number)
        + ',\n      "timestamp-ms": ' + String(FIXTURE_TIMESTAMP_MS + sequence_number)
        + ',\n      "summary": {"operation": "append", "snapshot-id": "7"}'
        + ',\n      "manifest-list": "' + manifest_list
        + '",\n      "schema-id": ' + String(schema_id) + "\n    }"
    )


def fixture_metadata_json(
    location: String,
    schema_fields: String,
    spec_fields: String,
    snapshots: List[String],
    current_snapshot_id: Int64,
    extra_specs: String = "",
) -> String:
    """A pretty-printed v2 metadata.json, as Iceberg Java writes it: one
    schema (id 0) of `schema_fields` (the text between the brackets of its
    `fields`), one partition spec (id 0) of `spec_fields`, the `snapshots`
    (objects of `fixture_snapshot_json`), and `current-snapshot-id` and
    `refs.main` of `current_snapshot_id` (-1 for none: no `main`). A non-empty
    `extra_specs` is more partition spec objects, after the first."""
    var snaps = String("")
    for i in range(len(snapshots)):
        if i > 0:
            snaps += ",\n    "
        snaps += snapshots[i]
    var s = String('{\n  "format-version": 2,\n')
    s += '  "table-uuid": "9c12d441-03fe-4693-9a96-a0705ddf69c1",\n'
    s += '  "location": "' + location + '",\n'
    s += '  "last-sequence-number": ' + String(len(snapshots)) + ',\n'
    s += '  "last-updated-ms": ' + String(FIXTURE_TIMESTAMP_MS) + ',\n'
    s += '  "last-column-id": 9,\n'
    s += '  "current-schema-id": 0,\n'
    s += '  "schemas": [ {\n    "type": "struct",\n    "schema-id": 0,\n    "fields": [ ' + schema_fields + ' ]\n  } ],\n'
    s += '  "default-spec-id": 0,\n'
    var specs = String('{\n    "spec-id": 0,\n    "fields": [ ' + spec_fields + ' ]\n  }')
    if extra_specs.byte_length() > 0:
        specs += ", " + extra_specs
    s += '  "partition-specs": [ ' + specs + ' ],\n'
    s += '  "properties": {"write.format.default": "parquet"},\n'
    s += '  "current-snapshot-id": ' + String(current_snapshot_id) + ',\n'
    s += '  "snapshots": [ ' + snaps + ' ]'
    if current_snapshot_id >= 0:
        s += ',\n  "refs": {\n    "main": {\n      "snapshot-id": ' + String(current_snapshot_id) + ',\n      "type": "branch"\n    }\n  }'
    s += "\n}\n"
    return s^


# =============================================================================
# Columns for data files.
# =============================================================================


def fixture_i64_column(values: List[Int], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A long column of `values`; the rows listed in `nulls` are null."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int64(values[i]))
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.int64](arr)


def fixture_i32_column(values: List[Int], nulls: List[Int]) raises -> Column[HeapRegion]:
    """An int column."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.int32](arr)


def fixture_date_column(values: List[Int], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A date column of days since the epoch."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive_with_arrow_type[DType.int32](arr, ArrowType.DATE32)


def fixture_micros_column(values: List[Int], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A timestamp column of microseconds since the epoch."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int64(values[i]))
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive_with_arrow_type[DType.int64](arr, ArrowType.TIMESTAMP_US)


def fixture_f64_column(values: List[Float64], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A double column."""
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.float64](arr)


def fixture_f32_column(values: List[Float64], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A float column."""
    var arr = PrimitiveArray[DType.float32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Float32(values[i]))
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.float32](arr)


def fixture_bool_column(values: List[Bool], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A boolean column."""
    var arr = BooleanArray.allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    for k in range(len(nulls)):
        arr._set_null(nulls[k])
    return Column.from_boolean(arr)


def fixture_string_column(values: List[String], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A string column."""
    var valid = List[Bool]()
    for _i in range(len(values)):
        valid.append(True)
    for k in range(len(nulls)):
        valid[nulls[k]] = False
    return Column.from_string(StringArray.from_strings_with_validity(values, valid))


def fixture_decimal_column(
    values: List[Int], nulls: List[Int], precision: Int, scale: Int
) raises -> Column[HeapRegion]:
    """A decimal column of the unscaled `values`."""
    var arr = Decimal128Array.allocate_nullable(len(values), precision, scale)
    for i in range(len(values)):
        var high = Int64(-1) if values[i] < 0 else Int64(0)
        arr.set_raw(i, Int64(values[i]), high)
    for k in range(len(nulls)):
        arr.set_null(nulls[k])
    return Column.from_decimal128(arr)
