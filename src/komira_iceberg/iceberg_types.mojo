# =============================================================================
# iceberg_types.mojo — Iceberg format-version 2 type model + JSON primitives.
# =============================================================================
#
# FILE-BASED ICEBERG INTEROP.
#
# The goal: expose a set of Parquet data files as a READABLE Apache Iceberg
# table written ENTIRELY in the object store, with NO service — any Iceberg
# engine (pyiceberg / DuckDB iceberg / Spark / Trino) reads our table by
# pointing at the bucket. This module is the shared TYPE MODEL the writer
# uses, plus the small JSON-emit primitives that build the table metadata.json
# (a JSON document) and the Avro manifest schema JSONs (Avro schema is JSON).
#
# We DELIBERATELY hand-build JSON here rather than route through the
# `komira_json` JSONL/trait writer: the Iceberg metadata.json and the Avro
# manifest schema strings are FIXED, spec-defined documents with field-id
# attributes that a generic record-to-JSONL writer cannot express. A direct
# String builder is the correct shape (and matches how arrow-rs's iceberg
# crate + pyiceberg emit these — a serde of fixed structs, not a row writer).
#
# SPEC SOURCE OF TRUTH: Apache Iceberg table spec, format-version 2
# (https://iceberg.apache.org/spec/). Field ids are LOAD-BEARING for cross-engine
# readability (readers match columns by field-id, not by name).
#
# Encapsulation: every type is a plain owned-field
# struct; the JSON emit helpers take/return owned String / borrowed values.
# ZERO UnsafePointer in any signature; ZERO wildcard origins; no
# Movable-with-heap-field is stored in a byte slab; no pointer fields.
# =============================================================================


# =============================================================================
# Iceberg primitive type tags (the subset this writer emits).
# =============================================================================
#
# Iceberg's type names in the schema JSON are lowercase strings ("boolean",
# "int", "long", "float", "double", "string"). We carry a small integer tag
# internally and render the spec name via `iceberg_type_name`. The tag set is
# the column-type subset the Parquet writer covers; DECIMAL / DATE / TIMESTAMP /
# nested types are not supported.
#
# THE TAGS THEMSELVES LIVE IN `komira_rowcell`, because they are the
# DISCRIMINANT of `RowCell` — `RowCell.type_tag` IS one of them, so a consumer
# that has the cell but not the tags cannot construct or read one. A consumer
# of the cell alone does not import `komira_iceberg`.
#
# What did NOT move is the part that is genuinely Iceberg's: `iceberg_type_name`
# below, which renders a tag as its ICEBERG SPEC name. The tag ORDINALS are
# internal (0..5) and carry no spec meaning; the spec meaning IS that rendering.
#
# The `ICE_T_*` spelling is retained verbatim as a re-export, so the Iceberg
# package's own call sites (iceberg_parquet_data / iceberg_avro_manifest /
# iceberg_partition / iceberg_delete_writer / the package `__init__` and its
# downstream Iceberg consumers) are untouched. `ICE_T_X` and `CELL_T_X` are the
# SAME comptime Int — there is no conversion anywhere, in either direction.

from komira_rowcell.row_cell import (
    CELL_T_BOOLEAN,
    CELL_T_INT,
    CELL_T_LONG,
    CELL_T_FLOAT,
    CELL_T_DOUBLE,
    CELL_T_STRING,
)

comptime ICE_T_BOOLEAN: Int = CELL_T_BOOLEAN
comptime ICE_T_INT: Int = CELL_T_INT  # 32-bit signed -> Parquet INT32
comptime ICE_T_LONG: Int = CELL_T_LONG  # 64-bit signed -> Parquet INT64
comptime ICE_T_FLOAT: Int = CELL_T_FLOAT  # -> Parquet FLOAT
comptime ICE_T_DOUBLE: Int = CELL_T_DOUBLE  # -> Parquet DOUBLE
comptime ICE_T_STRING: Int = CELL_T_STRING  # -> Parquet BYTE_ARRAY (UTF-8)


