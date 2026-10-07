# komira_parquet_codec

Parquet page compression.

- `compression`: `decompress(codec, input, output)` and
  `compress(codec, input, output)` dispatch on a `CompressionCodec` from
  `komira_parquet_api`, and `compress_bound` sizes a compression output.
  Supported: UNCOMPRESSED, SNAPPY, GZIP, ZSTD and LZ4_RAW both ways; the
  deprecated LZ4 (codec id 5) and BROTLI read only. LZO is refused. Codec id 5
  is decoded by structure, across the three framings writers have used for it
  (Hadoop block prefix, LZ4 frame, bare raw block). The same module holds the
  LZ4 frame entries (`decompress_lz4_frame`, `compress_lz4_frame`,
  `lz4_frame_compress_bound`) and the `.lz4` text-file framing check
  (`lz4_text_framing_of`, `lz4_frame_declared_content_size`).
- `snappy`: the snappy codec. Compression and the default decoder call the
  snappy C API; `set_snappy_decoder(SnappyDecoder.MOJO)` selects a Mojo
  decoder of the same format for the whole process instead. The choice is
  never read from the environment: a program that wants it configurable maps
  its own flag to the setter. `kSlopBytes` is the output slop a page decoder
  adds so the Mojo decoder's 16-byte fast paths run to the end of the page.
- `text_decompress`: `read_text_source_to_heap_buffer(path)` reads a
  line-oriented text file whole into a `SharedAlignedBuffer[HeapRegion]`,
  decompressing it when `is_compressed_text_path(path)` holds (`.csv`,
  `.jsonl`, `.ndjson` or `.json`, followed by `.gz`, `.zst` or `.lz4`, in any
  case). A `.lz4` file is read as an LZ4 frame or a raw block by its leading
  bytes. The output buffer starts from a gzip ISIZE trailer or an LZ4 frame's
  Content Size when there is one, else 4x the compressed size, and grows 4x
  per retry up to 16 GiB; an LZ4 frame error that is not a full destination
  is raised at once.
- `crc32c`: CRC-32C (Castagnoli). This is not the Parquet page checksum:
  `PageHeader.crc` is the standard CRC-32 of gzip and zlib (parquet.thrift).

Every entry takes `Span`s: the input, and a caller-owned output whose length
is the capacity; it returns the number of bytes written, and refuses an
output too small for the result. No public signature holds a raw pointer.

```mojo
from komira_parquet_api import CompressionCodec
from komira_parquet_codec import compress, compress_bound, decompress

var data: List[UInt8] = [1, 2, 3, 1, 2, 3, 1, 2, 3]
var packed = List[UInt8](length=compress_bound(CompressionCodec.ZSTD, len(data)), fill=0)
var n = compress(CompressionCodec.ZSTD, Span(data), Span(packed))
var out = List[UInt8](length=len(data), fill=0)
_ = decompress(CompressionCodec.ZSTD, Span(packed)[0:n], Span(out))
```

## Native libraries

snappy and the Brotli decoder are linked statically, from
`//third_party/snappy` (through `komira_compression`) and
`//third_party/brotli`, so neither library is needed at run time. Everything
else is opened by name with `dlopen` at first use by `komira_compression`,
which owns every codec library, and must be installed on the machine that
runs the code:

| codec | library | through |
|---|---|---|
| SNAPPY | linked | `komira_compression.snappy_block` |
| LZ4_RAW, LZ4 | `liblz4.so.1` (`liblz4.dylib`) | `komira_compression.lz4` |
| GZIP | `libz.so.1` (`libz.dylib`) | `komira_compression.zlib` |
| ZSTD | `libzstd.so.1` (`libzstd.dylib`) | `komira_compression.zstd_frame` |

A missing library aborts the process at the first call that needs it.

## Tests

The tests are welded into the build: the package cannot be built while one of
them fails. The LZ4, snappy and Brotli known answers come from pinned upstream
archives, extracted at build time and never copied here: the reference
liblz4's golden frame (`//third_party/pierrec-lz4`), google/snappy's
correctness corpus and corrupt blobs (`//third_party/snappy:testdata`), and
google/brotli's decoder test vectors (`//third_party/brotli:testdata`). The
small vectors are written in the tests: the gzip and zstd streams, each with
the command that made it; hand-built snappy short-offset blobs; and the
CRC-32C check values, with the publication they come from. The `text_decompress`
tests compress their fixtures in the test with this package's own codecs and
write them under `$TEST_TMPDIR`.

Whole Parquet files are the one committed fixture set:
`tests/fixtures/parquet` holds seven small files pyarrow wrote (GZIP, SNAPPY,
ZSTD and uncompressed; DATA_PAGE and DATA_PAGE_V2; INT96; a dictionary page
per row group; zero rows; page CRCs), with the generator script that wrote
them and a `SHA256SUMS`. `test_parquet_file_pages_e2e` walks every page of
each through the dispatch. No Brotli file is among them.
