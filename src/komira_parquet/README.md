# komira_parquet

The Parquet reader core. These parts of the package hold the value decoders of
the Parquet encodings, each a function of encoded bytes to values with no file,
page header or engine around it:

- `plain`: PLAIN. `decode_plain_int32` / `_int64` / `_float32` / `_float64`
  (a copy into a new array) and their `_zero_copy` twins (the page buffer
  becomes the array), `decode_plain_boolean`, `decode_plain_byte_array` (two
  walks with the same output, chosen by `set_plain_ba_fused_enabled`) and
  `decode_plain_int96_to_int64` (INT96 timestamps to Unix nanoseconds). Each
  refuses a page that cannot hold the count it is asked for, including a
  count whose byte size wraps.
- `plain_flba`: PLAIN FIXED_LEN_BYTE_ARRAY, to a `BinaryArray`
  (`decode_plain_fixed_len_byte_array`) or, for a DECIMAL column, to Float64
  (`decode_plain_flba_decimal_to_float64`).
- `decimal_decode`: DECIMAL to Arrow `Decimal128Array`, from FLBA
  (`decode_plain_flba_decimal_to_i128`), INT32 or INT64
  (`decode_int32_buf_to_decimal128`, `decode_int64_buf_to_decimal128`).
- `rle`: the RLE / Bit-Packing Hybrid (definition and repetition levels,
  dictionary codes, booleans). `RleDecoder(data, bit_width)` with
  `decode_int32` (as many values as asked for, skipping the rest of a run cut
  short) and `decode_run_int32` (run-aligned and resumable: a long RLE run comes
  back as a value and a count left over, a bit-packed run group by group);
  `decode_levels` / `decode_def_levels` for a V1 level section
  (`[i32 LE length][hybrid bytes]`), which refuse a length prefix the section
  cannot hold; `decode_def_levels_u8`, `bit_width_for_max_level`,
  `read_uleb128`. The bit-unpack kernels behind it are in `rle_bitunpack`.
- `delta`: DELTA_BINARY_PACKED. `DeltaDecoder(data)` with `decode_int64` /
  `decode_int32` (one shot), and `begin_resumable` + `resume_fill_int64` /
  `resume_fill_int32` (a page in chunks of any size, equal to the one-shot
  result); `delta_binary_packed_byte_count` for where an embedded stream ends.
- `delta_byte_array`: DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY, decoded to
  a `StringArray`.
- `byte_stream_split`: BYTE_STREAM_SPLIT for FLOAT and DOUBLE, into a new
  `PrimitiveArray` or straight into a caller's `ByteView` window (`_into`).
- `decode_arm_trace`: four decode sites have two arms each (a bulk copy or a
  byte loop for a DELTA page, and three dictionary-path choices the dictionary
  decoder reads). All default on; `set_*_enabled(False)` turns one off for the
  process, and fire counters count each arm. Nothing is read from the
  environment: a program that wants a switch maps its own flag to the setter.
- `scan_copy_trace`: the same for six scan sites where a whole buffer is
  either copied or handed over (gates set with `set_*_enabled`, the readahead
  hint with `set_prefetch_mode`), with paired counters and
  `scan_copy_trace_dump`, which prints every counter of the decode and scan
  paths when `set_scan_copy_trace_enabled(True)`. `payload_sel_trace` and
  `staged_filter_trace` hold the gates and counters of two scan stages.
