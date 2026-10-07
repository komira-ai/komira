# Text and row formats: schemas, codecs and skipping

## What is it for, and what is out of scope?

This sub-doc of [text and row formats](../text_and_row_formats.md) holds the per-format rules that the family doc's decode sections do not: the CSV token and dialect options, how Avro carries Arrow types it lacks and checks its blocks, and how ORC skips data. How the readers run is in the family doc.

Out of scope: the compression libraries the codecs call, and JSON, which is not in the tree yet.

## How does it work?

### Which strings does the CSV reader treat as null, true or false?

`CsvReadOptions` (`src/komira_csv/csv_options.mojo`) holds three token lists, with pandas-style defaults:

| List | Default tokens |
|---|---|
| `null_strings` | `""`, `NULL`, `NA`, `NaN`, `null` |
| `true_strings` | `true`, `TRUE`, `T`, `1`, `yes`, `Y` |
| `false_strings` | `false`, `FALSE`, `F`, `0`, `no`, `N` |

`is_null_cell` (`null_detection.mojo`) matches a cell's bytes exactly against the null list. An empty null list is strict mode: no cell is null. The lists are bounded arrays, so a list holds at most `MAX_NULL_STRINGS` (8) tokens.

### How do Arrow types without an Avro counterpart survive a round trip?

Through `arrow.<name>` logical-type annotations (`src/komira_avro/avro_logical_arrow.mojo`). The writer's schema builder `from_arrow_schema_json` stamps them when `emit_arrow_logicals` is true, the default in `AvroWriterOptions`. Each annotation has one required Avro backing type (`int`, `long`, a `fixed` of set size, or a union); `arrow.uint64` is backed by `fixed(8)` and `arrow.float16` by `fixed(2)`. On read, `avro_node_to_arrow_with_override` honours an annotation only when the node's physical type matches the table entry (`_physical_matches`); on a mismatch, or an `arrow.*` name it does not know, it falls back silently to the standard Avro mapping.

### How are Avro compressed blocks checked?

A snappy block is the raw snappy bytes followed by a big-endian CRC32 of the uncompressed bytes. The reader strips the trailer, decompresses and compares the CRC (`avro_codec.mojo`), raising `AvroCodecError.SNAPPY_CRC32_MISMATCH` on a difference. The header's codec name for zstd is exactly `"zstandard"` (`ocf_header.mojo`). ORC's Snappy has no such trailer: the stream is the raw block inside ORC's own chunk framing (`orc_codec.mojo`).

### How does the ORC reader skip data?

`src/komira_orc/orc_stride_skip.mojo` has a four-level cascade, with predicates expressed as `komira_plan_expr` `Expr` values, reached through two entry points:

1. Column projection: `read_orc_bytes_pruned` takes a list of output-column indices and decodes only those columns.
2. Stripe statistics: also `read_orc_bytes_pruned`. A stripe whose min and max are disjoint from the predicate is never decoded.
3. Stride statistics: `read_orc_bytes_filtered` applies the per-stride row-index statistics. It decodes the whole stripe and drops the rows of skipped strides after decode.
4. Stride bloom filters: also `read_orc_bytes_filtered`; the filters (`bloom_filter.mojo`) are consulted in the same per-stride loop as level 3.

Only a range-predicate subset is understood (a column against an integer literal, with AND and OR); any other predicate shape keeps every stride, so a stride is never skipped wrongly. Separately, `read_orc_file` unwraps a Hive ACID file: `is_acid_schema` (`orc_logical_arrow.mojo`) detects the six-column wrapper, and `acid_output_columns` lifts the `row` struct's children and hides the five metadata columns by default; `read_orc_file_opts` (and `read_orc_bytes_opts`) takes `with_acid_columns` to expose them.

## Why is it built this way?

### Why does the reader honour an Avro annotation only on a physical match?

**Decision.** An `arrow.*` annotation changes the Arrow type only when the Avro physical type is the one the table requires.

**Because.** The header of `avro_logical_arrow.mojo` names it the codec-compatibility guard and matches it to arrow-rs's guarded match arms: the annotation is only a hint about a physical value, and an annotation the reader does not know falls back the same way, for forward compatibility.

**Alternatives weighed.** Raising on a mismatch: files from other writers would stop reading.

**Revisit if.** A mismatch should be an error, not a silent fallback.

### Why does the ORC stride skip decode the whole stripe?

**Decision.** Skipped strides are dropped after decode.

**Because.** The header of `orc_stride_skip.mojo` records that the column decoder is not resumable, so seeking to a stride would need the row index's position table first.

**Alternatives weighed.** Seeking with the row index positions: not built.

**Revisit if.** The column decoders can start at a stride.

## What must always hold?

- **An Avro snappy block with a wrong CRC raises.** Enforced by the check in `avro_codec.mojo` and pinned by `test_snappy_bad_crc_raises` in `test_avro_snappy_codec_decode.mojo`.
- **An unsupported ORC predicate keeps the stride.** Stated in the header of `orc_stride_skip.mojo`; `test_orc_stride_skip.mojo` has three tests, none of which passes an unsupported predicate shape.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_csv/csv_options.mojo` | CSV options and token lists | `CsvReadOptions` |
| `src/komira_csv/null_detection.mojo` | token matching | `is_null_cell`, `is_true_cell`, `is_false_cell` |
| `src/komira_avro/avro_logical_arrow.mojo` | `arrow.*` annotations | `from_arrow_schema_json`, `avro_node_to_arrow_with_override` |
| `src/komira_avro/avro_codec.mojo` | block codecs | `crc32_ieee`, `decompress_block` |
| `src/komira_orc/orc_stride_skip.mojo`, `bloom_filter.mojo` | the skip cascade | `read_orc_bytes_pruned`, `read_orc_bytes_filtered` |
| `src/komira_orc/orc_logical_arrow.mojo` | ACID unwrapping | `is_acid_schema`, `acid_output_columns` |

## How is it tested?

These tests are in the `test_srcs` of their libraries; run `./buck2 build //src/komira_avro:komira_avro` or `//src/komira_orc:komira_orc`.

| Test | Covers |
|---|---|
| `komira_avro/tests/test_avro_arrow_logical_round_trip.mojo` | `arrow.*` write and read |
| `komira_avro/tests/test_avro_snappy_codec_decode.mojo` | snappy blocks and their CRC |
| `komira_orc/tests/test_orc_projection_stripe_prune.mojo` | projection and stripe pruning |
| `komira_orc/tests/test_orc_stride_skip.mojo` | stride statistics skipping |
| `komira_orc/tests/test_orc_bloom_filter.mojo` | stride bloom filters |
| `komira_orc/tests/test_orc_acid_default_suppress.mojo` | ACID metadata columns hidden by default |

`test_csv_simd_int_column.mojo` in `komira_csv/tests/` reads an empty cell as null through the default list.

## What are its limits and open questions?

- **Limit: the ORC skip cascade has no caller outside tests.** Nothing in this tree outside tests calls `read_orc_bytes_pruned` or `read_orc_bytes_filtered`.
