# =============================================================================
# iceberg_avro_manifest_read.mojo — manifest list + manifest file decoders.
# =============================================================================
#
# The decode half of iceberg_avro_manifest.mojo (split to keep each file under
# the size the compiler handles well). Positional decoders for the manifests that
# `build_manifest_list` / `build_manifest_file` write.

from komira_avro.ocf_block_scan import scan_ocf_blocks
from komira_avro.varint_decode_scalar import AvroByteReader
from komira_avro.varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_string,
)

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
)
from .iceberg_avro_manifest import ManifestFileEntry
from .iceberg_row_value import read_checked_string


# =============================================================================
# Manifest LIST decode — recover the prior snapshot's manifests (append carry).
# =============================================================================
#
# An Iceberg append snapshot's manifest list must enumerate ALL live manifests
# (the new commit's manifest PLUS every manifest carried forward from the
# parent). To carry them forward without polluting metadata.json, we DECODE the
# parent snapshot's manifest list (a NULL-codec OCF we wrote ourselves) and
# re-emit its entries into the new list. We parse only the four fields we need
# to rebuild a `ManifestFileEntry` (manifest_path, manifest_length,
# added_files_count, added_rows_count); the remaining fields are skipped in
# declared order.


def read_manifest_list(bytes: List[UInt8]) raises -> List[ManifestFileEntry]:
    """Decode a v2 manifest LIST (NULL-codec OCF) into its `ManifestFileEntry`
    records. Used to carry forward the parent snapshot's manifests on append.

    Skips the fields not needed to rebuild the entry, IN DECLARED ORDER (Avro
    is positional): manifest_path(str), manifest_length(long),
    partition_spec_id(int), content(int), sequence_number(long),
    min_sequence_number(long), added_snapshot_id(long), added_files_count(int),
    existing_files_count(int), deleted_files_count(int), added_rows_count(long),
    existing_rows_count(long), deleted_rows_count(long),
    partitions(union null|array)."""
    var out = List[ManifestFileEntry]()
    var blocks = scan_ocf_blocks(Span(bytes))
    for bi in range(len(blocks)):
        ref blk = blocks[bi]
        var start = blk.payload_offset
        var end = start + blk.payload_len
        var reader = AvroByteReader(Span(bytes)[start:end])
        var rec = 0
        var nrec = Int(blk.object_count)
        while rec < nrec:
            var manifest_path = read_checked_string(reader)
            var manifest_length = Int(reader.read_long())
            var spec_id = Int(reader.read_int())  # partition_spec_id
            var content = Int(reader.read_int())  # content (data / deletes)
            var seq = reader.read_long()  # sequence_number
            _ = reader.read_long()  # min_sequence_number
            var added_snap = reader.read_long()  # added_snapshot_id
            var added_files = Int(reader.read_int())  # added_files_count
            _ = reader.read_int()  # existing_files_count
            _ = reader.read_int()  # deleted_files_count
            var added_rows = reader.read_long()  # added_rows_count
            _ = reader.read_long()  # existing_rows_count
            _ = reader.read_long()  # deleted_rows_count
            # partitions: union ["null", array]; we always wrote null (tag 0).
            var part_tag = reader.read_long()
            if part_tag != Int64(0):
                # present array — skip it (block-count then items). We never
                # write partitions (unpartitioned), so this is defensive.
                raise Error(
                    "read_manifest_list: unexpected non-null partitions in a"
                    " file-based unpartitioned manifest list"
                )
            out.append(
                ManifestFileEntry(
                    manifest_path^,
                    manifest_length,
                    added_files,
                    added_rows,
                    content,
                    seq,
                    added_snap,
                    spec_id,
                )
            )
            rec += 1
    return out^


# =============================================================================
# Manifest FILE decode — recover each data/delete file's content + sequence
# number + equality_ids (the merge-on-read reader's entry point).
# =============================================================================
#
# The reader walks metadata.json -> snapshot -> manifest LIST -> each manifest
# FILE, and for each `manifest_entry` needs the data_file's `file_path`,
# `content`, its OWN `sequence_number`, `record_count`, and (for equality
# deletes) `equality_ids`. `read_manifest_entries` decodes exactly those,
# skipping the stat maps in DECLARED ORDER (Avro is positional). This is the
# decode-symmetric inverse of `encode_manifest_entry`.