@always_inline
def _write_iceberg_type_name[W: Writer](mut writer: W, tag: Int) raises:
    """WRITE what `iceberg_type_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    a shared-library link binds INDEPENDENTLY, and a pair bound CROSSED
    returns the wrong string."""
    if tag == ICE_T_BOOLEAN:
        writer.write(String("boolean"))
        return
    elif tag == ICE_T_INT:
        writer.write(String("int"))
        return
    elif tag == ICE_T_LONG:
        writer.write(String("long"))
        return
    elif tag == ICE_T_FLOAT:
        writer.write(String("float"))
        return
    elif tag == ICE_T_DOUBLE:
        writer.write(String("double"))
        return
    elif tag == ICE_T_STRING:
        writer.write(String("string"))
        return
    raise Error("iceberg_type_name: unknown type tag " + String(tag))


@always_inline
def iceberg_type_name(tag: Int) raises -> String:
    """The Iceberg schema-JSON primitive type name for a type tag."""
    var out = String()
    _write_iceberg_type_name(out, tag)
    return out^


# =============================================================================
# IcebergField / IcebergSchema — the table schema with stable field-ids.
# =============================================================================
#
# Each top-level column gets a STABLE field-id (1-based, assigned in order).
# Field-ids are the cross-engine column identity — a reader matches a data
# file's column to the table schema by field-id, so they must be stable + the
# same id appears in (a) the table schema JSON, (b) the manifest's bound
# lower/upper/null-count maps. We assign 1..N in column order.


@fieldwise_init
struct IcebergField(Copyable, Movable, Deinitable):
    """One top-level column of an Iceberg schema.

    Fields:
      var field_id: Int     — stable, 1-based, assigned in column order.
      var name: String      — column name.
      var type_tag: Int     — one of ICE_T_*.
      var required: Bool     — True == NOT NULL (Iceberg `required`); maps to
                               Parquet REQUIRED. False == nullable (OPTIONAL).
    """

    var field_id: Int
    var name: String
    var type_tag: Int
    var required: Bool


struct IcebergSchema(Copyable, Movable, Deinitable):
    """An Iceberg table schema (a flat struct of primitive columns).

    `schema_id` is the schema's id within the table (0 for the single schema
    this file-based writer emits first). Field-ids are assigned 1..N in column order at `add`.
    """

    var schema_id: Int
    var fields: List[IcebergField]

    def __init__(out self, schema_id: Int = 0):
        self.schema_id = schema_id
        self.fields = List[IcebergField]()

    def copy(self) -> Self:
        var s = Self(self.schema_id)
        for i in range(len(self.fields)):
            s.fields.append(self.fields[i].copy())
        return s^

    def add(mut self, name: String, type_tag: Int, required: Bool = False):
        """Append a column; assigns the next 1-based field-id in column order.

        Field-ids start at 1 (the Iceberg convention — id 0 is reserved). The
        id is `len(fields) + 1` so the assignment is deterministic + stable."""
        var fid = len(self.fields) + 1
        self.fields.append(IcebergField(fid, name, type_tag, required))

    @always_inline
    def num_fields(self) -> Int:
        return len(self.fields)

    @always_inline
    def last_column_id(self) -> Int:
        """The highest field-id assigned (== num_fields; metadata.json
        `last-column-id`)."""
        return len(self.fields)


# =============================================================================
# Schema evolution — ADD COLUMN (schema-id bump-on-commit).
# =============================================================================
#
# A source evolves its schema when a new attribute appears in a source row. We
# support ADD-COLUMN:
# append a NEW column with the next field-id + bump the schema_id. The added
# column is NULLABLE (Iceberg REQUIRES added columns be optional — an existing
# row has no value for it, so it reads NULL). Existing field-ids are STABLE
# (add-column never renumbers), so an OLD data file's columns still bind by
# field-id / name. DROP-COLUMN, RENAME-COLUMN, and partition-spec EVOLUTION are
# not supported.


def evolve_add_column(
    base: IcebergSchema, name: String, type_tag: Int
) raises -> IcebergSchema:
    """Return a NEW schema = `base` + one NULLABLE column, with schema_id bumped.

    The added column gets the next field-id (`base.num_fields() + 1`) in column
    order, is NULLABLE (required=False — Iceberg requires added columns be
    optional so existing rows read NULL), and the new schema's id is
    `base.schema_id + 1`. Existing columns + their field-ids are copied
    verbatim (stable identity)."""
    var out = IcebergSchema(base.schema_id + 1)
    for i in range(len(base.fields)):
        out.fields.append(base.fields[i].copy())
    # add_column assigns field-id = len(fields)+1 in column order; the added
    # column is NULLABLE (required=False).
    out.add(name, type_tag, required=False)
    return out^


