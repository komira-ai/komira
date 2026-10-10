# =============================================================================
# Bloom Filter Reader — load + decode SBBF bloom filters from Parquet files
# =============================================================================
#
# Loads the Thrift-encoded BloomFilterHeader followed by the raw SBBF bitset
# bytes for a given column chunk, materialized as a `BloomFilter` instance
# ready for `might_contain_*` membership tests.
#
# Wire format (parquet-format BloomFilter.md):
#
#   [ BloomFilterHeader as Thrift compact struct:
#         field 1 (i32):    numBytes
#         field 2 (struct): BloomFilterAlgorithm (union: SPLIT_BLOCK_ALGORITHM)
#         field 3 (struct): BloomFilterHash (union: XXHASH)
#         field 4 (struct): BloomFilterCompression (union: UNCOMPRESSED)
#     ][ numBytes raw bitset bytes ]
#
# Each column chunk's `ColumnMetaData.bloom_filter_offset` /
# `.bloom_filter_length` (Thrift fields 14 + 15) point at the
# BloomFilterHeader byte range. `bloom_filter_length` covers BOTH the
# Thrift header AND the raw bitset bytes.
#
# The spec's hash is xxHash64, and every bloom filter is read with it.
# =============================================================================

from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily

from komira_fs.file_system import FileSystem
from .file_reader import ParquetFileReader
from .thrift_compact import ThriftCompactReader
from komira_parquet_api.metadata import ColumnMetaData


# =============================================================================
# Thrift decoder for BloomFilterHeader
# =============================================================================


struct BloomFilterHeaderInfo(Movable, Copyable):
    """Decoded BloomFilterHeader.

    Fields:
        num_bytes: Size of the raw bitset that follows the header,
                   in bytes. From field 1 (i32).
        algorithm_ok: True iff the parsed algorithm was
                      SPLIT_BLOCK_ALGORITHM (field 2 -> field 1).
                      False = unknown algorithm => bloom is unusable.
        hash_ok: True iff the parsed hash function was XXHASH
                 (field 3 -> field 1). Informational: the caller passes the
                 hash family to `load_bloom_filter`.
        compression_ok: True iff the bitset compression was UNCOMPRESSED
                        (field 4 -> field 1). False = compressed bloom
                        (not supported).
        header_byte_length: Number of bytes consumed parsing the Thrift
                            header. The raw bitset starts at this offset
                            from the start of the header byte range.
    """

    var num_bytes: Int
    var algorithm_ok: Bool
    var hash_ok: Bool
    var compression_ok: Bool
    var header_byte_length: Int

    def __init__(
        out self,
        num_bytes: Int = 0,
        algorithm_ok: Bool = False,
        hash_ok: Bool = False,
        compression_ok: Bool = False,
        header_byte_length: Int = 0,
    ):
        self.num_bytes = num_bytes
        self.algorithm_ok = algorithm_ok
        self.hash_ok = hash_ok
        self.compression_ok = compression_ok
        self.header_byte_length = header_byte_length


