# =============================================================================
# iceberg_partition.mojo — Iceberg v2 partition-spec model + transforms +
#                          per-row partition-value computation + routing.
# =============================================================================
#
# A table over real data almost always partitions (by date or key hash) for
# reader pruning and file sizing. Without a spec the writer emits only
# an unpartitioned spec. This module adds:
#
#   1. A PARTITION-SPEC MODEL (`PartitionSpec` = a list of `PartitionField`,
#      each a {source field-id, transform, partition field-id, name}).
#   2. Two TRANSFORMS:
#        * IDENTITY(col)   — partition by the column value verbatim (e.g. a
#          low-cardinality status / region column).
#        * BUCKET(N, col)  — partition by `bucket = (hash(value) & INT_MAX) % N`
#          (the Iceberg 32-bit-murmur3 bucket transform): hash-partition by key
#          for even file sizes and reader pruning without exposing the key
#          values.
#   3. PER-ROW PARTITION-VALUE COMPUTATION (`partition_value_of`) — the tuple
#      of partition values a row belongs to, as a `List[RowCell]` in
#      partition-field order (each cell an INT for BUCKET, the source type for
#      IDENTITY).
#   4. A STABLE PARTITION KEY (`partition_key_string`) — a deterministic
#      string encoding of a partition tuple used to (a) group rows into
#      per-partition data files on write and (b) name the data file's
#      partition directory (Iceberg's `col=value` hive-ish path fragment, for
#      human/engine legibility — the manifest's `partition` struct is the
#      authoritative binding, the path is convenience).
#
# WHY bucket(N) not days(ts): the type model (iceberg_types ICE_T_*) covers
# boolean/int/long/float/double/string only — no DATE/TIMESTAMP. A `days(ts)`
# transform would need a new temporal type. `bucket(N, key)` needs no new type
# (it hashes any int, long or string) and is the common key-hash shape. So we
# ship identity + bucket; `days`/`years`/`truncate` are not supported.
#
# The Iceberg BUCKET hash is murmur3_x86_32 with seed 0 over the value's
# Iceberg single-value bytes, then `(hash & 0x7FFFFFFF) % N` (spec Appendix B).
# We implement murmur3_x86_32 here (dependency-free, matches the spec vectors)
# so an external Iceberg engine computes the SAME bucket for the SAME value —
# load-bearing for cross-engine partition pruning.
#
# Encapsulation: every type is a plain owned-field struct; every function takes
# owned/borrowed typed values and returns owned values. ZERO UnsafePointer in
# any signature; ZERO wildcard origins; PartitionField/PartitionSpec live only
# in plain Lists (no byte slab, no pointer fields).
# =============================================================================

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
)
from .iceberg_row_value import (
    RowCell,
    make_int_cell,
    encode_cell,
)


# =============================================================================
# Partition transform tags (the subset this writer emits).
# =============================================================================
#
# Iceberg's transform names in the partition-spec JSON are lowercase strings
# ("identity", "bucket[N]"). We carry a small integer tag + a param (N for
# bucket) and render the spec name via `transform_name`.

comptime ICE_TRANSFORM_IDENTITY: Int = 0
comptime ICE_TRANSFORM_BUCKET: Int = 1

# The Iceberg convention: partition-field ids start at 1000 (the spec's
# partition-field-id base; metadata.json `last-partition-id` tracks the max).
comptime ICE_PARTITION_FIELD_ID_BASE: Int = 1000


# =============================================================================
# PartitionField — one field of a partition spec.
# =============================================================================


@fieldwise_init
struct PartitionField(Copyable, Movable, Deinitable):
    """One partition field: a transform applied to one source column.

    Fields:
      var source_field_id: Int  — the schema field-id this partitions on.
      var field_id: Int         — the PARTITION field-id (>= 1000, stable).
      var name: String          — the partition field name (e.g. "id_bucket").
      var transform: Int        — one of ICE_TRANSFORM_*.
      var param: Int            — the transform parameter: N for BUCKET; unused
                                  (0) for IDENTITY.
    """

    var source_field_id: Int
    var field_id: Int
    var name: String
    var transform: Int
    var param: Int

    def copy(self) -> Self:
        return Self(
            self.source_field_id,
            self.field_id,
            String(self.name),
            self.transform,
            self.param,
        )


# =============================================================================
# PartitionSpec — an ordered list of partition fields (spec-id 0 for a
# create-time spec; spec EVOLUTION is not supported).
# =============================================================================