struct ManifestEntry(Copyable, Movable, Deinitable):
    """One decoded `manifest_entry` — what the merge-on-read reader needs.

    Fields:
      var file_path: String        — the data/delete file's object key.
      var content: Int             — 0 data / 1 position-delete / 2 equality.
      var sequence_number: Int64   — the entry's data sequence number.
      var record_count: Int        — rows in the file.
      var file_size_in_bytes: Int  — byte size.
      var equality_ids: List[Int]  — equality-match field-ids (empty unless the
                                     entry is an equality-delete file).
      var partition_avro: List[List[UInt8]]
                                   — this file's partition-value tuple's raw Avro
                                     bytes (one blob per partition field, in
                                     order). Empty for an unpartitioned file.
                                     Decoded to typed values by
                                     `read_partition_values_from_manifest`.
      var status: Int              — the entry's status: ICE_STATUS_ADDED (1) for
                                     everything this package writes.
    """

    var file_path: String
    var content: Int
    var sequence_number: Int64
    var record_count: Int
    var file_size_in_bytes: Int
    var equality_ids: List[Int]
    var partition_avro: List[List[UInt8]]
    var status: Int

    def __init__(
        out self,
        var file_path: String,
        content: Int,
        sequence_number: Int64,
        record_count: Int,
        file_size_in_bytes: Int,
        var equality_ids: List[Int],
        status: Int = 1,
    ):
        """6-arg ctor — no partition tuple (unpartitioned / the append path +
        every existing caller). partition_avro defaults empty."""
        self.file_path = file_path^
        self.content = content
        self.sequence_number = sequence_number
        self.record_count = record_count
        self.file_size_in_bytes = file_size_in_bytes
        self.equality_ids = equality_ids^
        self.partition_avro = List[List[UInt8]]()
        self.status = status

    def __init__(
        out self,
        var file_path: String,
        content: Int,
        sequence_number: Int64,
        record_count: Int,
        file_size_in_bytes: Int,
        var equality_ids: List[Int],
        var partition_avro: List[List[UInt8]],
        status: Int = 1,
    ):
        """7-arg ctor — carries the partition tuple's raw Avro bytes (the
        partitioned read path)."""
        self.file_path = file_path^
        self.content = content
        self.sequence_number = sequence_number
        self.record_count = record_count
        self.file_size_in_bytes = file_size_in_bytes
        self.equality_ids = equality_ids^
        self.partition_avro = partition_avro^
        self.status = status

    def copy(self) -> Self:
        var eids = List[Int]()
        for i in range(len(self.equality_ids)):
            eids.append(self.equality_ids[i])
        var pa = List[List[UInt8]]()
        for i in range(len(self.partition_avro)):
            pa.append(self.partition_avro[i].copy())
        return Self(
            String(self.file_path),
            self.content,
            self.sequence_number,
            self.record_count,
            self.file_size_in_bytes,
            eids^,
            pa^,
            self.status,
        )


def _skip_optional_int_keyed_map[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o], value_is_bytes: Bool) raises:
    """Skip one `["null", array<{key:int, value:(long|bytes)}>]` optional map.

    Reads the union tag; on the present branch (1) walks the Avro array blocks
    (a `long` count, then that many {int, long|bytes} items, repeated until a
    0-count block)."""
    var tag = reader.read_long()
    if tag == Int64(0):
        return
    while True:
        var count = reader.read_long()
        if count == Int64(0):
            break
        var n = Int(count)
        if n < 0:
            # Avro negative block-count == abs(count) items + a following
            # block-size long we can ignore (we still read every item).
            n = -n
            _ = reader.read_long()  # block byte size
        for _i in range(n):
            _ = reader.read_int()  # key
            if value_is_bytes:
                _ = reader.read_bytes()  # value (bytes)
            else:
                _ = reader.read_long()  # value (long)


def _skip_optional_long_array[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o]) raises:
    """Skip one `["null", array<long>]` optional (e.g. split_offsets)."""
    var tag = reader.read_long()
    if tag == Int64(0):
        return
    while True:
        var count = reader.read_long()
        if count == Int64(0):
            break
        var n = Int(count)
        if n < 0:
            n = -n
            _ = reader.read_long()
        for _i in range(n):
            _ = reader.read_long()


def _read_optional_int_array[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o]) raises -> List[Int]:
    """Read one `["null", array<int>]` optional (equality_ids) -> List[Int]."""
    var out = List[Int]()
    var tag = reader.read_long()
    if tag == Int64(0):
        return out^
    while True:
        var count = reader.read_long()
        if count == Int64(0):
            break
        var n = Int(count)
        if n < 0:
            n = -n
            _ = reader.read_long()
        for _i in range(n):
            out.append(Int(reader.read_int()))
    return out^


