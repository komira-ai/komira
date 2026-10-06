# komira_simd

SIMD byte-class, mask, copy, gather and bit-unpack primitives.

The kernels that columnar readers, parsers and filters share: substring
search and byte equality over spans, byte-class masks over 16- and 32-byte
chunks, per-lane popcounts, bit-packed integer unpacking, Arrow validity
bitmap packing, compress, gather, blend, horizontal adds and copies. Each
function lives in its own module (`komira_simd.popcount`,
`komira_simd.byte_class.byte_memmem`, ...); import it from there.

Inputs and outputs are values, `SIMD` vectors and `Span`s; no pointer
crosses the API. A kernel that writes takes a mutable `Span` the caller has
sized. The package's tests hold each SIMD kernel to a scalar reference
implementation.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Search and compare bytes

```mojo
from komira_simd.byte_class.byte_equal import bytes_equal
from komira_simd.byte_class.byte_memmem import find_needle
from std.testing import assert_equal, assert_false, assert_true

var text = "the quick brown fox jumps over the lazy dog".as_bytes()
assert_equal(find_needle(text, "lazy".as_bytes()), 35)
assert_equal(find_needle(text, "cat".as_bytes()), -1)
assert_equal(find_needle(text, "".as_bytes()), 0)

assert_true(bytes_equal("komira".as_bytes(), "komira".as_bytes()))
assert_false(bytes_equal("komira".as_bytes(), "komirb".as_bytes()))
```

## Count bits

```mojo
from komira_simd.popcount import popcount_mask, popcount_u8xW
from std.testing import assert_equal

# Per lane: the number of set bits in each byte.
var counts = popcount_u8xW(SIMD[DType.uint8, 4](0x00, 0x01, 0x0F, 0xFF))
assert_equal(Int(counts[0]), 0)
assert_equal(Int(counts[1]), 1)
assert_equal(Int(counts[2]), 4)
assert_equal(Int(counts[3]), 8)

# Across lanes: how many lanes of a filter mask are set.
var keep = SIMD[DType.bool, 4](True, False, True, False)
assert_equal(popcount_mask(keep), 2)
```

## Unpack bit-packed integers

`simd_unpack_bits` reads values packed most significant bit first. It
returns `False`, writing nothing, for a width it has no kernel for (the
covered widths are 1, 2 and the multiples of 8), so the caller falls back to
its own scalar loop.

```mojo
from komira_simd.bit_unpack import simd_unpack_bits
from std.testing import assert_equal, assert_false, assert_true

var packed: List[UInt8] = [0b11_10_01_00, 0b01_01_10_10]
var out: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0]
var dst = Span(out)
assert_false(simd_unpack_bits(Span(packed), 3, 4, dst))  # 3 bits: no kernel
assert_true(simd_unpack_bits(Span(packed), 2, 8, dst))

var want: List[Int64] = [3, 2, 1, 0, 1, 1, 2, 2]
assert_equal(out, want)
```

## Pack an Arrow validity bitmap

`pack_validity_from_null_flags` turns one null flag per row into an Arrow
validity bitmap (bit set = row present, least significant bit first) and
returns the null count.

```mojo
from komira_simd.validity_pack import pack_validity_from_null_flags
from std.testing import assert_equal

var is_null: List[Bool] = [False, True, False, False, True]
var bitmap: List[UInt8] = [0xFF]
var bits = Span(bitmap)
assert_equal(pack_validity_from_null_flags(Span(is_null), bits), 2)
assert_equal(bitmap[0], UInt8(0b0000_1101))  # rows 0, 2 and 3 are present
```
