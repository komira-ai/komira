# komira_parquet

The Parquet reader core. This part of the package holds the value decoders of
the Parquet encodings, each a function of encoded bytes to values with no file,
page header or engine around it:

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