struct PartitionSpec(Copyable, Movable, Deinitable):
    """An Iceberg partition spec: an ordered list of `PartitionField`.

    `spec_id` is 0 for the single spec a create-time partitioned table uses
    (changing an existing table's spec — partition-spec EVOLUTION — is not
    supported). Partition-field ids are assigned 1000.. in add order.
    """

    var spec_id: Int
    var fields: List[PartitionField]

    def __init__(out self, spec_id: Int = 0):
        self.spec_id = spec_id
        self.fields = List[PartitionField]()

    def copy(self) -> Self:
        var s = Self(self.spec_id)
        for i in range(len(self.fields)):
            s.fields.append(self.fields[i].copy())
        return s^

    @always_inline
    def num_fields(self) -> Int:
        return len(self.fields)

    @always_inline
    def is_unpartitioned(self) -> Bool:
        return len(self.fields) == 0

    def _next_field_id(self) -> Int:
        """The next partition field-id (1000-based, one above the current max)."""
        var mx = ICE_PARTITION_FIELD_ID_BASE - 1
        for i in range(len(self.fields)):
            if self.fields[i].field_id > mx:
                mx = self.fields[i].field_id
        return mx + 1

    def add_identity(mut self, source_field_id: Int, name: String):
        """Add an IDENTITY partition field on `source_field_id`."""
        self.fields.append(
            PartitionField(
                source_field_id,
                self._next_field_id(),
                name,
                ICE_TRANSFORM_IDENTITY,
                0,
            )
        )

    def add_bucket(mut self, source_field_id: Int, buckets: Int, name: String):
        """Add a BUCKET[buckets] partition field on `source_field_id`."""
        var n = buckets
        if n <= 0:
            # A degenerate bucket count would divide-by-zero at compute time.
            # We clamp to 1 rather than raise (add_* is non-raising for a clean
            # builder), which yields a single-bucket (== unpartitioned-ish)
            # spec; callers should pass buckets >= 1.
            n = 1
        self.fields.append(
            PartitionField(
                source_field_id,
                self._next_field_id(),
                name,
                ICE_TRANSFORM_BUCKET,
                n,
            )
        )

    @always_inline
    def last_partition_id(self) -> Int:
        """The highest partition field-id assigned (metadata.json
        `last-partition-id`). For an unpartitioned spec this is the base-1
        sentinel (999), matching the unpartitioned convention."""
        if len(self.fields) == 0:
            return ICE_PARTITION_FIELD_ID_BASE - 1  # 999
        var mx = ICE_PARTITION_FIELD_ID_BASE - 1
        for i in range(len(self.fields)):
            if self.fields[i].field_id > mx:
                mx = self.fields[i].field_id
        return mx


def transform_name(transform: Int, param: Int) raises -> String:
    """The Iceberg partition-spec-JSON transform name.

    IDENTITY -> "identity"; BUCKET -> "bucket[N]" (the spec's parameterized
    spelling)."""
    if transform == ICE_TRANSFORM_IDENTITY:
        return String("identity")
    elif transform == ICE_TRANSFORM_BUCKET:
        return String("bucket[") + String(param) + String("]")
    raise Error("transform_name: unknown transform tag " + String(transform))


# =============================================================================
# murmur3_x86_32 — the Iceberg bucket-transform hash (spec Appendix B).
# =============================================================================
#
# Iceberg's `bucket[N]` transform is `(murmur3_x86_32(bytes, seed=0) &
# 0x7FFFFFFF) % N` over the value's canonical bytes:
#   int / long  -> the value as an 8-byte little-endian long (INTs are promoted
#                  to long before hashing, per the spec).
#   string      -> the UTF-8 bytes.
#   boolean/float/double -> not bucket-partitionable in the spec's canonical
#                  set; we support int/long/string buckets (the usual key shapes)
#                  and raise for the rest.
# This is the standard murmur3 32-bit x86 variant; matching it byte-for-byte is
# load-bearing so an external Iceberg engine derives the SAME bucket.


@always_inline
def _rotl32(x: UInt32, r: Int) -> UInt32:
    return (x << UInt32(r)) | (x >> UInt32(32 - r))