def _parse_union_variant[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Bool:
    """Read a single-variant union struct and return True iff the
    variant ID is exactly 1.

    Used for the three union-shaped fields of BloomFilterHeader
    (BloomFilterAlgorithm, BloomFilterHash, BloomFilterCompression).
    The writer emits them as `struct { field 1: empty struct }`. We
    consider the variant "ok" iff field 1 was present (matches
    SPLIT_BLOCK_ALGORITHM / XXHASH / UNCOMPRESSED). Anything else
    (different variant, no variant) returns False.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var variant_is_one = False
    for _ in range(64):
        var fld = reader._read_field_header()
        var fid = fld[0]
        var wt = fld[1]
        if wt == 0:
            break
        if fid == 1:
            variant_is_one = True
        # Consume the variant payload regardless of which variant fired.
        reader._skip_field(wt)
    reader.prev_field_id = saved
    return variant_is_one


def parse_bloom_filter_header[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> BloomFilterHeaderInfo:
    """Parse a Thrift compact BloomFilterHeader at the reader's cursor.

    Advances `reader.pos` past the entire header (including the trailing
    STOP byte). Returns the decoded numBytes + algorithm / hash /
    compression validity flags. The raw bitset begins at the NEW reader
    position after this call returns.
    """
    var start_pos = reader.pos
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var num_bytes = 0
    var algorithm_ok = False
    var hash_ok = False
    var compression_ok = False

    # Header fields are bounded to 4 (parquet.thrift). Cap the loop at 64
    # for paranoia (matches the rest of the parser).
    for _ in range(64):
        var fld = reader._read_field_header()
        var fid = fld[0]
        var wt = fld[1]
        if wt == 0:
            break
        if fid == 1 and wt == 5:
            num_bytes = reader._read_zigzag()
        elif fid == 1 and wt == 6:
            # Forward-compat: accept i64 zigzag for numBytes.
            num_bytes = reader._read_zigzag()
        elif fid == 2 and wt == 12:
            algorithm_ok = _parse_union_variant(reader)
        elif fid == 3 and wt == 12:
            hash_ok = _parse_union_variant(reader)
        elif fid == 4 and wt == 12:
            compression_ok = _parse_union_variant(reader)
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return BloomFilterHeaderInfo(
        num_bytes=num_bytes,
        algorithm_ok=algorithm_ok,
        hash_ok=hash_ok,
        compression_ok=compression_ok,
        header_byte_length=reader.pos - start_pos,
    )


# =============================================================================
# Load-from-disk helper
# =============================================================================


def load_bloom_filter[fs_o: FileSystem](
    ref file: ParquetFileReader[fs_o],
    column_meta: ColumnMetaData,
    hash_family: HashFamily = HashFamily.xxhash64(),
) raises -> Optional[BloomFilter]:
    """Load + materialize the BloomFilter for one column chunk.

    Args:
        file: Open Parquet file reader.
        column_meta: Column chunk metadata (carries bloom offset + length).
        hash_family: Hash function used by the writer. Default XXHASH64
            (the spec's hash).

    Returns:
      - None when:
        - `column_meta.bloom_filter_offset` / `.bloom_filter_length` is
          absent (no bloom for this column),
        - the Thrift header decodes to a non-SBBF algorithm or compressed
          bitset (currently unsupported),
        - the byte range is unreadable / truncated.
      - Some(BloomFilter) on success. The returned filter carries the
        requested `hash_family`; subsequent `might_contain_*` calls
        will hash with that function.

    The returned BloomFilter is `Movable` (not Copyable) — callers
    typically store it in an `Optional` or move it into a per-(file,
    rg, col) cache slot.
    """
    var bf_off_opt = column_meta.bloom_filter_offset
    var bf_len_opt = column_meta.bloom_filter_length
    if not bf_off_opt or not bf_len_opt:
        return None
    var bf_off = bf_off_opt.value()
    var bf_len = bf_len_opt.value()
    if bf_off <= 0 or bf_len <= 0:
        return None

    # Read the entire (header + bitset) byte range at once. Bloom byte
    # ranges are tiny relative to row group reads (typically ~1-32 KB).
    var buf = file.read_bytes(bf_off, bf_len)
    var view = buf.view_range_ro(0, bf_len)
    var reader = ThriftCompactReader(view)
    var header = parse_bloom_filter_header(reader)

    if not header.algorithm_ok:
        return None
    if not header.compression_ok:
        return None
    if header.num_bytes <= 0:
        return None

    var bitset_start = header.header_byte_length
    var bitset_end = bitset_start + header.num_bytes
    if bitset_end > bf_len:
        # Truncated / corrupt header advertising more bytes than the
        # column-chunk meta promised. Conservative: drop the bloom.
        return None

    # Materialize a BloomFilter wrapping the bitset bytes. `from_bytes`
    # round-trips the SBBF bitset layout (32-byte blocks, 8 x UInt32
    # little-endian words per block) used by both write and read sides.
    #
    # SAFETY: `buf` is owned by this stack frame; `view_range_ro` returns
    # a ByteView origin-tied to it; the `_unsafe_ptr()` here is used solely
    # to bridge BloomFilter.from_bytes, which takes an
    # `UnsafePointer[UInt8, _]`. `buf` outlives the from_bytes call (the
    # BloomFilter copies the bytes).
    var bitset_view = buf.view_range_ro(bitset_start, header.num_bytes)
    var bf = BloomFilter.from_bytes(
        bitset_view._unsafe_ptr(), header.num_bytes, hash_family,
    )
    return Optional(bf^)


# =============================================================================
# Bloom hash-family detection
# =============================================================================
#
# The parquet-format spec mandates xxHash64, and every writer this reader
# knows of (this project's, DuckDB, pyarrow / arrow-cpp, parquet-rs, Spark)
# uses it, so the hash family does not depend on the writer.
# =============================================================================


@always_inline
def detect_hash_family(created_by: String) -> HashFamily:
    """Map a Parquet writer's `created_by` string to the bloom hash family.

    Always XXHASH64, the parquet-format spec's hash; `created_by` names no
    writer that hashes otherwise.
    """
    _ = created_by
    return HashFamily.xxhash64()


@always_inline
def detect_hash_family_optional(created_by: Optional[String]) -> HashFamily:
    """Optional-aware wrapper around `detect_hash_family`. None /
    absent created_by -> XXHASH64 (spec default)."""
    if not created_by:
        return HashFamily.xxhash64()
    return detect_hash_family(created_by.value())