# =============================================================================
# Iceberg v2 data_file `content` enum (spec-assigned).
# =============================================================================
#
# The `content` field (data_file field-id 134 / manifest_file field-id 517)
# distinguishes DATA files from the two DELETE-file kinds Iceberg v2 uses for
# merge-on-read. These are the SPEC values — a reader branches on `content` to
# decide whether an entry adds rows (0) or masks rows (1/2):
#
#   0 == DATA             — a Parquet data file (adds rows).
#   1 == POSITION_DELETES — masks rows by (data-file-path, row-position).
#   2 == EQUALITY_DELETES  — masks rows whose `equality_ids` columns match a
#                            delete row's values (delete-by-key).
#
# Defined HERE (not only in iceberg_avro_manifest) so the struct model, the
# writer, and the reader share ONE source of truth for the enum.

comptime ICE_DATA_CONTENT_DATA: Int = 0
comptime ICE_DATA_CONTENT_POSITION_DELETES: Int = 1
comptime ICE_DATA_CONTENT_EQUALITY_DELETES: Int = 2

# Sentinel `DataFileInfo.sequence_number` value meaning "inherit the commit's
# sequence number" — the append path never sets a per-file seq, so its data
# files take the snapshot's sequence number. Delete files set an explicit value.
comptime ICE_SEQ_INHERIT: Int64 = -1


# =============================================================================
# DataFileInfo — per-Parquet-file metadata recorded in the manifest.
# =============================================================================
#
# After the Parquet writer emits a data file, the Iceberg writer records this
# struct: the file path (relative-or-absolute object key), the byte size, the
# row count, and per-column bound/null-count stats keyed by FIELD-ID. The
# stats drive reader-side pruning (a reader skips a file whose [lower, upper]
# cannot satisfy a predicate). All stats are OPTIONAL in the spec; we emit
# record_count + file_size_in_bytes (required) plus lower/upper/null-count for
# the columns we computed them on.
#
# The bound bytes are Iceberg "single-value serialization" (Appendix D):
#   boolean : 1 byte (0x00/0x01)
#   int     : 4 bytes little-endian
#   long    : 8 bytes little-endian
#   float   : 4 bytes little-endian IEEE-754
#   double  : 8 bytes little-endian IEEE-754
#   string  : UTF-8 bytes (no length prefix)
# These are produced by `iceberg_bounds.mojo`.


struct ColumnBound(Copyable, Movable, Deinitable):
    """A per-column (field-id keyed) statistics entry for one data file.

    `lower` / `upper` are Iceberg single-value-serialized bytes (see module
    header). Empty `lower`/`upper` Optionals mean "no bound computed for this
    column" (the file's manifest entry simply omits that field-id from the
    lower/upper maps). `null_count` is the count of null cells (-1 == unknown,
    omitted from the null_value_counts map)."""

    var field_id: Int
    var lower: Optional[List[UInt8]]
    var upper: Optional[List[UInt8]]
    var null_count: Int
    var value_count: Int

    def __init__(
        out self,
        field_id: Int,
        var lower: Optional[List[UInt8]],
        var upper: Optional[List[UInt8]],
        null_count: Int,
        value_count: Int,
    ):
        self.field_id = field_id
        self.lower = lower^
        self.upper = upper^
        self.null_count = null_count
        self.value_count = value_count

    def copy(self) -> Self:
        var lo: Optional[List[UInt8]] = None
        if self.lower:
            lo = self.lower.value().copy()
        var hi: Optional[List[UInt8]] = None
        if self.upper:
            hi = self.upper.value().copy()
        return Self(
            self.field_id, lo^, hi^, self.null_count, self.value_count
        )