def murmur3_x86_32(data: List[UInt8], seed: UInt32) -> UInt32:
    """`murmur3_x86_32` over `data` with `seed` (Iceberg uses seed 0).

    A faithful port of the reference murmur3 x86 32-bit hash. Processes 4-byte
    blocks little-endian, then the tail, then finalizes with the standard
    fmix32 avalanche."""
    var c1 = UInt32(0xCC9E2D51)
    var c2 = UInt32(0x1B873593)
    var h1 = seed
    var length = len(data)
    var nblocks = length // 4

    # body — 4-byte little-endian blocks.
    for i in range(nblocks):
        var base = i * 4
        var k1 = (
            UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
        )
        k1 = k1 * c1
        k1 = _rotl32(k1, 15)
        k1 = k1 * c2
        h1 = h1 ^ k1
        h1 = _rotl32(h1, 13)
        h1 = h1 * UInt32(5) + UInt32(0xE6546B64)

    # tail (0..3 remaining bytes).
    var tail_index = nblocks * 4
    var k1 = UInt32(0)
    var rem = length - tail_index
    if rem == 3:
        k1 = k1 ^ (UInt32(data[tail_index + 2]) << 16)
    if rem >= 2:
        k1 = k1 ^ (UInt32(data[tail_index + 1]) << 8)
    if rem >= 1:
        k1 = k1 ^ UInt32(data[tail_index])
        k1 = k1 * c1
        k1 = _rotl32(k1, 15)
        k1 = k1 * c2
        h1 = h1 ^ k1

    # finalization (fmix32).
    h1 = h1 ^ UInt32(length)
    h1 = h1 ^ (h1 >> UInt32(16))
    h1 = h1 * UInt32(0x85EBCA6B)
    h1 = h1 ^ (h1 >> UInt32(13))
    h1 = h1 * UInt32(0xC2B2AE35)
    h1 = h1 ^ (h1 >> UInt32(16))
    return h1


def _iceberg_bucket_bytes(cell: RowCell, type_tag: Int) raises -> List[UInt8]:
    """The canonical bytes Iceberg hashes for the BUCKET transform.

    int / long -> 8-byte little-endian long (INT promoted to long per spec).
    string     -> UTF-8 bytes.
    Other types are not in the bucket set -> raise."""
    var out = List[UInt8]()
    if type_tag == ICE_T_INT or type_tag == ICE_T_LONG:
        var v = cell.as_long()
        var u = UInt64(v)
        for i in range(8):
            out.append(UInt8((u >> UInt64(i * 8)) & UInt64(0xFF)))
        return out^
    elif type_tag == ICE_T_STRING:
        var s = cell.as_string()
        var bs = s.as_bytes()
        for i in range(len(bs)):
            out.append(bs[i])
        return out^
    raise Error(
        "iceberg bucket transform: type tag "
        + String(type_tag)
        + " is not bucket-partitionable (only int/long/string keys)"
    )


def iceberg_bucket_of(cell: RowCell, type_tag: Int, buckets: Int) raises -> Int:
    """The Iceberg bucket index of `cell`: `(murmur3(bytes) & 0x7FFFFFFF) % N`.

    Matches the spec so an external engine derives the SAME bucket for the SAME
    value (load-bearing for cross-engine partition pruning).

    Raises on a null cell (a transform of null is null, and a null partition
    value is not supported: it would otherwise hash as 0 or "" and share a
    bucket with the real value) and on `buckets <= 0`."""
    if buckets <= 0:
        raise Error(
            "iceberg bucket transform: bucket count must be positive, got "
            + String(buckets)
        )
    if cell.is_null():
        raise Error(
            "iceberg bucket transform: a null value is not supported (null"
            " partition values are not written)"
        )
    var b = _iceberg_bucket_bytes(cell, type_tag)
    var h = murmur3_x86_32(b, UInt32(0))
    var pos = Int(h & UInt32(0x7FFFFFFF))
    return pos % buckets


# =============================================================================
# Per-row partition-value computation.
# =============================================================================


def _col_index_of_field_id(schema: IcebergSchema, field_id: Int) raises -> Int:
    for i in range(len(schema.fields)):
        if schema.fields[i].field_id == field_id:
            return i
    raise Error(
        "iceberg partition: source field-id "
        + String(field_id)
        + " not in the table schema"
    )


