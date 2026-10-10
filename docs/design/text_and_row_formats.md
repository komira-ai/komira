# Text and row formats: CSV, Avro, ORC and XML

## What is it for, and what is out of scope?

Three libraries read and write the file formats other than Parquet. `komira_csv` parses and writes CSV. `komira_avro` reads and writes [Avro](https://avro.apache.org/docs/1.11.1/specification/) object container files (OCF). `komira_orc` reads and writes [ORC](https://orc.apache.org/specification/ORCv1/). A fourth library, `komira_xml`, is a general XML codec that this doc covers because it is the other small format codec in the tree. Each reader turns a whole file, held in memory, into one Arrow `RecordBatch`, and each writer turns a batch into a file.

One idea runs through the readers: **a text file has no footer, so its schema is either inferred from a bounded prefix or declared by the caller, and the file is then decoded at those types, in parallel when it is large.** Avro and ORC carry their schema in the file, so they read it from there.

Out of scope:

- JSON and JSON lines, which are not described here yet; see [held sections](#what-is-not-here-yet).
- How a query plan names a file and reaches these readers, and the engine's file-write sinks. They belong to the SDK and the execution engine, which are not in the tree yet.
- The compression libraries the codecs call (`komira_zlib`, `komira_lz4` and the system libraries for Snappy, Zstandard, bzip2 and xz), and Parquet.
- The per-format rules (null tokens, Avro type annotations, block checks, ORC skipping) are in the sub-doc [schemas, codecs and skipping](text_and_row_formats/schemas_codecs_and_skipping.md).

## How does it work?

```
CSV   bytes ─► (BOM strip) ─► scan to ScannedCells ─► column types ─► one builder per column ─► RecordBatch
        large body: quote-safe split ─► one worker per row range ─► concat in range order
Avro  bytes ─► OCF header ─► block scan ─► block ranges per worker ─► decompress + decode ─► RecordBatch
ORC   bytes ─► PostScript, footer, stripe footers ─► per stripe, per column streams ─► RecordBatch
write: RecordBatch ─► CsvSink | write_avro_file | write_orc_file
```

### How is a CSV file parsed?

`read_csv_bytes_to_batch[Q, SCANNER_VARIANT]` in `src/komira_csv/reader.mojo` is the serial reader. `Q` is the dialect, a `QuoteStyle` conformer: `Rfc4180`, `Excel` or `Posix` (defined in `src/komira_arrow/quote_styles.mojo`, re-exported from `src/komira_csv/quote_styles/`), which differ in compile-time constants such as `DOUBLE_QUOTE_ESCAPES` and `ESCAPE_BYTE`. `read_csv_bytes_to_batch_dynamic` picks `Q` from `CsvReadOptions.quote_style_tag` at run time (0 is `Rfc4180`, 1 `Excel`, 2 `Posix`). The reader:

1. Skips a UTF-8 byte-order mark when `strip_utf8_bom` is set, as it is by default.
2. Scans the bytes into a `ScannedCells` buffer: flat lists of cell starts, cell ends, cell flags and row starts (`scanned_cells.mojo`). `_dispatch_scan` (`reader.mojo`) selects one of three scanners, `scan_csv_phase1_into_cells`, `scan_csv_phase2_movemask_into_cells` and `scan_csv_phase3_pclmulqdq_into_cells`, all of which live in `csv_scanner_phase1.mojo` and are chosen by `SCANNER_VARIANT_PHASE_2` or `SCANNER_VARIANT_PHASE_3`; the default, `DEFAULT_SCANNER_VARIANT = 2`, is `scan_csv_phase2_movemask_into_cells`.
3. Takes column names from the header row, or names them `col_0`, `col_1` and so on when `has_header` is false.
4. Uses `declared_column_types` when set, after `check_declared_column_types` has confirmed there is one entry per column. Otherwise it infers with `infer_column_types`, whose lattice is Int64, Float64, Date32, Bool, then String (`type_inference.mojo`), or with `infer_column_types_wide` when `infer_temporal_types` is set, which adds the temporal types.
5. Builds each column with `_build_column`: Int64, Float64, Date32, Bool and String have builders in `reader.mojo`, and every other type goes to `dispatch_typed_builder` (`typed_column_builders.mojo`). A short row gives a null, and so does a cell that does not parse as the column's type.

### When is a CSV schema inferred?

`read_csv_bytes_to_schema_dynamic` (`reader.mojo`) infers a schema without building columns. It scans at most a 256 KiB prefix (`_SCHEMA_SAMPLE_PREFIX_BYTES`) and applies the same inference rules to the first `infer_rows` data rows (`CsvReadOptions.infer_rows`). A caller that binds a query before running it can take the schema from here and pass it back as `declared_column_types`, so the decode parses at the types the query was bound against instead of inferring a second time.

### How is a CSV file split for parallel decode?

`read_csv_bytes_to_batch_parallel_impl` (`parallel_reader.mojo`) falls back to the serial reader with the phase-3 scanner when the body is below `_MIN_PARALLEL_BYTES` (1 MiB), when only one worker is available, or when the split yields a single range. It uses at most `_MAX_WORKERS` (32), and defaults to the number of physical cores. Otherwise `compute_csv_quote_safe_row_ranges` (`csv_chunk_split.mojo`) cuts the body into row ranges.

For the RFC 4180 family a byte is inside a quoted field exactly when the number of quote bytes before it is odd, because a doubled-quote escape contributes two. One pass with a carry-less multiply (`quote_region_mask_u64`) therefore classifies every candidate newline. In the same pass, each quote that parity calls an opener must follow a delimiter, CR, LF or the start of the body, which is the rule the scanner's state machine applies. At the first quote that fails this check the split stops and the rest of the body becomes one range, so a stray quote costs parallelism and never produces wrong rows. For the `Posix` dialect, whose `\"` escape is one quote byte and flips parity, `csv_split_is_quote_parity_safe` is false and the split emits one range.

Worker 0 infers the shared schema from a 256 KiB prefix (`_INFER_PREFIX_BYTES`), unless the options declare types. Each worker then scans its range with `scan_csv_phase3_pclmulqdq_into_cells` and builds a batch. The workers run through `LocalDispatcher.run_with_state`. `_concat_csv_batches_column_parallel` joins the batches in range order, one task per column.

### How is an Avro file decoded?

`read_avro_bytes_parallel_with_dispatcher` (`src/komira_avro/parallel_driver.mojo`) decodes the header (`decode_ocf_header` in `ocf_header.mojo`), finds the blocks by walking their sync markers (`scan_ocf_blocks_after_header`), and splits the blocks into contiguous ranges (`_partition_blocks`). A file with fewer than `_MIN_PARALLEL_BLOCKS` (2) blocks, or a run with one worker, decodes serially through `decode_avro_bytes_comptime`. Each worker decompresses its blocks with `decompress_block` (`avro_codec.mojo`: null, deflate, snappy, zstandard, bzip2 and xz) and decodes them. `_reassemble_in_order` concatenates the worker batches in block order.

Decoding takes one of two paths, chosen by `classify_avro_shape` in `comptime_decoder.mojo`. A record whose fields are all non-null, or all nullable (`union[null, T]`), boolean, int, long, float, double, string or bytes, and none of which carries a logical type, is a "hot" shape (`is_hot_shape`) and runs `decode_block_comptime[SHAPE_KIND]`, a loop specialised at compile time. Every other schema runs `ActionTableInterpreter` (`action_table.mojo`), which walks a per-field action list. Both paths fill the same `ColumnAccVariant` accumulators. A union other than null plus one type raises `AvroDecodeError.UNSUPPORTED_UNION`; an Arrow type with no accumulator raises `UNSUPPORTED_COLUMN_TYPE`; and a record, enum, array or map field raises `UNSUPPORTED_FIELD_KIND` when a block decodes. `avro_schema.mojo` parses the schema JSON, maps Avro types to Arrow, and rejects recursive schemas.

### How is an ORC file read?

`read_orc_file` (`src/komira_orc/orc_reader.mojo`) maps the whole file (`komira_arrow_ipc.chunked_read.read_chunked`, mmap-backed) and hands the bytes to `read_orc_bytes` (`read_orc_file_opts` goes through `read_orc_bytes_opts`), which parses the tail: the PostScript, footer and stripe footers, which are Protocol Buffers messages decoded by `footer.mojo`. For each stripe it locates the streams of each column (`_locate_streams`) and decodes column by column through `decode_stripe_column` (`column_decoder.mojo`), the RLE decoders in `rle_decode.mojo` and `decompress_stream` (`orc_codec.mojo`: none, zlib, snappy, LZO, LZ4 and zstd). `read_orc_file_with_dispatcher` decodes the columns in parallel (`_decode_orc_columns_parallel_with_dispatcher`). A schema with nested types, or with Hive ACID columns, goes to the recursive decoder in `nested_decoder.mojo` (`_read_orc_nested`).

### How is an ORC file written?

`write_orc_file` (`orc_writer.mojo`) maps each Arrow column to an ORC kind (`_arrow_to_orc_kind`), cuts rows into stripes, emits each stripe's PRESENT, DATA and LENGTH streams (`stripe_emit.mojo`) with direct encodings only, and writes the metadata, footer and PostScript with `protobuf_writer.mojo`. `write_orc_file_with_dispatcher` compresses streams in parallel (`stream_compress_parallel.mojo`).

### How is a CSV file written?

`CsvSink` (`src/komira_csv/csv_sink.mojo`) writes a header row on `init_sink` unless `header=False`, then one line per row for each batch it accepts. It formats cells column by column (`_format_column_cells`), and in parallel above `_CSV_WRITE_MIN_PARALLEL_ROWS` (16 Ki rows) with at most `_CSV_WRITE_MAX_WORKERS` (32) workers. If the writer is destroyed before `finish()` and it created the file, it unlinks the partial file.

### How is an Avro file written?

`write_avro_file` (`avro_ocf_writer.mojo`) derives the Avro schema from the Arrow schema (`from_arrow_schema_json`), writes a header with a random 16-byte sync marker, encodes rows into blocks, and flushes a block when it reaches `block_size_bytes` or `block_size_rows`, whichever comes first (`AvroWriterOptions`). A nullable column is a union whose branch 0 is null. Each block is compressed with the chosen codec and framed with its object count, byte count and the sync marker.

### What does the XML codec accept?

Well-formed XML, leniently. `XmlReader` (`src/komira_xml/xml_reader.mojo`) is a forward-only pull parser. It owns the input, yields `XmlEvent` values holding byte ranges, and copies only when a caller asks for text, a name or an attribute value. It accepts elements, attributes, self-closing tags, text, CDATA sections, comments and the XML declaration, and skips a DOCTYPE. `parse_xml` (`xml_tree.mojo`) builds an owned `XmlNode` tree, resolves namespace prefixes to URIs, and refuses a second root. `canonical_xml` writes a namespace-resolved canonical form for comparing documents and refuses nesting deeper than 512. `append_unescaped` (`xml_escape.mojo`) decodes the five predefined entities and numeric character references. `XmlWriter` (`xml_writer.mojo`) writes into one buffer, escaping text and attributes.

## Why is it built this way?

### Why split a CSV body only where quote parity is proven?

**Decision.** The parallel reader splits where `compute_csv_quote_safe_row_ranges` proves a row boundary, stops splitting at the first quote the scanner would not treat as an opener, and never splits a `Posix` body.

**Because.** A raw newline is a row end only outside quotes, so a newline split can start a worker in the middle of a quoted field. For RFC 4180 dialects a doubled-quote escape keeps parity, so parity classifies every split point in one pass. A quote in the middle of an unquoted field flips parity where the scanner does not, so the opener check stops the split there: the split never starts a range inside a quoted field, and a stray quote only stops further splitting. The header of `csv_chunk_split.mojo` records these points.

**Alternatives weighed.**

- Split at raw newlines: a split inside a quoted field need not raise, so rows can be silently wrong.
- Use one worker whenever a projected column is variable-width: with every column read as a string, a large file then decodes on one core.
- Parity alone: after a stray quote it inverts every later classification.

**Revisit if** large files in a dialect whose escape flips parity, as `Posix`'s does, must decode in parallel.

### Why does the CSV reader take declared column types?

**Decision.** `CsvReadOptions.declared_column_types` makes the decode parse at types the caller has already bound, and a length that disagrees with the header raises.

**Because.** A reader that always re-infers can return other types than the ones a query was bound against. Casting afterwards cannot repair it: a column bound as strings that holds `0001` and is re-inferred as integers parses to `1`, the right type with the wrong value. The bytes have to survive, so the parse has to happen at the declared type. The field's docstring in `csv_options.mojo` records this.

**Alternatives weighed.** Guess which columns line up when the lengths differ: that is how the silent wrong answer arose.

**Revisit if** a caller needs to declare only some columns.

### Why do the CSV readers check input sizes with explicit raises?

**Decision.** `input_limits.mojo` checks, once per file and before any allocation, the column count (at most `MAX_CSV_COLUMNS`, 4,096), the cells per input byte (at most `MAX_CSV_CELLS_PER_INPUT_BYTE`, 256) and each string column's total bytes (at most `MAX_ARROW_STRING_BYTES`, 2^31 - 1).

**Because.** The builders allocate rows times columns: every record must have the header's field count (a short record is refused, not padded; see the record-shape invariant below), so a small file with a very wide header would demand billions of cells. Checks inside the per-cell loops would add work to every cell, and asserts vanish in builds that compile them out. The header of `input_limits.mojo` records the reasoning.

**Revisit if** a legitimate input exceeds a ceiling; each ceiling is one constant.

### Why does the Avro decoder specialise record shapes at compile time?

**Decision.** Hot-shape records decode in loops specialised by `SHAPE_KIND`; other schemas go through the runtime action interpreter.

**Because.** The interpreter pays, per field and per row, several branch cascades and copies to pick the read and the accumulator. Resolving the binding of each output column once, at the start of the decode, removes that dispatch, and both paths fill the same accumulators, so the output is the same.

**Alternatives weighed.** A SIMD varint decoder: the header of `src/komira_avro/__init__.mojo` records it as a negative result, about 0.39 times the scalar decoder.

**Revisit if** a common schema shape falls outside the specialised set.

### Why is LZO read but never written?

**Decision.** `komira_orc` decodes LZO with its own `lzo1x_decompress.mojo`, and `compress_stream` refuses to write it.

**Because.** The only available LZO1X encoder is GPL-licensed and the ORC specification deprecates the codec; the refusal message `OrcCodecError.LZO_WRITE_UNSUPPORTED` in `orc_codec.mojo` says so.

**Alternatives weighed.** Link an LZO library: its licence rules it out.

**Revisit if** a compatible LZO1X encoder exists.

### Why is XML a lenient pull parser over byte ranges?

**Decision.** `XmlReader` yields byte ranges into one owned buffer and `append_unescaped` passes an unknown `&` through.

**Because.** Byte-range events make one forward pass with no allocation per event. A decoder that raises on real-world service payloads is worse than one that is lenient on input and strict on output. The headers of `xml_reader.mojo` and `__init__.mojo` record these reasons.

**Revisit if** a caller needs validation, for example end-tag name matching.

## What must always hold?

- **A declared CSV schema is positional.** Column `i` of the file parses at declared type `i`, and a width mismatch raises rather than truncating, padding or re-inferring. Enforced by `check_declared_column_types` (`csv_options.mojo`), which the readers call; no `komira_csv` test imports it or is named for a mismatched width.
- **A CSV record has exactly the header's field count, and nothing follows a closing quote but the delimiter, a line end or the end of input.** Under every dialect (Rfc4180, Excel, Posix) the readers refuse a record with more fields than the header, one with fewer, and a byte after a closing quote; the error names the record number (the header is record 1), its physical line, its byte offset, the field and the problem. No dialect or option tolerates these: before the check the extra cells were dropped, short records were padded with nulls and a stray byte split the field, all in silence. Enforced by `check_csv_record_shape` (`record_shape.mojo`), called by `read_csv_bytes_to_batch`, `read_csv_bytes_to_schema` and every worker of the parallel reader; pinned by `test_csv_record_shape` and `test_csv_record_shape_parallel`.
- **Blank lines (policy).** A fully blank line (zero bytes between two line terminators; `""` is not blank) in a file with two or more columns is skipped, anywhere in the file, as pandas does by default: it holds no data. It is not counted as a record but is counted as a line in error messages. In a one-column file a blank line is a record with one empty field, read as NULL, except before the header or the first record: blank lines there are skipped whatever the column count (a header cannot be blank, and the field count is not known yet). Same paths as above; pinned by `test_csv_blank_lines`, `test_csv_record_shape_edges` and `test_csv_record_shape_parallel`.
- **A CSV split starts every range at a row start.** Pinned by `test_csv_quote_safe_chunk_split`, including a stray-quote fixture.
- **Parallel decode keeps file order.** CSV concatenates in range order and Avro reassembles in block order. Pinned by the `test_csv_parallel_reader_*` tests (parallel against serial values) and `test_avro_block_parallel_decode`.
- **A writer refuses a type it cannot encode, by name.** Avro raises `AvroWriteError.UNSUPPORTED_TYPE`, pinned by `test_avro_write_roundtrip`; ORC raises `OrcWriteError.UNSUPPORTED_TYPE`, which no test checks.
- **A `CsvSink` that never finishes removes its partial file.** Its destructor unlinks a file it created; no test is named for it.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_csv/reader.mojo` | serial CSV reader, schema-only inference | `read_csv_bytes_to_batch`, `read_csv_bytes_to_batch_dynamic`, `read_csv_bytes_to_schema_dynamic` |
| `src/komira_csv/parallel_reader.mojo` | parallel CSV reader | `read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher`, `_concat_csv_batches_column_parallel` |
| `src/komira_csv/csv_chunk_split.mojo` | quote-safe split | `compute_csv_quote_safe_row_ranges` |
| `src/komira_csv/csv_scanner_phase1.mojo`, `csv_state_machine.mojo`, `scanned_cells.mojo` | scanners | `scan_csv_phase2_movemask_into_cells`, `scan_csv_phase3_pclmulqdq_into_cells`, `ScannedCells` |
| `src/komira_csv/type_inference.mojo`, `cell_parsers*.mojo`, `temporal_parsers.mojo`, `temporal_range.mojo`, `typed_column_builders.mojo` | types and cells | `infer_column_types`, `dispatch_typed_builder` |
| `src/komira_csv/csv_options.mojo`, `null_detection.mojo`, `input_limits.mojo` | options, tokens, ceilings | `CsvReadOptions`, `check_declared_column_types` |
| `src/komira_csv/csv_sink.mojo` | CSV writer | `CsvSink`, `_format_column_cells` |
| `src/komira_avro/parallel_driver.mojo`, `comptime_decoder.mojo`, `action_table.mojo` | Avro decode | `read_avro_bytes_parallel_with_dispatcher`, `decode_block_comptime`, `ActionTableInterpreter`, `ResolutionTable` |
| `src/komira_avro/avro_schema.mojo`, `ocf_header.mojo`, `ocf_block_scan.mojo`, `avro_codec.mojo` | schema, container, codecs | `AvroSchema`, `decode_ocf_header`, `scan_ocf_blocks`, `decompress_block` |
| `src/komira_avro/avro_ocf_writer.mojo`, `ocf_block_emit.mojo`, `varint_encode.mojo` | Avro writer | `write_avro_file`, `AvroWriterOptions` |
| `src/komira_orc/orc_reader.mojo`, `footer.mojo`, `column_decoder.mojo`, `rle_decode.mojo`, `orc_codec.mojo` | ORC reader | `read_orc_file`, `OrcFileTail`, `decode_stripe_column`, `decompress_stream` |
| `src/komira_orc/orc_writer.mojo`, `stripe_emit.mojo`, `protobuf_writer.mojo` | ORC writer | `write_orc_file`, `OrcWriterOptions` |
| `src/komira_xml/xml_reader.mojo`, `xml_tree.mojo`, `xml_escape.mojo`, `xml_writer.mojo` | XML codec | `XmlReader`, `parse_xml`, `XmlNode`, `XmlWriter` |

Entry points are the functions and types in the last column.

### I want to change X: which file?

| Change | Start at |
|---|---|
| Add a CSV option | `CsvReadOptions` in `csv_options.mojo`, then the reader that honours it |
| Change CSV type inference | `infer_column_types` in `type_inference.mojo` |
| Parse a new type from CSV | `dispatch_typed_builder` in `typed_column_builders.mojo`, plus a parser in `cell_parsers.mojo` (date, time, timestamp and duration parsers: `temporal_parsers.mojo`) |
| Change how a CSV body is split | `compute_csv_quote_safe_row_ranges` in `csv_chunk_split.mojo` |
| Decode a new Avro shape fast | `classify_avro_shape`, `is_hot_shape` and `decode_block_comptime` in `comptime_decoder.mojo` |
| Write a new type to Avro or ORC | `_resolve_write_tag` in `avro_ocf_writer.mojo`; `_arrow_to_orc_kind` in `orc_writer.mojo` |
| Change the XML parser | `XmlReader.next_event` in `xml_reader.mojo`; tree and namespaces in `xml_tree.mojo` |

## How is it tested?

Each library lists its tests in `test_srcs` in its `BUCK` file: 41 for `komira_csv`, 32 for `komira_avro`, 37 for `komira_orc` and four for `komira_xml`. Each test is built against the library and run, and the package is published only if every one passes, unless the BUCK file holds a test in its known-failing ledger (see [the Mojo rules](../../tools/build/mojo/README.md), "The gate"). Run: `./buck2 build //src/komira_csv:komira_csv` (likewise for the other three).

| Test | Covers |
|---|---|
| `test_csv_scanner_phase1`, `test_csv_scanner_phase2_movemask`, `test_csv_scanner_phase3_pclmulqdq`, `test_csv_scanner_flat_cells` | the three scanners |
| `test_csv_quote_safe_chunk_split`, `test_csv_parallel_reader_*`, `test_csv_phase_4_column_parallel_concat_*` | split, parallel decode, concat |
| `test_csv_phase_b`, `test_csv_dtype_completion`, `test_csv_schema_sample_inference` | options, types, prefix inference |
| `test_avro_codec_matrix`, `test_avro_block_parallel_decode`, `test_avro_comptime_shape_kind_decode` | codecs, block parallelism, specialised shapes |
| `test_avro_resolve_*` (five files: aliases and defaults, errors, field skip, promotions, union and enum), `test_avro_recursive_reject` | schema resolution, recursive schemas |
| `test_avro_write_roundtrip`, `test_avro_write_parallel_block_compress` | writer |
| `test_orc_footer_decode`, `test_orc_rle_families`, `test_orc_codec_matrix`, `test_orc_lzo1x_decompress` | tail, RLE, codecs |
| `test_orc_struct_decode`, `test_orc_list_decode`, `test_orc_map_decode`, `test_orc_union_decode` | nested reads |
| `test_orc_write_*` (six files: multistripe, nullable roundtrip, parallel stream compress, primitives roundtrip, roundtrip, statistics), `test_orc_pyarrow_orc_cross_impl_read` | writer, a file from another writer |
| `test_xml_codec` | escaping, events, writer, namespaces, malformed input, round trip |

**Not tested.** the decode of a CSV file with a quote inside an unquoted field on the parallel path, and the ORC writer's type refusal.

## What are its limits and open questions?

- **Limit: the parallel CSV reader ignores three options when it splits.** `parallel_reader.mojo` never reads `strip_utf8_bom` or `infer_temporal_types`; only its serial fallbacks honour them. (`projection_columns` is honoured by the serial reader through `CsvReadOptions.is_projected`, and the parallel reader does not read it either.) So with the RFC 4180 dialect, a file of 1 MiB or more that starts with a byte-order mark can get a different first column name. `Posix` never splits, and the `Excel` scanners skip the mark themselves (`ACCEPTS_BOM`, tested in `scan_csv_phase3_pclmulqdq_into_cells`, the scanner the parallel workers run).
- **Limit: the parallel CSV scanner mis-tokenizes a stray quote.** The header of `csv_chunk_split.mojo` records that `scan_csv_phase3_pclmulqdq`, which the parallel reader and its serial fallback use, mis-tokenizes a file with a quote inside an unquoted field. The serial default is the phase-2 scanner.
- **Limit: inference sees a prefix only.** A CSV schema comes from the first `infer_rows` data rows (100 by default); in the serial builders a later cell that does not parse becomes null.
- **Limit: Avro schema resolution is not used by the readers here.** The parallel driver decodes with `ResolutionTable.identity`. `ResolutionTable.resolve` and `read_avro_bytes_resolved`, which apply a reader schema with aliases, defaults and promotions, are called only by tests inside `komira_avro`.
- **Limit: the Avro decoder cannot read nested fields.** Records, arrays, maps and enums raise (see above); only flat records of scalars, with the logical types the accumulators cover, decode.
- **Limit: writer coverage.** The Avro writer takes a flat record of Bool, Int8 to Int64, UInt8 to UInt32, Float32, Float64, strings, binary, Date64, second and nanosecond timestamps, and the time and duration types listed in `_resolve_write_tag`; UInt64, Float16, decimals and nested types raise. The ORC writer takes Bool, Int8 to Int64, Float32, Float64, strings and Date32, with direct encodings and no dictionary.
- **Limit: ORC skipping is a library API only.** The projection, stripe and stride skip cascade is described in the [sub-doc](text_and_row_formats/schemas_codecs_and_skipping.md#how-does-the-orc-reader-skip-data); nothing in this tree calls it outside tests.
- **Limit: XML end tags are not matched by name.** An end tag closes the innermost open element whatever its name, so `<a></b>` parses as an element `a`. A DOCTYPE is skipped, not interpreted.
- **Open question: stale comments.** The header of `parallel_reader.mojo` describes a newline split and a serial concat; the code splits at quote-safe row boundaries and concatenates by column.

## What is not here yet?

These parts of the subject wait for code that is not in the tree, and are not described until it lands:

- JSON and JSON lines: schema inference, the structural index, the parallel decoder and the JSONL writer, and the general JSON helpers.
- How a plan names a CSV, JSON, Avro or ORC file, infers a schema when the plan is built, and reaches these readers; and the engine's file-write sinks.
- The users of the XML codec in the cloud clients.