struct DataFileInfo(Copyable, Movable, Deinitable):
    """Everything the manifest needs to record for one Parquet data / delete
    file.

    Fields:
      var file_path: String       — the file's object-store KEY, recorded in the
                                     manifest exactly as given. It is a key of
                                     the store the table lives in (`location`
                                     plus a relative part), not a URI with a
                                     scheme: the store normalizes its keys, so
                                     `s3://b/k` would not survive a read back.
                                     An engine that opens the table resolves
                                     the key itself (see the README).
      var file_size_in_bytes: Int — on-disk byte size of the file.
      var record_count: Int       — number of rows in the file.
      var bounds: List[ColumnBound] — per-column stats keyed by field-id.
      var content: Int            — one of ICE_DATA_CONTENT_* (0 data /
                                     1 position-deletes / 2 equality-deletes).
                                     Default 0 (data) so the append path + the
                                     REST-adapter projection keep constructing
                                     `DataFileInfo` positionally with 4 args.
      var equality_ids: List[Int] — for an EQUALITY-delete file, the field-ids
                                     the delete rows carry (the match columns).
                                     Empty for data + position-delete files.
      var sequence_number: Int64  — this file's OWN data sequence number, or
                                     ICE_SEQ_INHERIT (-1) to mean "inherit the
                                     commit's sequence number". Delete files
                                     carry their own so the reader orders
                                     deletes against data-file generations (an
                                     equality delete masks ONLY data files with
                                     a STRICTLY LOWER sequence number).
      var partition_avro: List[List[UInt8]]
                                   — the PARTITION-VALUE tuple for this file, one
                                     entry per partition field, each PRE-ENCODED
                                     in its Avro primitive form (int -> zigzag
                                     varint, string -> length+bytes, etc.). The
                                     manifest partition encoder concatenates
                                     these positionally into the `r102` partition
                                     record. Empty for an unpartitioned table (the
                                     empty `r102` = zero bytes). Kept as
                                     PRE-ENCODED BYTES (not `RowCell`) so
                                     iceberg_types has NO import cycle with
                                     iceberg_row_value — the caller (the
                                     partition-aware writer, which sees `RowCell`)
                                     encodes them via `set_partition_avro`.
      var partition_types: List[Int]
                                   — the partition VALUES' type tags (ICE_T_*, in
                                     partition-field order). The decoder needs
                                     them to skip/read the partition struct.

    `DataFileInfo` is only ever stored in a plain `List[DataFileInfo]` (never
    a byte-backed slab, never cast under a wildcard origin), so the
    heap-owning `String` / `List[ColumnBound]` / `List[Int]` /
    `List[List[UInt8]]` fields are safe (the byte-slab rule in
    docs/design/mojo_safety_and_idioms.md).
    """

    var file_path: String
    var file_size_in_bytes: Int
    var record_count: Int
    var bounds: List[ColumnBound]
    var content: Int
    var equality_ids: List[Int]
    var sequence_number: Int64
    var partition_avro: List[List[UInt8]]
    var partition_types: List[Int]

    def __init__(
        out self,
        var file_path: String,
        file_size_in_bytes: Int,
        record_count: Int,
        var bounds: List[ColumnBound],
    ):
        """Legacy 4-arg (DATA-file) ctor — content defaults to data, no
        equality-ids, sequence inherits the commit (ICE_SEQ_INHERIT),
        UNPARTITIONED (empty partition tuple). Used by the append path + the
        REST-adapter projection."""
        self.file_path = file_path^
        self.file_size_in_bytes = file_size_in_bytes
        self.record_count = record_count
        self.bounds = bounds^
        self.content = ICE_DATA_CONTENT_DATA
        self.equality_ids = List[Int]()
        self.sequence_number = ICE_SEQ_INHERIT
        self.partition_avro = List[List[UInt8]]()
        self.partition_types = List[Int]()

    def __init__(
        out self,
        var file_path: String,
        file_size_in_bytes: Int,
        record_count: Int,
        var bounds: List[ColumnBound],
        content: Int,
        var equality_ids: List[Int],
        sequence_number: Int64 = ICE_SEQ_INHERIT,
    ):
        """Full ctor — carries the delete-file `content` + `equality_ids` + an
        explicit per-file `sequence_number` (delete files supply their own).
        UNPARTITIONED by default; call `with_partition` to attach a partition
        tuple to a DATA file."""
        self.file_path = file_path^
        self.file_size_in_bytes = file_size_in_bytes
        self.record_count = record_count
        self.bounds = bounds^
        self.content = content
        self.equality_ids = equality_ids^
        self.sequence_number = sequence_number
        self.partition_avro = List[List[UInt8]]()
        self.partition_types = List[Int]()

    def with_partition(
        var self,
        var partition_avro: List[List[UInt8]],
        var partition_types: List[Int],
    ) -> Self:
        """Return `self` with a PARTITION tuple attached (pre-encoded Avro bytes
        + the value type tags, in partition-field order).

        The caller (the partition-aware writer, which has the typed `RowCell`
        values) pre-encodes each value to its Avro primitive form via
        `encode_partition_values` in iceberg_partition, then attaches the tuple
        here. Consumed by the manifest partition encoder. A move-in / move-out
        builder so `di = di.with_partition(...)` reads cleanly at the call
        site."""
        self.partition_avro = partition_avro^
        self.partition_types = partition_types^
        return self^

    def copy(self) -> Self:
        var b = List[ColumnBound]()
        for i in range(len(self.bounds)):
            b.append(self.bounds[i].copy())
        var eids = List[Int]()
        for i in range(len(self.equality_ids)):
            eids.append(self.equality_ids[i])
        var out = Self(
            String(self.file_path),
            self.file_size_in_bytes,
            self.record_count,
            b^,
            self.content,
            eids^,
            self.sequence_number,
        )
        var pa = List[List[UInt8]]()
        for i in range(len(self.partition_avro)):
            pa.append(self.partition_avro[i].copy())
        var pt = List[Int]()
        for i in range(len(self.partition_types)):
            pt.append(self.partition_types[i])
        return out^.with_partition(pa^, pt^)