def partition_value_of(
    spec: PartitionSpec, schema: IcebergSchema, row: List[RowCell]
) raises -> List[RowCell]:
    """The partition tuple `row` belongs to, in partition-field order.

    For each partition field: IDENTITY yields the source cell verbatim (its
    declared type); BUCKET yields an INT cell holding the bucket index. The
    returned tuple is the value the manifest's `partition` struct records + the
    grouping key for per-partition data-file routing."""
    if len(row) != len(schema.fields):
        raise Error(
            "partition_value_of: row arity "
            + String(len(row))
            + " != schema column count "
            + String(len(schema.fields))
        )
    var out = List[RowCell]()
    for i in range(len(spec.fields)):
        ref pf = spec.fields[i]
        var ci = _col_index_of_field_id(schema, pf.source_field_id)
        var src_type = schema.fields[ci].type_tag
        if pf.transform == ICE_TRANSFORM_IDENTITY:
            if row[ci].is_null():
                raise Error(
                    "partition_value_of: null value in identity partition"
                    " source field-id "
                    + String(pf.source_field_id)
                    + " (null partition values are not supported)"
                )
            out.append(row[ci].copy())
        elif pf.transform == ICE_TRANSFORM_BUCKET:
            var b = iceberg_bucket_of(row[ci], src_type, pf.param)
            out.append(make_int_cell(Int32(b)))
        else:
            raise Error(
                "partition_value_of: unknown transform "
                + String(pf.transform)
            )
    return out^


def partition_value_type_tags(
    spec: PartitionSpec, schema: IcebergSchema
) raises -> List[Int]:
    """The type tags of the partition VALUES (in partition-field order).

    IDENTITY -> the source column's type; BUCKET -> INT. The manifest partition
    encoder + the partition-value decoder need these to (de)serialize the
    partition struct positionally."""
    var out = List[Int]()
    for i in range(len(spec.fields)):
        ref pf = spec.fields[i]
        if pf.transform == ICE_TRANSFORM_BUCKET:
            out.append(ICE_T_INT)
        else:  # IDENTITY
            var ci = _col_index_of_field_id(schema, pf.source_field_id)
            out.append(schema.fields[ci].type_tag)
    return out^


# =============================================================================
# Stable partition key (grouping + path fragment).
# =============================================================================


def partition_key_string(
    spec: PartitionSpec, values: List[RowCell]
) raises -> String:
    """A deterministic string key for a partition tuple.

    Names and values are percent-encoded (`_escape_path_token`) so the key is a
    safe path fragment. Used to (a) GROUP rows into per-partition data files (equal key == same
    file) and (b) build the data file's `col=value/...` path fragment (Iceberg's
    hive-ish partition directory — convenience for engines/humans; the manifest
    `partition` struct is the authoritative binding). Empty for an unpartitioned
    spec (a single file)."""
    if len(spec.fields) == 0:
        return String("")
    if len(values) != len(spec.fields):
        raise Error(
            "partition_key_string: "
            + String(len(values))
            + " values for "
            + String(len(spec.fields))
            + " partition fields"
        )
    var out = String("")
    for i in range(len(spec.fields)):
        if i > 0:
            out += "/"
        out += _escape_path_token(spec.fields[i].name)
        out += "="
        out += _escape_path_token(_cell_to_key_token(values[i]))
    return out^


def _escape_path_token(s: String) -> String:
    """Percent-encode every byte outside `[A-Za-z0-9._-]` as `%XX` (uppercase
    hex), so a partition value can never add a path separator (or `..`), `=`
    or any other structure to the key. The encoding is injective, so two
    different values never share a partition key."""
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        var b = Int(bs[i])
        var plain = (
            (b >= ord("a") and b <= ord("z"))
            or (b >= ord("A") and b <= ord("Z"))
            or (b >= ord("0") and b <= ord("9"))
            or b == ord(".")
            or b == ord("_")
            or b == ord("-")
        )
        if plain:
            out.append(UInt8(b))
        else:
            out.append(UInt8(ord("%")))
            out.append(_hex_upper((b >> 4) & 0xF))
            out.append(_hex_upper(b & 0xF))
    # SAFETY: only ASCII bytes are written (plain bytes are ASCII, escapes are
    # `%` and hex digits), so the result is valid UTF-8.
    return String(unsafe_from_utf8=Span(out))


@always_inline
def _hex_upper(nib: Int) -> UInt8:
    if nib < 10:
        return UInt8(0x30 + nib)
    return UInt8(0x41 + nib - 10)


def _cell_to_key_token(cell: RowCell) raises -> String:
    """A cell's stable string token for the partition path/key (type-agnostic:
    integral -> decimal, string -> the raw value, float -> decimal)."""
    if cell.is_null():
        raise Error(
            "partition key: a null value is not supported (it would share a"
            " key with the zero value)"
        )
    var t = cell.type_tag
    if t == ICE_T_STRING:
        return cell.as_string()
    elif t == ICE_T_FLOAT or t == ICE_T_DOUBLE:
        var d = cell.as_double()
        # -0.0 and +0.0 are equal values: one key.
        if d == Float64(0):
            return String("0.0")
        return String(d)
    else:  # BOOLEAN / INT / LONG
        return String(cell.as_long())


