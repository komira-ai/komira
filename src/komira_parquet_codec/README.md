# komira_parquet_codec

Parquet page compression.

- `compression`: `decompress(codec, ...)` and `compress(codec, ...)` dispatch
  on a `CompressionCodec` from `komira_parquet_api`, and `compress_bound`
  sizes a compression output. Supported: UNCOMPRESSED, SNAPPY, GZIP, ZSTD and
  LZ4_RAW both ways; the deprecated LZ4 (codec id 5) and BROTLI read only. LZO
  is refused. Codec id 5 is decoded by structure, across the three framings
  writers have used for it (Hadoop block prefix, LZ4 frame, bare raw block).
  The same module holds the LZ4 frame entries (`decompress_lz4_frame`,
  `compress_lz4_frame`, `lz4_frame_compress_bound`) and the `.lz4` text-file
  framing check (`lz4_text_framing_of`, `lz4_frame_declared_content_size`).
- `snappy`: the snappy codec. Compression and the default decoder call the
  snappy C API; a Mojo decoder of the same format can be selected instead.
  `kSlopBytes` is the output slop a page decoder adds for that decoder.
- `crc32c`: CRC-32C (Castagnoli). This is not the Parquet page checksum:
  `PageHeader.crc` is the standard CRC-32 of gzip and zlib.

## Native libraries

snappy is linked statically from `//third_party/snappy`, so no libsnappy is
needed at run time. Everything else is opened by name with `dlopen` at first
use, as `komira_avro` does for its codecs, and must be installed on the
machine that runs the code:

| codec | library | through |
|---|---|---|
| LZ4_RAW, LZ4 | `liblz4.so.1` (`liblz4.dylib`) | `komira_lz4` and this package's LZ4 frame shim |
| GZIP | `libz.so.1` (`libz.dylib`) | `komira_zlib` |
| ZSTD | `libzstd.so.1` (`libzstd.dylib`) | this package |
| BROTLI | `libbrotlidec.so.1` (`libbrotlidec.dylib`) | this package |

A missing library aborts the process at the first call that needs it.