# =============================================================================
# JSON-emit primitives — minimal, correct string builders for metadata.json
# and the Avro manifest schema JSON.
# =============================================================================
#
# These produce a SINGLE JSON document built by direct String concatenation.
# Correctness over speed: metadata.json is small (a few KiB) and written once
# per commit. The string-escape follows RFC 8259 §7 (the same rule
# `komira_json/encode.mojo:_emit_string_escaped` applies).


def json_escape_string(s: String) -> String:
    """RFC 8259 §7 JSON string escaping, wrapped in double-quotes.

    Escapes `"`, `\\`, and control chars < 0x20 (the mandatory set). Bytes
    >= 0x80 (the UTF-8 continuation of a non-ASCII character) are copied
    through unchanged. The output is a complete JSON string token including the
    surrounding quotes."""
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs) + 2)
    out.append(UInt8(ord('"')))
    for i in range(len(bs)):
        var b = Int(bs[i])
        if b == ord('"'):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord('"')))
        elif b == ord("\\"):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("\\")))
        elif b == 0x08:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("b")))
        elif b == 0x0C:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("f")))
        elif b == 0x0A:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("n")))
        elif b == 0x0D:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("r")))
        elif b == 0x09:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("t")))
        elif b < 0x20:
            # \u00XX for the remaining control chars.
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("u")))
            out.append(UInt8(ord("0")))
            out.append(UInt8(ord("0")))
            out.append(_hex_nibble_upper((b >> 4) & 0xF))
            out.append(_hex_nibble_upper(b & 0xF))
        else:
            out.append(bs[i])
    out.append(UInt8(ord('"')))
    # SAFETY: every byte is copied from a valid UTF-8 `String` and the escapes
    # added are ASCII, so the result is valid UTF-8.
    return String(unsafe_from_utf8=Span(out))


@always_inline
def _hex_nibble_upper(nib: Int) -> UInt8:
    if nib < 10:
        return UInt8(0x30 + nib)
    return UInt8(0x41 + nib - 10)  # 'A'..'F'


@always_inline
def json_kv_str(key: String, value: String) -> String:
    """`"key":"escaped-value"` (no trailing comma)."""
    return json_escape_string(key) + ":" + json_escape_string(value)


@always_inline
def json_kv_int(key: String, value: Int) -> String:
    """`"key":<int>` (no trailing comma)."""
    return json_escape_string(key) + ":" + String(value)


@always_inline
def json_kv_int64(key: String, value: Int64) -> String:
    """`"key":<int64>` (no trailing comma)."""
    return json_escape_string(key) + ":" + String(value)


@always_inline
def json_kv_bool(key: String, value: Bool) -> String:
    """`"key":true|false` (no trailing comma)."""
    return json_escape_string(key) + ":" + ("true" if value else "false")


@always_inline
def json_kv_raw(key: String, raw_value: String) -> String:
    """`"key":<raw>` — value emitted verbatim (for nested objects/arrays)."""
    return json_escape_string(key) + ":" + raw_value
