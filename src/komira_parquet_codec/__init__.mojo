"""`komira_parquet_codec`: Parquet page compression.

`decompress` and `compress` dispatch on a Parquet `CompressionCodec`
(UNCOMPRESSED, SNAPPY, GZIP, ZSTD, LZ4_RAW, the deprecated LZ4 for reading,
BROTLI for reading); `compress_bound` sizes a compression output. The LZ4
frame entries serve formats that carry LZ4 frames rather than Parquet pages
(Kafka record batches, `.lz4` text files). The snappy entries and
`kSlopBytes`, the output slop a page decoder adds for the snappy decoder,
are re-exported from the `snappy` subpackage.
"""

from .compression import (
    Lz4TextFraming,
    compress,
    compress_bound,
    compress_lz4_frame,
    decompress,
    decompress_lz4_frame,
    lz4_frame_compress_bound,
    lz4_frame_declared_content_size,
    lz4_text_framing_of,
    snappy_max_compressed_length,
    snappy_uncompressed_length,
)
from .snappy import kSlopBytes, snappy_compress, snappy_decompress
