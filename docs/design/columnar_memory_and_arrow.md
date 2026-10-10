# Columnar memory: Arrow buffers, columns and batches

## What is it for, and what is out of scope?

`komira_arrow` (over `komira_buffer`) holds the engine's data in memory in the [Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html): a column is a few byte buffers (values, offsets, a validity bitmap), and a batch is a schema plus columns. Readers, operators and writers across the tree pass data to each other as `RecordBatch` values.

The design idea is **one type-erased column over shared buffers**. A `Column` carries an `ArrowType` tag and its buffers, and typed arrays such as `PrimitiveArray[dtype]` are views built from it on demand. Each buffer is a `SharedAlignedBuffer`, a refcounted (`ArcPointer`) handle to a memory region, so sharing a column is a refcount bump. Copies happen only where a consumer contract needs them ([when](#when-does-reading-a-column-copy-its-bytes)).

Beside `komira_arrow`, `komira_arrow_ipc` holds the Arrow IPC encoder and decoder, the Arrow C Data Interface and dense and sparse tensors; `komira_compression` holds the compression codec bindings, `komira_simd` the SIMD kernels, `komira_collections` the typed collections the engine is built on, and `komira_scan_source` the plan-time description of a scan source. Three small packages sit beside them:

- `komira_atomic_alias` defines `AtomicI8`, `AtomicI32`, `AtomicI64`, `AtomicU8`, `AtomicU32` and `AtomicU64` as aliases of the standard library's `Atomic`.
- `komira_rowcell` defines `RowCell`, one typed table cell (boolean, 32- or 64-bit integer, float, double or string), and imports nothing from this repository.
- `komira_uuid` mints UUIDv7 identifiers (`Uuid`, `generate_uuidv7`, `Uuidv7Generator`) and reads the wall clock (`now_unix_ms`).

Out of scope:

- The plan IR and scalar evaluation in `src/komira_plan_expr/`, `src/komira_plan_ir/` and `src/komira_column_kernels/`, which are separate packages with their own designs.
- The worker traits and cancellation in `src/komira_async_api/`, which belong to the async runtime's design.
- Parquet decoding, the Arrow IPC file reader, and the spill codec with its bridge to column-native batches. They live in the file-format and engine libraries, which build on this one.

## How does it work?

Bytes enter as a heap allocation, a file mapping or a foreign C array, become refcounted buffers, and are grouped into columns, batches and tables:

```
new data ───► OwnedAlignedBuffer ──from_owned────────┐
file bytes ─► MmapRegion ──────────borrow_mmap_erased─┼─► SharedAlignedBuffer ─► Column ─► RecordBatch ─► Table
C arrays ───► copied by drain_record_batch_stream ────┘
Column ──as_* / share_as_*──► PrimitiveArray, StringArray, BooleanArray, ...
RecordBatch ──► IPC messages (encode_*) · C stream (build_record_batch_stream)
```

### How are bytes owned?

An `OwnedAlignedBuffer` is a single-owner allocation for new data. Its constructor rounds the capacity up to a multiple of 64 bytes, over-allocates a `List[UInt8]` by 63 bytes, and caches a pointer rounded up to a 64-byte boundary. The bytes start uninitialized; `zero()` clears them. A second constructor takes a `memory_advice` bitmask (`ADVICE_HUGEPAGE`, `ADVICE_POPULATE`, from `hugepage_span.mojo`) and applies it with `madvise(2)` to an allocation of 8 MiB (`HUGEPAGE_MIN_ALLOC_BYTES`) or more; the plain constructor passes `ADVICE_OFF` and applies none.

A `SharedAlignedBuffer[K]` is the shared form: an `ArcPointer[K]`, a byte offset, a length, and a pointer cached at construction. `K` is a `MemoryRegion`, a type that owns bytes and lends them as a `ByteView` tied to its own origin. Two types conform: `HeapRegion`, which owns a `List[UInt8]`, and `MmapRegion`, which owns a `PROT_READ`, `MAP_PRIVATE` file mapping. `SharedAlignedBuffer.from_owned` moves an `OwnedAlignedBuffer`'s bytes into a new `HeapRegion` without copying them. `share()` returns a second handle to the same bytes, and `share_range_as` returns one to a sub-range. A buffer built from an `OwnedAlignedBuffer` is 64-byte aligned; a borrowed one points wherever its source bytes are, and `is_aligned()` reports which.

A `Bitmap` is a validity bitmap: one bit per element, least significant bit first, and a set bit means the element is present. It wraps a `SharedAlignedBuffer`, and `Bitmap.create` starts with every bit clear.

### How is a column laid out?

A `Column` is one Arrow array of any type. It holds an `ArrowType`, a data buffer, optional offsets and validity, a length, a null count, an element offset, dictionary fields, and a `Slab` of child columns for list, struct, map and union types. `ArrowType` is a one-byte tag with 51 named values, ids 0 to 50: the Arrow types from `NULL` to `LARGE_LIST_VIEW`, plus `ERROR`, a marker for spreadsheet error values with no buffer layout of its own. Type parameters live beside the tag: `Field` carries the timestamp zone, decimal precision and scale, dictionary index type, union type ids and child names and types, and `Column` repeats the decimal precision and scale.

A dictionary column keeps its indices in the data buffer, 4 or 8 bytes wide, and its values in `_dict_data`. A string dictionary stores packed UTF-8 bytes with offsets; a numeric one stores a flat buffer of `int32`, `int64`, `float32` or `float64` values, and `is_numeric_dict()` tells them apart. `PrimitiveArray` and `StringArray` hold `SharedAlignedBuffer` and `Bitmap` fields like `Column`'s; `BooleanArray` holds its values as a `Bitmap`.

### When does reading a column copy its bytes?

Only when the result must start at offset 0 with its own validity, or must be owned outright:

| Operation | Copies? |
|---|---|
| `Column.share()` | No. Every buffer and child is shared, and `_offset` is kept. |
| `Column.deep_copy()` | Yes, every buffer, recursively. |
| `Column.slice(start, length)` | No. It raises unless `supports_zero_copy_slice()` holds, which it does for integer, floating-point, `DATE32`, `DATE64`, `TIMESTAMP*`, `DECIMAL128` and `DICTIONARY` columns. |
| `as_primitive[dtype]()`, no validity | No. It shares the column's window and returns an array at offset 0. |
| `as_primitive[dtype]()`, with validity | Yes. It copies the window's values and bits into new buffers at offset 0. |
| `share_as_primitive[dtype]()` | No. It raises for a column with validity, and keeps `_offset`. |

`as_primitive` also accepts a temporal column whose storage matches `dtype`: `DATE32`, `TIME32_*` and `INTERVAL_YEAR_MONTH` as `int32`, and `DATE64`, `TIME64_*`, durations, `INTERVAL_DAY_TIME` and timestamps as `int64`.

### How does a zero-copy mmap read keep the file mapped?

`SharedAlignedBuffer.borrow_mmap_erased` returns a `SharedAlignedBuffer[HeapRegion]` whose pointer aims into a mapped file, and stores an `ArcPointer[MmapRegion]` in its optional `_mmap_keepalive` field. The mapping lives until the last buffer holding that refcount drops, and `share()` clones both refcounts. Its callers include the Arrow IPC mmap decoder (`decode_record_batch_message_mmap`) and the local-file and Parquet readers of the I/O and file-format libraries.

The `Column.from_borrowed_*` constructors borrow more weakly. They wrap a `ByteView` with the `ByteView` overload of `SharedAlignedBuffer.from_borrowed_view`, which keeps nothing alive, so the source bytes must outlive the column; the zero-copy IPC decoder builds its columns this way. The other overload, `from_borrowed_view(owner, offset, length)`, clones `owner`'s region refcount and its `_mmap_keepalive`.

### How are batches and tables built?

A `Schema` stores its fields column-wise, one list per attribute (`_names`, `_arrow_types`, `_nullables`, ...), and a `Field` is one entry. A `RecordBatch` is a `Schema`, a `Slab[Column[HeapRegion]]` and a row count, and `RecordBatchBuilder` assembles one. A batch may carry a selection mask, a `BooleanArray` of live rows, while its columns keep every row. The Parquet source and some operators set one; a consumer either honours it or calls `materialize_selection_if_present` (`src/komira_column_kernels/compiler_helpers.mojo`) to gather the live rows first.

A `Table` is a query result: one schema and a `Slab[RecordBatch]` of chunks in output order. `to_record_batch` returns one batch, concatenating the chunks when there are several. `into_single_batch` does not concatenate: it returns the only chunk, returns an empty batch with the table's schema when there are none, and raises when there are more.

`ColumnNativeBatch` (`src/komira_arrow/column_native.mojo`) is a second batch type, used by engine stages such as sort, top-N, window and join probing. In wrapped mode it holds a `RecordBatch`'s columns, moved in without a copy. In contiguous mode it holds one body buffer in the layout the spill codec writes. The engine's spill layer converts between the two.

### How are Arrow IPC messages encoded and decoded?

`ipc_flatbuf.mojo` reads and writes the [Arrow IPC](https://arrow.apache.org/docs/format/Columnar.html#serialization-and-interprocess-communication-ipc) FlatBuffers metadata with its own `FlatbufWriter` and `FlatbufReader`, scoped to Arrow's message, schema, footer and tensor tables. The message functions build on it:

- **Encode.** `encode_schema_message`, `encode_record_batch_message` and `encode_footer_message` return one buffer each; `encode_record_batch_message_streaming` writes the body to a `BodySink`. The body and schema legs cover different types. The body leg, `encode_column`, writes 46 of the 51 types: it refuses the four view types by name, and `ERROR` has no arm. The schema leg, `encode_schema_message`, writes 38 and refuses 13: those five, plus `LIST`, `LARGE_LIST`, `FIXED_SIZE_LIST`, `FIXED_SIZE_BINARY`, `STRUCT`, `MAP`, `UNION_SPARSE` and `UNION_DENSE`. A stream carries only types both legs write, so 38 types can be written to one, `DECIMAL128` and `DECIMAL256` only when their `Field` states a precision.
- **Decode.** A record batch message does not carry column types, so the caller passes them from the schema message: a `List[ArrowType]`, or `ColumnTypeSpec`s for the nested decoders. `decode_record_batch_message` copies each buffer. `decode_record_batch_zerocopy` borrows into the frame. It accepts `NULL`, the fixed-width types `_fixed_width_bytes_for` sizes (integers, floats, dates, times, timestamps, durations, intervals and decimals), and `STRING`, `BINARY`, `LARGE_STRING` and `LARGE_BINARY`; every other type raises, `BOOL` and `DICTIONARY` included. It does not check the frame's compression codec. `decode_record_batch_message_nested_zerocopy` borrows nested columns and raises for view types and for a compressed body. `decode_record_batch_message_mmap` borrows into a mapping and also raises for a compressed body. The copying `decode_record_batch_message_nested` turns view types into their non-view equivalents.
- **Compress.** `encode_record_batch_message_compressed[C]` and `decompress_record_batch_frame[C]` take a codec that conforms to `ArrowIpcCompression`. Arrow IPC's `CompressionType` defines two codecs, `LZ4_FRAME` and `ZSTD`, and `Lz4Frame` and `Zstd[level]` carry their ids, 0 and 1. The third conformer, `Uncompressed`, carries `ARROW_IPC_CODEC_ID = -1`, a sentinel for "write no `BodyCompression` table". The compressed encoder's caller contract is that `C` is `Lz4Frame` or `Zstd[*]`; an uncompressed stream goes through the uncompressed encoder. The `_with_dispatcher` variants work on a `ParallelDispatch`.
- **Tensors.** `encode_tensor` and `encode_sparse_tensor` in `src/komira_arrow_ipc/` write Arrow's tensor messages. A tensor is not a column.

`compression_codecs.mojo` also defines `Snappy`, `Gzip`, `Lz4Raw`, `Lzo`, `Brotli` and `Zlib` for file formats. `Snappy` calls the snappy C API, linked statically into the binary (`//third_party/snappy:snappy` is a dep of `komira_compression`). `Zstd`, `Gzip`, `Lz4Raw` and `Lz4Frame` call `libzstd`, `libz` and `liblz4`, each loaded with `dlopen` once per process. `Lzo`, `Brotli` and `Zlib` raise.

### How do batches cross the Arrow C Data Interface?

`build_record_batch_stream` exports a `Slab[RecordBatch]` through the [C stream interface](https://arrow.apache.org/docs/format/CStreamInterface.html). The exported arrays point into the batches' own buffers: the root array's private state holds a `Column.share()` of each column, so the bytes live until the consumer calls `release`. It checks the schema's column types before it returns.

`drain_record_batch_stream` and `drain_c_abi_record_batch_stream` import a stream and copy every buffer. The second takes the four stream callbacks as C function pointers and calls the producer's `release` on every exit path, including a raise; it serves a caller that holds a stream from another shared library.

### What do the collections and SIMD kernels provide?

- `Slab[T]` is a growable array over a `List[UInt8]` whose destructor drops the live slots. `create_prefilled` and `init_slot` build slots in place, and `get_mut_interior(i)` returns a mutable reference through an immutable slab, for per-worker slots.
- `ByteView[origin]` is a byte range tied to its source's origin, with little-endian reads and writes.
- `BatchView[origin]`, `ColView` and `StringColumnView` are read-only typed views over a batch or column that cannot outlive it.
- `BloomFilter`, `ColumnBuilder[dtype]` and `MultiColumnBuilder` serve filtering and row-by-row column building.
- `src/komira_simd/` holds popcount, gather, compress, blend, bit-unpacking, validity-packing, pattern-copy and horizontal-add kernels, and `fast_copy_bytes`; `byte_class/` adds byte-level kernels such as byte equality, `memmem`, movemask and table lookup. The width-policy functions `komira_simd_width`, `komira_simd_width_bitpack` and `komira_simd_width_delta` halve the native vector width on AVX-512 builds unless the build defines `KOMIRA_SIMD_ALLOW_AVX512`, to avoid the clock drop some AVX-512 cores take on 512-bit instructions.

### How does a scan name its source?

`ScanBinding` (`src/komira_scan_source/scan_binding.mojo`) describes a scan at plan time. It holds a kind id that `scan_kind_id` hashes from a reverse-DNS name such as `"komira.arrow.ipc"`, opaque `ScanParams`, a schema, optional statistics and a fingerprint, and no data. The concrete sources in `src/komira_scan_source/` implement `SourceLike`. `SourceVariant` holds a `tag` and three optional arms: `ParquetSource`, `InMemorySource` and `ScanBinding`. The other five sources, `ArrowSource`, `AvroSource`, `CsvSource`, `JsonSource` and `OrcSource`, have no arm: `SourceVariant`'s constructors for them (`from_arrow_uncompressed`, `from_arrow_lz4_frame`, `from_arrow_zstd`, and an `__init__` for each of the other four) build a `ScanBinding`.

At execution, `ScanResolver` (`src/komira_scan_source/scan_resolver.mojo`) answers only identity and freshness, through `epoch`, `is_bound` and `resolve_snapshot`. Its refinement `ScanPayloadResolver` adds `payload_arc`, which returns a handle's batches as an `ArcPointer[Slab[RecordBatch]]`. `ScanRegistry` (`src/komira_scan_source/scan_registry.mojo`) is the one type in `komira_scan_source` that conforms to `ScanPayloadResolver`; the SDK's engine context holds one and binds in-memory sources into it. `scan_resolver.mojo` also describes a second tier, `ScanMorselResolver`, defined by the morsel scheduler, whose `open_scan` returns a scan's rows at execution. The five file kinds are not resolved: `ScanData.__init__` (`src/komira_plan_ir/logical_plan_variants.mojo`) reads the binding's `legacy_source_type` and `name` and turns them back into a legacy `SOURCE_*` type and a path.

## Why is it built this way?

### Why does a mapped batch stay heap-typed?

**Decision.** A zero-copy mmap buffer is a `SharedAlignedBuffer[HeapRegion]` that carries the mapping's refcount in `_mmap_keepalive`, not a `SharedAlignedBuffer[MmapRegion]`.

**Because.** `RecordBatch._columns` is `Slab[Column[HeapRegion]]`, and a `SharedAlignedBuffer[MmapRegion]` cannot be stored in a `SharedAlignedBuffer[HeapRegion]` field: they are distinct concrete types. The erased keepalive lets the whole column-to-batch chain stay heap-typed while the bytes stay in the page cache.

**Alternatives weighed.**

- Carry `K` through `RecordBatch`: every batch consumer changes, and the comment on `_mmap_keepalive` records that this approach hit a cross-module recursive type cycle.
- Copy mapped bytes into a new heap region: one allocation and one copy per buffer, per column, per batch.

**Revisit if.** `RecordBatch` becomes generic over its memory region.

### Why does `as_primitive` copy a nullable column?

**Decision.** `as_primitive` shares the window of a column without validity and copies a nullable one.

**Because.** The copy rebases values and validity to offset 0, and some consumers index a typed array's validity from bit 0, ignoring its `offset`; `column.mojo`'s header names three such sites. Without validity nothing reads from bit 0, so the share is safe, and it replaces a memory-bound copy on every call with a refcount bump.

**Alternatives weighed.**

- Share every column: the offset-blind validity readers would read the wrong bits.
- Copy every column: every call pays a copy of the window.

**Revisit if.** Every reader of a typed array's validity honours its offset.

### Why does C Data import copy while export shares?

**Decision.** Export hands out pointers into shared buffers; import copies every foreign buffer.

**Because.** An exported array's private state owns a `Column.share()` of its source, so the bytes outlive the export by construction. An imported batch retains no pointer into the producer's memory and stays valid after `release`, which makes it safe to hand to a plan that outlives the producer's cursor.

**Alternatives weighed.**

- Borrow foreign buffers on import: the batch's lifetime would hang on the producer's `release`, and a plan could outlive it.

**Revisit if.** Import cost dominates a workload, and a batch can hold a foreign release callback as its keepalive.

### Why are the IPC FlatBuffers hand-written?

**Decision.** `ipc_flatbuf.mojo` implements only the FlatBuffers encoding of Arrow's fixed metadata grammar.

**Because.** That grammar is small and stable, and a Mojo implementation needs no C dependency and no foreign call per message.

**Alternatives weighed.**

- A FlatBuffers C library through FFI: a new C dependency, seldom installed as a system library, a foreign call per message, and a general protocol where Arrow needs a fixed subset.

**Revisit if.** Arrow's message schemas change faster than this file can track.

### Why are the row cell and the atomic aliases separate packages?

**Decision.** `RowCell` and the `Atomic*` aliases live in their own dependency-free packages.

**Because.** `komira_snapshotter` needs only a cell and takes it from `komira_rowcell`, its one dependency; taking it from the Iceberg library would pull in that library's closure, which includes Parquet and the engine. `komira_atomic_alias/atypes.mojo` is the one file a compiler change to `Atomic` must edit.

**Alternatives weighed.**

- Keep `RowCell` in the Iceberg library: a client that needs only a cell builds Parquet and the query engine to get one.

**Revisit if.** A cell needs a type from another package, which would re-create that dependency.

## What must always hold?

- **A shared buffer is not written.** `share()` aliases bytes, and `SharedAlignedBuffer` has `write_*_at` and `store_simd`, so a write through one handle shows through all. `share()`'s docstring rests its correctness on buffers staying immutable on consumer paths. Not enforced.
- **A borrowed column does not outlive its source.** The `ByteView` overload of `SharedAlignedBuffer.from_borrowed_view`, which the `Column.from_borrowed_*` constructors use, keeps nothing alive. Not enforced.
- **A mapped buffer keeps its mapping.** `share()`, `share_range_as`, the `(owner, offset, length)` overload of `from_borrowed_view` and the copy constructor of `CopyableSharedAlignedBuffer` each clone `_mmap_keepalive`. `test_sab_borrowed_view_mmap_keepalive` pins the `from_borrowed_view` overload, `test_sab_share_range_window` pins `share_range_as`, and `test_copyable_sab_mmap_keepalive_copy` pins the copy constructor. None of the three test files that read `has_mmap_keepalive` calls `share()`, so its clone is not pinned.
- **A nullable `as_primitive` result starts at offset 0.** Pinned by `test_as_primitive_sliced_column_byte_equiv` and `test_column_view_elim_oracle`.
- **An exported stream outlives its source batches.** Pinned by `test_arrow_c_stream_export_independence`. The consumer must call `release` exactly once; nothing here checks that.
- **A foreign stream and its arrays are released.** Pinned by `test_arrow_c_stream_import_foreign_release`.
- **A selection mask is honoured.** Not enforced: a consumer that ignores it reads dropped rows. `test_selection_mask_c1` pins the mask API.
- **32-bit offsets do not wrap.** Producers that call `should_promote_offsets` switch to 64-bit offsets, and the `check_int32_offsets` guards raise. Pinned by `test_arrow_offset_overflow`.
- **A slab's first `len` slots are initialized.** Maintained inside `slab.mojo` and pinned by `test_slab`. `get_mut_interior` callers must touch disjoint slots and must not grow the slab while a reference lives; not enforced.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_buffer/memory_region.mojo` | The region trait | `MemoryRegion`; `HeapRegion`, `MmapRegion` in siblings |
| `src/komira_buffer/owned_aligned_buffer.mojo` | Single-owner buffers | `OwnedAlignedBuffer` |
| `src/komira_buffer/shared_aligned_buffer.mojo` | Refcounted buffers | `SharedAlignedBuffer`, `borrow_mmap_erased`, `share` |
| `src/komira_arrow/column.mojo` | The type-erased column | `Column`, `as_primitive`, `share`, `slice` |
| `src/komira_arrow/arrow_types.mojo` | Type tags | `ArrowType` |
| `src/komira_arrow/schema.mojo`, `record_batch.mojo`, `table.mojo` | Schemas, batches, results | `Field`, `Schema`, `RecordBatch`, `Table` |
| `src/komira_arrow_ipc/ipc_encoder_dispatch.mojo`, `ipc_decoder_dispatch.mojo` | IPC messages | `encode_record_batch_message`, `decode_record_batch_message` |
| `src/komira_arrow_ipc/ipc_flatbuf.mojo` | IPC metadata | `FlatbufWriter`, `FlatbufReader` |
| `src/komira_compression/compression_codecs.mojo` | Codec bindings | `Lz4Frame`, `Zstd`, `Snappy` |
| `src/komira_arrow_ipc/c_data_stream.mojo` | C stream export and import | `build_record_batch_stream`, `drain_record_batch_stream` |
| `src/komira_collections/slab.mojo` | Typed slab | `Slab` |
| `src/komira_simd/width_policy.mojo` | SIMD width policy | `komira_simd_width`, `komira_simd_width_bitpack`, `komira_simd_width_delta` |
| `src/komira_scan_source/scan_binding.mojo`, `scan_resolver.mojo`, `scan_registry.mojo` | Scan descriptions and resolution | `ScanBinding`, `ScanResolver`, `ScanRegistry` |
| `src/komira_rowcell/row_cell.mojo` | The table cell | `RowCell` |
| `src/komira_uuid/uuid.mojo`, `clock.mojo` | UUIDv7 and the wall clock | `Uuid`, `generate_uuidv7`, `now_unix_ms` |

Entry points:

- **Public API:** build columns with `Column.from_*`, group them with `RecordBatchBuilder`, read them back with `RecordBatch.column_as_*` or `Column.as_*`, and serialize with `encode_record_batch_message` or `build_record_batch_stream`.
- **Execution starts at:** the caller. The columnar code starts no threads; the `_with_dispatcher` variants run on a dispatcher the caller passes.

## How is it tested?

Each core package lists the files of its own `tests/` directory in the `test_srcs` of its target (`komira_arrow` in `src/komira_arrow/BUCK`, `komira_arrow_ipc`, `komira_buffer` and the rest likewise), so each runs as part of building the library (see [the `test_srcs` gate](../../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate)). `komira_uuid` and `komira_atomic_alias` do the same with `test_uuid_v7` and `test_atomic_alias_widths`. Run: `./buck2 build //src/komira_arrow:komira_arrow //src/komira_arrow_ipc:komira_arrow_ipc //src/komira_buffer:komira_buffer //src/komira_uuid:komira_uuid //src/komira_atomic_alias:komira_atomic_alias`.

Some of the core packages' tests and what they cover:

| Test | Covers |
|---|---|
| `test_arrow_ipc_pyarrow_parity` | Decoding IPC bytes that pyarrow wrote, from `src/komira_arrow_ipc/tests/fixtures/arrow_ipc/` |
| `test_arrow_ipc_type_census` | Which of the 50 type ids the encoder writes, refuses or has no arm for |
| `test_arrow_ipc_flatbuf_wire_canonical` | Lengths and offsets above 4 GiB in IPC metadata |
| `test_lz4_raw_conformer_roundtrip` | The `Lz4Raw` codec |
| `test_bitmap`, `test_bitmap_ops` | Validity bitmaps |
| `test_simd_gather`, `test_simd_popcount`, `test_fast_copy_byte_oracle` | SIMD kernels |

Not tested:

- `komira_rowcell` declares no tests.
- No test file calls `decode_record_batch_message_mmap`, `drain_c_abi_record_batch_stream`, or `komira_simd_width` or its `_bitpack` and `_delta` siblings by name.

## What are its limits and open questions?

- **Limit: three codecs raise.** `Lzo`, `Brotli` and `Zlib` raise on use.
- **Limit: a missing codec library aborts.** Each codec's first use `dlopen`s a versioned system library, such as `libzstd.so.1` on Linux, and calls `abort` if that fails.
- **Limit: view and nested types are read, not written.** The copying `decode_record_batch_message_nested` reads `BINARY_VIEW`, `UTF8_VIEW`, `LIST_VIEW` and `LARGE_LIST_VIEW` as their non-view types, and has arms for `LIST`, `LARGE_LIST`, `FIXED_SIZE_LIST`, `FIXED_SIZE_BINARY`, `STRUCT`, `MAP`, `UNION_SPARSE` and `UNION_DENSE`. `encode_schema_message` refuses all twelve, so no stream this encoder writes carries one, although `encode_column` writes bodies for the last eight.
- **Limit: zero-copy decoding is partial.** `decode_record_batch_zerocopy` accepts only `NULL`, fixed-width, `STRING`, `BINARY`, `LARGE_STRING` and `LARGE_BINARY` columns. The nested zero-copy decoder refuses view types, and it and the mmap decoder refuse compressed bodies; the copying decoders handle those.
- **Limit: the flat zero-copy decoder ignores compression.** `read_record_batch` records the frame's codec, and nothing in `decode_record_batch_zerocopy` reads it, so a compressed body is not refused and its columns borrow the compressed bytes. This comes from reading the code: no test decodes a compressed frame with it. Only tests call `decode_record_batch_zerocopy`.
- **Limit: the compressed encoders do not refuse `Uncompressed`.** `_encode_record_batch_message_compressed_impl` has no check on `C`: it passes `C.ARROW_IPC_CODEC_ID` to `write_body_compression`, which writes `UInt8(Int(codec_id) & 0xFF)`. With `Uncompressed` the `BodyCompression` codec byte is 0xFF, which the encoder's docstring says "is NOT valid Arrow IPC". `_encode_dictionary_batch_message_from_string_column_compressed_impl` passes the id the same way. The caller contract is the only guard. This comes from reading the code: no test passes `Uncompressed` to either compressed encoder.
- **Limit: file scans bypass the resolver.** Only in-memory sources are bound into a `ScanRegistry`. The five file kinds reach execution as a legacy `SOURCE_*` type and a path, and `ScanBinding`'s docstring, which says the payload is reached through "a resolver owned by the package that registered `kind_id`", describes a design the code does not have.
- **Limit: many types cannot be sliced without a copy.** `supports_zero_copy_slice()` is a whitelist that leaves out strings, binaries, booleans, `TIME*`, durations and nested types. Its docstring gives reasons for three: string and binary accessors read offsets from position 0, booleans are bit-packed, and nested child offsets do not compose with a parent offset.
- **Limit: the width policy is not used inside the core packages.** The width-policy functions serve the Parquet writer's float-statistics, bit-packing and delta kernels. Code in the core packages sizes vectors with `simd_width_of`, the native width.
- **Limit: some docstrings disagree with the code.** `Column`'s names fields `_dict_indices` and `_dict_values` that do not exist, `as_primitive`'s says it always copies, and `decode_record_batch_zerocopy`'s says it refuses nullable columns. Trust the code.
- **Where `Schema` and `ArrowType` live.** The columnar layer is its own package, `komira_arrow` (over `komira_buffer`), separate from the plan IR (`komira_plan_expr`, `komira_plan_ir`) and scalar evaluation (`komira_column_kernels`), so a change to either no longer rebuilds the columnar library. `Schema` and `ArrowType` are in `komira_arrow`, and the plan packages import them from there.
