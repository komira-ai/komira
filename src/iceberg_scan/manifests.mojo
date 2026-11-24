# =============================================================================
# iceberg_scan/manifests.mojo -- manifest lists and manifests of any writer
# =============================================================================
#
# WHAT THIS IS. The decoders of the two Avro files a snapshot is made of:
# the manifest list (one record per manifest) and a manifest (one record per
# data or delete file). Both are read through `read_avro_datums`, so a field
# is found BY NAME in the writer's own schema, in whatever order that writer
# put it and whether or not it wrote the optional ones (Java, Spark, pyiceberg
# and this repository's writer all differ).
#
# MANIFEST LIST fields: manifest_path, partition_spec_id, content,
# sequence_number, min_sequence_number, added_snapshot_id and the partition
# summaries `partitions[{contains_null, contains_nan, lower_bound,
# upper_bound}]`. A v1 list has no content and no sequence numbers (they read
# as 0).
#
# MANIFEST ENTRY fields: status, sequence_number and data_file{content,
# file_path, file_format, partition{...}, record_count, value_counts,
# null_value_counts, nan_value_counts, lower_bounds, upper_bounds,
# equality_ids, referenced_data_file}. A map field is an Avro array of
# {key, value} records (what Java writes for an int-keyed map) or an Avro map
# (accepted too).
#
# SEQUENCE NUMBERS. An entry whose `sequence_number` is null inherits the
# manifest's (the spec's rule for entries a snapshot added).
#
# PARTITION VALUES are re-serialized to the table spec's single-value form
# (Appendix D) from the Avro value: int and date as 4 little-endian bytes, long
# and timestamp as 8, boolean as one byte, float and double as 4 and 8 bytes of
# IEEE little-endian, string as UTF-8, decimal and fixed as the stored bytes.
# None stands for a null value.
#
# ERRORS. `ICEBERG_MANIFEST_INVALID: <what>`.
# =============================================================================

from std.memory import bitcast

from .avro_datum import (
    AvroDatums,
    ICEBERG_MANIFEST_INVALID,
    AVRO_DATUM_BOOL,
    AVRO_DATUM_BYTES,
    AVRO_DATUM_DOUBLE,
    AVRO_DATUM_FIXED,
    AVRO_DATUM_FLOAT,
    AVRO_DATUM_INT,
    AVRO_DATUM_LONG,
    AVRO_DATUM_MAP,
    AVRO_DATUM_STRING,
    read_avro_datums,
)
from .table_metadata import IcebergPartitionSpecDef, IcebergSchemaDef


comptime ENTRY_EXISTING: Int = 0
comptime ENTRY_ADDED: Int = 1
comptime ENTRY_DELETED: Int = 2

comptime CONTENT_DATA: Int = 0
comptime CONTENT_POSITION_DELETES: Int = 1
comptime CONTENT_EQUALITY_DELETES: Int = 2


def _invalid(what: String) -> Error:
    return Error(ICEBERG_MANIFEST_INVALID + String(": ") + what)


# =============================================================================
# The values.
# =============================================================================


struct IcebergCountMap(Copyable, Movable):
    """A map of field id to a count, as two parallel lists."""

    var ids: List[Int]
    var counts: List[Int64]

    def __init__(out self):
        self.ids = List[Int]()
        self.counts = List[Int64]()

    def get(self, id: Int) -> Optional[Int64]:
        """The count of field `id`, or None when the writer recorded none."""
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return Optional[Int64](self.counts[i])
        return None


struct IcebergBoundMap(Copyable, Movable):
    """A map of field id to a serialized bound, as two parallel lists."""

    var ids: List[Int]
    var bounds: List[List[UInt8]]

    def __init__(out self):
        self.ids = List[Int]()
        self.bounds = List[List[UInt8]]()

    def get(self, id: Int) -> Optional[List[UInt8]]:
        """The serialized bound of field `id`, or None when there is none."""
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return Optional[List[UInt8]](self.bounds[i].copy())
        return None


struct IcebergPartitionSummary(Copyable, Movable):
    """The manifest list's summary of one partition field across a manifest."""

    var contains_null: Bool
    var contains_nan: Optional[Bool]
    var lower: Optional[List[UInt8]]
    var upper: Optional[List[UInt8]]

    def __init__(out self):
        self.contains_null = True
        self.contains_nan = None
        self.lower = None
        self.upper = None


struct IcebergManifestFile(Copyable, Movable):
    """One manifest of a manifest list."""

    var path: String
    var spec_id: Int
    var content: Int
    """0 data, 1 deletes."""
    var sequence_number: Int64
    var min_sequence_number: Int64
    var added_snapshot_id: Int64
    var partitions: List[IcebergPartitionSummary]
    """Empty when the writer recorded no summaries."""

    def __init__(out self):
        self.path = String("")
        self.spec_id = 0
        self.content = 0
        self.sequence_number = 0
        self.min_sequence_number = 0
        self.added_snapshot_id = -1
        self.partitions = List[IcebergPartitionSummary]()


