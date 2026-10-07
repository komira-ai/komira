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

Every public decoder takes the encoded bytes as a `Span[UInt8]` and writes into
a `Span` (or a buffer) whose length it respects: a request larger than the
output is cut to it or refused, never written past it. Corrupt input (a
negative length, a value count the page cannot hold, a run or block header
that decodes to a negative or overflowing size) raises or stops the decode; it
never reads or writes outside the input and output.

Every example below runs as a test when the package is built.

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
hostile inputs they exist for. `test_no_env_reads` scans the package's
sources: no environment read, no raw pointer in a public signature, no import
outside the package's deps.
