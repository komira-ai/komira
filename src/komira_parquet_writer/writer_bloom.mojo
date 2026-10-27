# =============================================================================
# Bloom filter writer: a split-block bloom filter as Parquet bytes
# =============================================================================
#
# A column chunk's bloom filter sits between the column data and the page
# index section of the file:
#
#   [PAR1] [column chunks] [bloom filters] [ColumnIndex / OffsetIndex]
#   [FileMetaData footer] [footer length] [PAR1]
#
# Each filter is a Thrift BloomFilterHeader (numBytes, the SPLIT_BLOCK
# algorithm, the XXHASH hash, UNCOMPRESSED) followed by the raw bitset; the
# header's file offset and the total length go into the column chunk's
# `bloom_filter_offset` and `bloom_filter_length`.
#
# The header names XXHASH, so a filter built with another hash family cannot
# be written: a reader would probe it with the wrong hash and prune row groups
# that hold the value.
#
# Reference: parquet-format BloomFilter.md.
# =============================================================================

from komira_dynamic_filter.bloom_filter import BloomFilter

from .thrift_writer import ThriftCompactWriter


def serialize_bloom_filter_header(num_bytes: Int) -> List[UInt8]:
    """The Thrift BloomFilterHeader of a `num_bytes` SBBF bitset (SPLIT_BLOCK
    algorithm, XXHASH hash, UNCOMPRESSED)."""
    var w = ThriftCompactWriter()
    w.write_bloom_filter_header(num_bytes)
    return w.take_bytes()


def serialize_bloom_filter(
    bf: BloomFilter, mut out_header: List[UInt8], mut out_bitset: List[UInt8]
) raises:
    """Serialize `bf` into `out_header` and `out_bitset` (both replaced).

    Raises:
        Error: `bf` uses a hash other than xxHash64, the only one the
            header can declare.
    """
    if not bf.hash_family.is_xxhash64():
        raise Error(
            "serialize_bloom_filter: a Parquet bloom filter header declares"
            " XXHASH; this filter uses another hash family"
        )
    out_header = serialize_bloom_filter_header(bf.num_bytes)
    out_bitset = List[UInt8]()
    out_bitset.reserve(bf.num_bytes)
    if bf.num_bytes > 0:
        bf.data.view_range_ro(0, bf.num_bytes).copy_to(
            out_bitset, 0, bf.num_bytes
        )