struct IcebergFileEntry(Copyable, Movable):
    """One data or delete file of a manifest."""

    var status: Int
    """0 EXISTING, 1 ADDED, 2 DELETED."""
    var data_sequence_number: Int64
    """The entry's own, else the manifest's."""
    var content: Int
    """0 data, 1 position deletes, 2 equality deletes."""
    var file_path: String
    var file_format: String
    """Upper-cased as stored: PARQUET, AVRO, ORC, PUFFIN."""
    var spec_id: Int
    var partition: List[Optional[List[UInt8]]]
    """Per spec field, the single-value serialization (None is null)."""
    var record_count: Int64
    var value_counts: IcebergCountMap
    var null_value_counts: IcebergCountMap
    var nan_value_counts: IcebergCountMap
    var lower_bounds: IcebergBoundMap
    var upper_bounds: IcebergBoundMap
    var equality_ids: List[Int]
    var referenced_data_file: Optional[String]

    def __init__(out self):
        self.status = 1
        self.data_sequence_number = 0
        self.content = 0
        self.file_path = String("")
        self.file_format = String("")
        self.spec_id = 0
        self.partition = List[Optional[List[UInt8]]]()
        self.record_count = 0
        self.value_counts = IcebergCountMap()
        self.null_value_counts = IcebergCountMap()
        self.nan_value_counts = IcebergCountMap()
        self.lower_bounds = IcebergBoundMap()
        self.upper_bounds = IcebergBoundMap()
        self.equality_ids = List[Int]()
        self.referenced_data_file = None


# =============================================================================
# The manifest list.
# =============================================================================


def read_manifest_list(
    bytes: Span[UInt8, _], format_version: Int
) raises -> List[IcebergManifestFile]:
    """The manifests of a manifest list, in file order. A v1 list has neither
    content nor sequence numbers: both read as 0, whatever the file says."""
    var d = read_avro_datums(bytes)
    var out = List[IcebergManifestFile]()
    for r in range(len(d.records)):
        var rec = d.records[r]
        var m = IcebergManifestFile()
        var path = d.get_string(rec, String("manifest_path"))
        if not path:
            raise _invalid(String("a manifest list entry has no manifest_path"))
        m.path = path.value()
        m.spec_id = Int(d.get_long(rec, String("partition_spec_id")).or_else(0))
        m.added_snapshot_id = d.get_long(rec, String("added_snapshot_id")).or_else(-1)
        if format_version >= 2:
            m.content = Int(d.get_long(rec, String("content")).or_else(0))
            var seq = d.get_long(rec, String("sequence_number"))
            if not seq:
                raise _invalid(
                    String("the manifest ") + m.path + String(" has no sequence_number")
                )
            m.sequence_number = seq.value()
            m.min_sequence_number = d.get_long(
                rec, String("min_sequence_number")
            ).or_else(0)
        var summaries = d.field(rec, String("partitions"))
        if summaries >= 0:
            var items = d.nodes[summaries].children.copy()
            for k in range(len(items)):
                m.partitions.append(_summary_of(d, items[k]))
        out.append(m^)
    return out^


def _summary_of(d: AvroDatums, node: Int) -> IcebergPartitionSummary:
    var s = IcebergPartitionSummary()
    var cn = d.get_bool(node, String("contains_null"))
    if cn:
        s.contains_null = cn.value()
    s.contains_nan = d.get_bool(node, String("contains_nan"))
    s.lower = d.get_bytes(node, String("lower_bound"))
    s.upper = d.get_bytes(node, String("upper_bound"))
    return s^


# =============================================================================
# A manifest.
# =============================================================================