- `dictionary`: RLE_DICTIONARY. `DictionaryDecoder` loads a PLAIN dictionary
  page (`init_dict_int32` / `_int64` / `_float32` / `_float64` /
  `_byte_array` / `_fixed_len_byte_array`), decodes a data page's codes
  (`decode_indices`, or `decode_indices_into` a caller's `Span`) and resolves
  them to values (`resolve_int32` and siblings, `resolve_flba_as_binary`,
  `resolve_flba_decimal_to_float64`), to a `StringDictionaryArray`
  (`resolve_as_string_dict`) or to a DICTIONARY `Column` that takes the codes
  over (`string_dict_column`). A code outside the loaded dictionary is
  refused before anything is read with it. The numeric resolves have two
  arms (`set_dict_resolve_fused_enabled`): the blocked, bounds-fused gather of
  `dict_gather_fused` (default) and the gathers of `dictionary_resolve`.
  `dict_gather_fused` also holds `gather_flat_clamped`, the clamping gather of
  the sub-row-group route.
- `def_level_bitmap`: a flat column's V1 definition-level section to an Arrow
  validity bitmap (`decode_def_levels_to_bitmap`), with an all-valid fast path.
- `nested`: the Dremel level helpers. `compute_leaf_levels` walks a schema to
  each leaf's maximum definition and repetition levels; `reconstruct_struct_column`,
  `reconstruct_list_column` and `reconstruct_map_column` build a nested
  column's validity and offsets from its levels.
- `decode_helpers` and `null_expand`: the column decoder's helpers. The
  Parquet-to-Arrow type map of a schema element (`schema_element_arrow_type`,
  `field_from_schema_element`, annotation-aware: DECIMAL, unsigned, narrow and
  date integers, timestamps, text or binary BYTE_ARRAY), the post-decode
  re-labels, and the scatter of dense values into a nullable array by their
  definition-level bits.
- `selection_vector`, `gather_common`, `gather_byte_array` and `gather_dict`:
  reading only the selected rows of a column chunk. `SelectionInterval` is a
  (skip, select) run of a row filter; `SelectionInterval.from_bool_mask` (or
  `boolean_to_intervals`) turns a `BooleanArray` mask into the runs, a 64-bit
  word at a time. The package-private gathers copy the selected rows out of
  decompressed pages, non-null or nullable: PLAIN BYTE_ARRAY pages by walking
  the length prefixes and copying only the selected bodies, dictionary-encoded
  pages by decoding the codes and looking up only the selected ones (a code
  outside the dictionary gathers 0, or an empty string). Each refuses a
  `num_selected` that is not the intervals' total, intervals past the last
  page, and output past the Int32 string offsets; the BYTE_ARRAY walk refuses
  a malformed length prefix with the PLAIN decode's message.

Every public decoder takes the encoded bytes as a `Span[UInt8]` and writes into
a `Span` (or a buffer) whose length it respects: a request larger than the
output is cut to it or refused, never written past it. Corrupt input (a
negative length, a value count the page cannot hold, a run or block header
that decodes to a negative or overflowing size) raises or stops the decode; it
never reads or writes outside the input and output.

The package also reads a Parquet file's footer and the metadata around its
pages:

- `file_reader`: `ParquetFileReader[FS]`, a reader over any `FileSystem`.
  `read_parquet_preamble` fetches the trailer and the Thrift footer in one
  tail read (or two, when the footer is larger than the read); the reader
  keeps the footer bytes and reads data ranges, from a mapping of the file on
  an mmap-backed file system (`LocalFs`) and through `fs.read_at` on any
  other. `open_metadata_only` (no mapping) and `open_footer_only` (no I/O)
  serve callers that never read data; `clone_sharing_mmap` gives a second
  reader over the same mapping. Every range is checked against the file.
- `thrift_compact`: `ThriftCompactReader`, the Thrift Compact Protocol reader
  every parser here shares. It never reads outside its view, refuses a
  varint past 64 bits, a length or element count the bytes cannot hold, and
  nesting past 64 levels; `parse_metadata_summary` reads the footer's
  top-level fields.
- `metadata_parser`: `parse_full_metadata`, the whole `FileMetaData` (schema,
  row groups, column chunks, statistics, key-value metadata). Statistics
  field 9 is the spec's `nan_count`; a chunk's HyperLogLog registers come
  from its own key-value metadata (`komira_parquet_api.hll_footer`).
- `footer_header`: the light parses. `parse_metadata_header_and_schema`
  stops once `num_rows` and the schema are read and finds `ARROW:schema` by
  a backward byte search instead of walking the row groups;
  `parse_metadata_num_rows_only` reads `num_rows` alone. Both report the
  bytes they examined.
- `page_header_parser`: the PageHeader of a data page (V1 and V2) or a
  dictionary page, from a `Span`, with every size and count checked before a
  decoder can use it.
- `gather`: `decode_column_with_selection`, the selected rows of a column
  chunk. It walks the chunk's pages, decompresses only the data pages a page
  mask selects (a V2 page whose header says its values are not compressed is
  copied), loads a dictionary page, and hands the selected pages to the gather
  for their shape: PLAIN fixed-width (INT32, INT64, FLOAT, DOUBLE; these
  gathers are in `gather` too), PLAIN BYTE_ARRAY or dictionary-encoded,
  non-null or flat nullable (V1 definition levels). Every gathered column gets
  the Arrow type of its annotations (unsigned, narrow and date integers,
  timestamps, binary BYTE_ARRAY). A shape it does not gather (nested,
  FIXED_LEN_BYTE_ARRAY, DECIMAL, other encodings, mixed encodings, V2 pages
  with levels, dictionary-encoded pages with `preserve_dict`) and some
  malformed chunks (a page that runs past the chunk, a fixed-width dictionary
  page shorter than its value count) return `None`, and the caller must decode
  that chunk some other way. Errors from the page header parser, the codec
  and the dictionary decoder, and the gathers' refusals, are raised.
- `bloom_reader`, `bloom_pruner`: a column chunk's split-block bloom filter
  (xxHash64, as parquet-format's BloomFilter.md defines it), and the
  row-group pruner that probes it for `col == literal` leaves under AND and
  OR. It prunes only when a filter proves a value absent.
- `num_rows_cache`: `ParquetNumRowsCache`, a `(path, size) -> num_rows`
  cache.
- `partition_pred_bridge`: maps a partition predicate between its plan form
  (`komira_plan_expr.partition_pred_pod`) and the form the Hive discovery
  prunes with (`komira_fs.pruned_hive_discovery`).

Every example below runs as a test when the package is built.

## The footer

```mojo
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.metadata_parser import parse_full_metadata
from std.testing import assert_equal

# FileMetaData with version 2 (field 1, i32) and num_rows 3 (field 3, i64):
# each field header is `delta << 4 | type`, each integer a zigzag varint.
var footer: List[UInt8] = [0x15, 0x04, 0x26, 0x06, 0x00]
var buf = OwnedAlignedBuffer(len(footer))
buf.copy_from_bytes_list(footer)
var md = parse_full_metadata(buf.view_ro())
assert_equal(md.version, 2)
assert_equal(md.num_rows, 3)
```

## RLE / Bit-Packing Hybrid

```mojo
from komira_parquet.rle import RleDecoder
from std.testing import assert_equal

# An RLE run of 3 copies of 5, then one bit-packed group of 8 values 0..7,
# at a bit width of 3.
var data: List[UInt8] = [0x06, 0x05, 0x03, 0x88, 0xC6, 0xFA]
var out = List[Int32](length=11, fill=0)
var dec = RleDecoder(Span(data), 3)
assert_equal(dec.decode_int32(11, Span(out)), 11)
assert_equal(out[2], 5)
assert_equal(out[10], 7)
```

## DELTA_BINARY_PACKED

```mojo
from komira_parquet.delta import DeltaDecoder
from std.testing import assert_equal

# Block size 128, 4 miniblocks, 3 values, first value 10; then one block with
# a minimum delta of 2 and width-0 miniblocks: 10, 12, 14.
var data: List[UInt8] = [0x80, 0x01, 0x04, 0x03, 0x14, 0x04, 0, 0, 0, 0]
var out = List[Int64](length=3, fill=0)
var dec = DeltaDecoder(Span(data))
assert_equal(dec.decode_int64(3, Span(out)), 3)
assert_equal(out[2], 14)
```

## BYTE_STREAM_SPLIT

```mojo
from komira_parquet.byte_stream_split import decode_byte_stream_split_float32
from std.testing import assert_equal

# Two floats, 1.0 (0x3F800000) and 2.0 (0x40000000): byte 0 of each, then
# byte 1 of each, and so on.
var data: List[UInt8] = [0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x3F, 0x40]
var arr = decode_byte_stream_split_float32(Span(data), 2)
assert_equal(arr.get(1), 2.0)
```

## PLAIN

```mojo
from komira_parquet.plain import decode_plain_byte_array, decode_plain_int32
from std.testing import assert_equal

# Two Int32s, 1 and -2, little-endian.
var ints: List[UInt8] = [0x01, 0, 0, 0, 0xFE, 0xFF, 0xFF, 0xFF]
assert_equal(decode_plain_int32(Span(ints), 2).get(1), -2)
# BYTE_ARRAY: a 4-byte little-endian length, then the bytes.
var strs: List[UInt8] = [2, 0, 0, 0, 0x68, 0x69, 0, 0, 0, 0]
var arr = decode_plain_byte_array(Span(strs), 2)
assert_equal(arr.get(0), "hi")
assert_equal(arr.get(1), "")
```

## DECIMAL

```mojo
from komira_parquet.decimal_decode import decode_plain_flba_decimal_to_i128
from std.testing import assert_equal

# FLBA(2) DECIMAL(4, 2): -1.29 is the unscaled -129, big-endian 0xFF7F.
var data: List[UInt8] = [0xFF, 0x7F]
var arr = decode_plain_flba_decimal_to_i128(Span(data), 1, 2, 2)
assert_equal(arr.get_low(0), -129)
assert_equal(arr.precision, 4)
```

## RLE_DICTIONARY

```mojo
from komira_parquet.dictionary import DictionaryDecoder
from std.testing import assert_equal

# A dictionary page of three Int64s (10, 20, 30), then a data page: bit width
# 2, one bit-packed group of 8 codes 2, 0, 1, 2, 0, 0, 0, 0.
var entries: List[Int] = [10, 20, 30]
var dict_page = List[UInt8]()
for i in range(3):
    for k in range(8):
        dict_page.append(UInt8((entries[i] >> (8 * k)) & 0xFF))
var data_page: List[UInt8] = [0x02, 0x03, 0x92, 0x00]
var dec = DictionaryDecoder()
dec.init_dict_int64(Span(dict_page), 3)
var codes = dec.decode_indices(Span(data_page), 4)
var values = dec.resolve_int64(codes)
assert_equal(values.get(0), 30)
assert_equal(values.get(1), 10)
assert_equal(values.get(3), 30)
```

## Nested levels

```mojo
from komira_parquet.nested import reconstruct_list_column
from std.testing import assert_equal

# A required list of required elements: [[a, b, c], [d, e]] has definition
# level 1 at every element and repetition level 0 where a row starts.
var def_levels: List[Int32] = [1, 1, 1, 1, 1]
var rep_levels: List[Int32] = [0, 1, 1, 0, 1]
var col = reconstruct_list_column(def_levels, rep_levels, False, 0, 2)
var offsets = col._offsets.value().view_ro()
assert_equal(offsets.read_i32_le_at(4), 3)
assert_equal(offsets.read_i32_le_at(8), 5)
```

## Selection intervals

```mojo
from komira_arrow.boolean_array import BooleanArray
from komira_parquet.selection_vector import SelectionInterval
from std.testing import assert_equal

# Rows 2, 3 and 6 of 8 pass a filter: skip 2, select 2, then skip 2, select 1.
var mask = BooleanArray.allocate(8)
mask.data.set(2)
mask.data.set(3)
mask.data.set(6)
var runs = SelectionInterval.from_bool_mask(mask)
assert_equal(len(runs), 2)
assert_equal(Int(runs[1].skip), 2)
assert_equal(Int(runs[1].select), 1)
```

## The decode arms

```mojo
from komira_parquet.decode_arm_trace import delta_page_memcpy_enabled, reset_decode_arm_gates
from komira_parquet.decode_arm_trace import set_delta_page_memcpy_enabled
from std.testing import assert_false, assert_true

assert_true(delta_page_memcpy_enabled())
set_delta_page_memcpy_enabled(False)  # e.g. from a program's own flag
assert_false(delta_page_memcpy_enabled())
reset_decode_arm_gates()
```

## Tests

The tests are welded into the build: the package cannot be built while one of
them fails. Each encoding is checked against values encoded by the test itself
from the format's definition (parquet-format's Encodings.md), at every bit
width and at counts on both sides of each kernel's vector step, with sentinels
past every output to catch a write too far. The refusals are tested with the
hostile inputs they exist for. The footer readers are checked the same way:
footers, page headers and bloom filter headers are written by the tests from
parquet.thrift's field ids, files are written into the test's own scratch
directory, and a file system that is not mmap-backed is stood in by an
in-memory one. `test_no_env_reads` scans the package's sources: no
environment read, no raw pointer in a public signature, no import outside
the package's deps.