# =============================================================================
# Partition-value Avro encode (for the manifest partition struct).
# =============================================================================


def encode_partition_values(values: List[RowCell]) -> List[List[UInt8]]:
    """Pre-encode a partition tuple's cells to their Avro primitive form, one
    byte-blob per cell (in partition-field order).

    This is what `DataFileInfo.with_partition` stores + the manifest partition
    encoder concatenates positionally into the `r102` record. Kept here (where
    `RowCell` + `encode_cell` are visible) so iceberg_types stays free of a
    RowCell import cycle."""
    var out = List[List[UInt8]]()
    for i in range(len(values)):
        var blob = List[UInt8]()
        encode_cell(values[i], blob)
        out.append(blob^)
    return out^


# =============================================================================
# Per-partition data-file routing.
# =============================================================================


struct PartitionedDataFile(Copyable, Movable, Deinitable):
    """One partition's worth of rows (destined for ONE data file).

    Fields:
      var partition_values: List[RowCell]  — the partition tuple (typed).
      var partition_types: List[Int]       — the tuple's value type tags.
      var partition_avro: List[List[UInt8]]— the tuple pre-encoded to Avro
                                             (ready for `DataFileInfo`).
      var partition_key: String            — the col=value/... path fragment.
      var rows: List[List[RowCell]]        — the rows in this partition.
    """

    var partition_values: List[RowCell]
    var partition_types: List[Int]
    var partition_avro: List[List[UInt8]]
    var partition_key: String
    var rows: List[List[RowCell]]

    def __init__(
        out self,
        var partition_values: List[RowCell],
        var partition_types: List[Int],
        var partition_avro: List[List[UInt8]],
        var partition_key: String,
        var rows: List[List[RowCell]],
    ):
        self.partition_values = partition_values^
        self.partition_types = partition_types^
        self.partition_avro = partition_avro^
        self.partition_key = partition_key^
        self.rows = rows^

    def copy(self) -> Self:
        var pv = List[RowCell]()
        for i in range(len(self.partition_values)):
            pv.append(self.partition_values[i].copy())
        var pt = List[Int]()
        for i in range(len(self.partition_types)):
            pt.append(self.partition_types[i])
        var pa = List[List[UInt8]]()
        for i in range(len(self.partition_avro)):
            pa.append(self.partition_avro[i].copy())
        var rr = List[List[RowCell]]()
        for i in range(len(self.rows)):
            var row = List[RowCell]()
            for j in range(len(self.rows[i])):
                row.append(self.rows[i][j].copy())
            rr.append(row^)
        return Self(pv^, pt^, pa^, String(self.partition_key), rr^)


def route_rows_to_partitions(
    spec: PartitionSpec, schema: IcebergSchema, rows: List[List[RowCell]]
) raises -> List[PartitionedDataFile]:
    """Group `rows` into per-partition buckets by their partition-value tuple.

    Each returned `PartitionedDataFile` holds the rows that share ONE partition
    key (equal partition value == same file), plus that partition's typed +
    Avro-encoded value tuple + the col=value path fragment. For an unpartitioned
    spec, ALL rows land in one bucket with an empty partition tuple. A stable,
    linear group-by (first-seen order) — no hashing of the key beyond string
    equality, so the routing is deterministic + easy to reason about."""
    var partition_type_tags = partition_value_type_tags(spec, schema)
    var keys = List[String]()  # partition_key per bucket (parallel to buckets)
    var buckets = List[PartitionedDataFile]()

    for ri in range(len(rows)):
        var pv = partition_value_of(spec, schema, rows[ri])
        var key = partition_key_string(spec, pv)
        # find or create the bucket for this key.
        var found = -1
        for bi in range(len(keys)):
            if keys[bi] == key:
                found = bi
                break
        if found < 0:
            var pt = List[Int]()
            for i in range(len(partition_type_tags)):
                pt.append(partition_type_tags[i])
            var pa = encode_partition_values(pv)
            var empty_rows = List[List[RowCell]]()
            buckets.append(
                PartitionedDataFile(
                    pv.copy(), pt^, pa^, String(key), empty_rows^
                )
            )
            keys.append(String(key))
            found = len(buckets) - 1
        # append the row into the bucket.
        var row_copy = List[RowCell]()
        for c in range(len(rows[ri])):
            row_copy.append(rows[ri][c].copy())
        buckets[found].rows.append(row_copy^)

    return buckets^