def read_manifest(
    bytes: Span[UInt8, _],
    manifest: IcebergManifestFile,
    spec: IcebergPartitionSpecDef,
    schema: IcebergSchemaDef,
) raises -> List[IcebergFileEntry]:
    """The entries of a manifest, in file order, DELETED ones included (the
    planner skips them). `spec` is the partition spec the manifest was written
    under (`manifest.spec_id`); its field names find the partition values."""
    var d = read_avro_datums(bytes)
    var out = List[IcebergFileEntry]()
    for r in range(len(d.records)):
        var rec = d.records[r]
        var df = d.field(rec, String("data_file"))
        if df < 0:
            raise _invalid(String("an entry of ") + manifest.path + String(" has no data_file"))
        var e = IcebergFileEntry()
        var status = d.get_long(rec, String("status"))
        if not status or status.value() < 0 or status.value() > 2:
            raise _invalid(
                String("an entry of ") + manifest.path + String(" has no valid status")
            )
        e.status = Int(status.value())
        e.data_sequence_number = d.get_long(
            rec, String("sequence_number")
        ).or_else(manifest.sequence_number)
        e.spec_id = manifest.spec_id
        e.content = Int(d.get_long(df, String("content")).or_else(0))
        var path = d.get_string(df, String("file_path"))
        if not path:
            raise _invalid(String("an entry of ") + manifest.path + String(" has no file_path"))
        e.file_path = path.value()
        e.file_format = d.get_string(df, String("file_format")).or_else(String("")).upper()
        e.record_count = d.get_long(df, String("record_count")).or_else(0)
        e.partition = _partition_values(d, df, spec)
        e.value_counts = _count_map(d, d.field(df, String("value_counts")))
        e.null_value_counts = _count_map(d, d.field(df, String("null_value_counts")))
        e.nan_value_counts = _count_map(d, d.field(df, String("nan_value_counts")))
        e.lower_bounds = _bound_map(d, d.field(df, String("lower_bounds")))
        e.upper_bounds = _bound_map(d, d.field(df, String("upper_bounds")))
        var ids = d.field(df, String("equality_ids"))
        if ids >= 0:
            var items = d.nodes[ids].children.copy()
            for k in range(len(items)):
                e.equality_ids.append(Int(d.nodes[items[k]].i))
        e.referenced_data_file = d.get_string(df, String("referenced_data_file"))
        out.append(e^)
    return out^


def _partition_values(
    d: AvroDatums, df: Int, spec: IcebergPartitionSpecDef
) -> List[Optional[List[UInt8]]]:
    var out = List[Optional[List[UInt8]]]()
    var part = d.field(df, String("partition"))
    for k in range(len(spec.fields)):
        if part < 0:
            out.append(None)
            continue
        var v = d.field(part, spec.fields[k].name)
        if v < 0:
            out.append(None)
        else:
            out.append(_single_value(d, v))
    return out^


def _le(mut out: List[UInt8], value: UInt64, width: Int):
    for k in range(width):
        out.append(UInt8((value >> UInt64(8 * k)) & 0xFF))


def _single_value(d: AvroDatums, node: Int) -> Optional[List[UInt8]]:
    """The table spec's single-value serialization of an Avro value."""
    ref n = d.nodes[node]
    var out = List[UInt8]()
    if n.kind == AVRO_DATUM_INT:
        _le(out, bitcast[DType.uint64, 1](n.i) & 0xFFFFFFFF, 4)
    elif n.kind == AVRO_DATUM_LONG:
        _le(out, bitcast[DType.uint64, 1](n.i), 8)
    elif n.kind == AVRO_DATUM_BOOL:
        out.append(UInt8(n.i))
    elif n.kind == AVRO_DATUM_FLOAT:
        _le(out, UInt64(bitcast[DType.uint32, 1](Float32(n.f))), 4)
    elif n.kind == AVRO_DATUM_DOUBLE:
        _le(out, bitcast[DType.uint64, 1](n.f), 8)
    elif (
        n.kind == AVRO_DATUM_STRING
        or n.kind == AVRO_DATUM_BYTES
        or n.kind == AVRO_DATUM_FIXED
    ):
        out = n.bytes.copy()
    else:
        return None
    return Optional[List[UInt8]](out^)


def _count_map(d: AvroDatums, node: Int) -> IcebergCountMap:
    var out = IcebergCountMap()
    if node < 0:
        return out^
    ref n = d.nodes[node]
    for k in range(len(n.children)):
        var id = -1
        var value = Optional[Int64](None)
        if n.kind == AVRO_DATUM_MAP:
            id = _id_of(n.names[k])
            value = Optional[Int64](d.nodes[n.children[k]].i)
        else:
            var key = d.get_long(n.children[k], String("key"))
            if key:
                id = Int(key.value())
            value = d.get_long(n.children[k], String("value"))
        if id >= 0 and value:
            out.ids.append(id)
            out.counts.append(value.value())
    return out^


def _bound_map(d: AvroDatums, node: Int) -> IcebergBoundMap:
    var out = IcebergBoundMap()
    if node < 0:
        return out^
    ref n = d.nodes[node]
    for k in range(len(n.children)):
        var id = -1
        var value = Optional[List[UInt8]](None)
        if n.kind == AVRO_DATUM_MAP:
            id = _id_of(n.names[k])
            value = Optional[List[UInt8]](d.nodes[n.children[k]].bytes.copy())
        else:
            var key = d.get_long(n.children[k], String("key"))
            if key:
                id = Int(key.value())
            value = d.get_bytes(n.children[k], String("value"))
        if id >= 0 and value:
            out.ids.append(id)
            out.bounds.append(value.take())
    return out^


def _id_of(key: String) -> Int:
    """The field id an Avro map key spells, or -1."""
    var v = 0
    var bytes = key.as_bytes()
    if len(bytes) == 0 or len(bytes) > 9:
        return -1
    for b in bytes:
        if b < 0x30 or b > 0x39:
            return -1
        v = v * 10 + Int(b - 0x30)
    return v