def _read_partition_value_bytes[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o], type_tag: Int) raises -> List[UInt8]:
    """Read one partition value of `type_tag` from `reader` and RE-ENCODE it to
    its Avro primitive bytes (the same form the writer emitted).

    We round-trip through the typed read + a re-encode so the reader recovers
    the exact byte blob the writer stored on `DataFileInfo.partition_avro`
    (symmetric with `encode_partition_values`). This keeps the partition-value
    decode independent of the AvroByteReader's internal cursor arithmetic."""
    var out = List[UInt8]()
    if type_tag == ICE_T_BOOLEAN:
        encode_boolean(reader.read_boolean(), out)
    elif type_tag == ICE_T_INT:
        encode_int(reader.read_int(), out)
    elif type_tag == ICE_T_LONG:
        encode_long(reader.read_long(), out)
    elif type_tag == ICE_T_FLOAT:
        encode_float(reader.read_float(), out)
    elif type_tag == ICE_T_DOUBLE:
        encode_double(reader.read_double(), out)
    elif type_tag == ICE_T_STRING:
        encode_string(read_checked_string(reader), out)
    else:
        raise Error(
            "_read_partition_value_bytes: unknown partition type tag "
            + String(type_tag)
        )
    return out^


def read_manifest_entries(
    bytes: List[UInt8], partition_value_types: List[Int] = List[Int]()
) raises -> List[ManifestEntry]:
    """Decode a v2 manifest FILE (NULL-codec OCF) into `ManifestEntry` records.

    Decodes each `manifest_entry` in DECLARED ORDER (Avro is positional):
      status(int), snapshot_id(union), sequence_number(union),
      file_sequence_number(union), then the data_file (r2) struct:
        content(int), file_path(str), file_format(str), partition(r102),
        record_count(long), file_size_in_bytes(long),
        column_sizes / value_counts / null_value_counts / nan_value_counts
        (optional int-keyed maps), lower_bounds / upper_bounds (optional
        int->bytes maps), key_metadata(["null","bytes"]),
        split_offsets(["null",array<long>]),
        equality_ids(["null",array<int>]), sort_order_id(["null","int"]).
    The stat maps are skipped; content + sequence_number + record_count +
    file_size + equality_ids + the partition tuple are captured.

    `partition_value_types` (default empty = unpartitioned) gives the partition
    struct's VALUE type tags in partition-field order so the reader consumes the
    partition record's bytes correctly (empty -> zero bytes, the unpartitioned form).
    The recovered raw partition bytes are stored on `ManifestEntry.partition_avro`
    for `read_partition_values_from_manifest`."""
    var out = List[ManifestEntry]()
    var blocks = scan_ocf_blocks(Span(bytes))
    for bi in range(len(blocks)):
        ref blk = blocks[bi]
        var start = blk.payload_offset
        var end = start + blk.payload_len
        var reader = AvroByteReader(Span(bytes)[start:end])
        var rec = 0
        var nrec = Int(blk.object_count)
        while rec < nrec:
            var status = Int(reader.read_int())  # status
            # snapshot_id (["null","long"])
            if reader.read_long() != Int64(0):
                _ = reader.read_long()
            # sequence_number (["null","long"])
            var seq = Int64(0)
            if reader.read_long() != Int64(0):
                seq = reader.read_long()
            # file_sequence_number (["null","long"])
            if reader.read_long() != Int64(0):
                _ = reader.read_long()

            # ---- data_file (r2) ----
            var content = Int(reader.read_int())  # content
            var file_path = read_checked_string(reader)  # file_path
            _ = reader.read_bytes()  # file_format
            # partition (r102): one value per partition field (empty for an
            # unpartitioned table -> zero bytes). Recover each value's raw Avro
            # bytes so the caller can decode the partition tuple.
            var partition_avro = List[List[UInt8]]()
            for pi in range(len(partition_value_types)):
                partition_avro.append(
                    _read_partition_value_bytes(
                        reader, partition_value_types[pi]
                    )
                )
            var record_count = Int(reader.read_long())  # record_count
            var file_size = Int(reader.read_long())  # file_size_in_bytes
            _skip_optional_int_keyed_map(reader, False)  # column_sizes
            _skip_optional_int_keyed_map(reader, False)  # value_counts
            _skip_optional_int_keyed_map(reader, False)  # null_value_counts
            _skip_optional_int_keyed_map(reader, False)  # nan_value_counts
            _skip_optional_int_keyed_map(reader, True)  # lower_bounds
            _skip_optional_int_keyed_map(reader, True)  # upper_bounds
            # key_metadata (["null","bytes"])
            if reader.read_long() != Int64(0):
                _ = reader.read_bytes()
            _skip_optional_long_array(reader)  # split_offsets
            var equality_ids = _read_optional_int_array(reader)  # equality_ids
            # sort_order_id (["null","int"])
            if reader.read_long() != Int64(0):
                _ = reader.read_int()

            out.append(
                ManifestEntry(
                    file_path^,
                    content,
                    seq,
                    record_count,
                    file_size,
                    equality_ids^,
                    partition_avro^,
                    status,
                )
            )
            rec += 1
    return out^
