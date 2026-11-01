# =============================================================================
# kafka_fetch_compress.mojo: compression of the Record* array of a Fetch batch.
# =============================================================================
#
# The mirror image of kafka_compression.mojo. On Fetch, the server may compress
# the returned Record* array and set the compression bits of the v2 RecordBatch
# `attributes`. Every Kafka client decompresses fetched batches itself, so a
# compressed Fetch is wire-compatible with any stock client.
#
# The codecs come from komira_compression, re-framed to what a Kafka broker
# emits (and what kafka_compression.mojo decodes):
#
#   gzip (1)   RFC 1952 gzip framing (`Gzip.compress_gzip_file`; the plain
#              `Gzip.compress` writes zlib framing, which Kafka clients
#              refuse).
#   snappy (2) the xerial framing: the 16-byte header (0x82 "SNAPPY" 0x00,
#              then the version and compatible-version int32s) and one
#              `[int32 block-len][raw snappy block]`. A single block is a
#              valid xerial frame.
#   lz4 (3)    one LZ4 frame (magic 0x184D2204).
#   zstd (4)   one standard zstd frame.
#
# Round trip with kafka_compression.mojo: for every codec g and payload p,
# `decompress_kafka_records(g, compress_kafka_records(g, p)) == p`.
#
# Every public signature takes and returns bytes (`Span[UInt8]` in,
# `List[UInt8]` out).
# =============================================================================


from komira_compression.compression_codecs import (
    Gzip,
    Lz4Frame,
    Snappy,
    Zstd,
)


# Kafka attributes compression-codec ids (bits 0-2 of the batch attributes).
comptime FETCH_COMPRESSION_NONE: Int = 0
comptime FETCH_COMPRESSION_GZIP: Int = 1
comptime FETCH_COMPRESSION_SNAPPY: Int = 2
comptime FETCH_COMPRESSION_LZ4: Int = 3
comptime FETCH_COMPRESSION_ZSTD: Int = 4


def _put_int32_be(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _compress_snappy_xerial(src: Span[UInt8, _]) raises -> List[UInt8]:
    """The xerial snappy framing: the 16-byte header, then one
    `[int32 block-len][raw snappy block]`."""
    var block = Snappy.compress(src)
    var out = List[UInt8]()
    out.reserve(16 + 4 + len(block))
    out.append(UInt8(0x82))
    out.append(UInt8(ord("S")))
    out.append(UInt8(ord("N")))
    out.append(UInt8(ord("A")))
    out.append(UInt8(ord("P")))
    out.append(UInt8(ord("P")))
    out.append(UInt8(ord("Y")))
    out.append(UInt8(0))
    _put_int32_be(out, 1)  # version
    _put_int32_be(out, 1)  # compatible version
    _put_int32_be(out, len(block))  # block length
    out.extend(Span(block))
    return out^


def compress_kafka_records(
    codec_id: Int, data: Span[UInt8, _]
) raises -> List[UInt8]:
    """Compress the plaintext Record* array of a Kafka v2 RecordBatch.

    `codec_id` is the value to set in attributes bits 0-2 (1 gzip, 2 snappy,
    3 lz4, 4 zstd). For `none` (0) the result is a copy of the input (the
    caller should emit an uncompressed batch instead). Raises on an
    unsupported id. Inverse of `decompress_kafka_records`."""
    if codec_id == FETCH_COMPRESSION_NONE:
        return List[UInt8](Span(data))
    elif codec_id == FETCH_COMPRESSION_GZIP:
        return Gzip.compress_gzip_file(data)
    elif codec_id == FETCH_COMPRESSION_SNAPPY:
        return _compress_snappy_xerial(data)
    elif codec_id == FETCH_COMPRESSION_LZ4:
        return Lz4Frame.compress(data)
    elif codec_id == FETCH_COMPRESSION_ZSTD:
        return Zstd.compress(data)
    else:
        raise Error(
            "kafka_fetch_compress: unsupported codec id "
            + String(codec_id)
            + " (expected 0=none/1=gzip/2=snappy/3=lz4/4=zstd)"
        )


def fetch_compression_codec_name(codec_id: Int) -> StaticString:
    """The codec's name, or "unknown" for an id outside 0-4."""
    if codec_id == FETCH_COMPRESSION_NONE:
        return "none"
    elif codec_id == FETCH_COMPRESSION_GZIP:
        return "gzip"
    elif codec_id == FETCH_COMPRESSION_SNAPPY:
        return "snappy"
    elif codec_id == FETCH_COMPRESSION_LZ4:
        return "lz4"
    elif codec_id == FETCH_COMPRESSION_ZSTD:
        return "zstd"
    return "unknown"
