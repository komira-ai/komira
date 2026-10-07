# komira_zlib

One-shot deflate and inflate, a stream skipper and CRC-32 over the system libz,
which is opened at run time (`libz.so.1`, `libz.dylib` on macOS) so there is
nothing to link. Every entry takes a byte span and writes into a buffer the
caller owns:

- `zlib_deflate_into(dst, src, level, window_bits)` compresses all of `src` as
  one stream and returns the bytes written; `dst` must hold
  `zlib_compress_bound(len(src), window_bits)` bytes.
- `zlib_inflate_into(dst, src, window_bits)` decodes the stream at the start of
  `src` and returns the bytes written. A stream that does not fit in `dst`, is
  corrupt, or fails its Adler-32 / CRC-32 check is refused, and so is a `src`
  that ends before the stream does (truncated). Bytes in `src` after the end
  of the first stream are not read: a gzip file of several members decodes its
  first member only.
- `zlib_inflate_once` is one `inflate` call whose return code and counts come
  back unjudged, for a caller with its own policy on a full destination.
- `zlib_skip_stream` returns how many bytes the stream at the start of `src`
  occupies, to walk concatenated streams that carry no length prefix.
- `zlib_crc32` is the CRC-32 of the gzip trailer, continuable across pieces.

`window_bits` picks the framing: `ZLIB_WINDOW_BITS_ZLIB` (RFC 1950),
`ZLIB_WINDOW_BITS_RAW` (RFC 1951, raw deflate), `ZLIB_WINDOW_BITS_GZIP`
(RFC 1952), and, for inflate only, `ZLIB_WINDOW_BITS_AUTO` (zlib or gzip,
detected). There is no incremental streaming API and no gzip header fields
(file name, time) are written or read.

## Examples

A gzip round trip, and the empty input as a 20-byte gzip stream (the 10-byte
RFC 1952 header, a 2-byte empty deflate block and the 8-byte CRC-32 / size
trailer):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_zlib import ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP
from komira_zlib import zlib_compress_bound, zlib_deflate_into, zlib_inflate_into

var text = String("to be or not to be, ") * 40
var src = text.as_bytes()
var packed = List[UInt8](length=zlib_compress_bound(len(src), ZLIB_WINDOW_BITS_GZIP), fill=0)
var plen = zlib_deflate_into(Span(packed), src, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP)
assert_equal(packed[0], 0x1F)  # the gzip magic
assert_equal(packed[1], 0x8B)

var out = List[UInt8](length=len(src), fill=0)
assert_equal(zlib_inflate_into(Span(out), Span(packed)[0:plen]), len(src))
assert_equal(String(unsafe_from_utf8=out), text)

var empty = List[UInt8]()
var empty_gz = List[UInt8](length=zlib_compress_bound(0, ZLIB_WINDOW_BITS_GZIP), fill=0)
assert_equal(zlib_deflate_into(Span(empty_gz), Span(empty), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP), 20)
```

Two zlib streams back to back: `zlib_skip_stream` finds where the second one
starts. A destination one byte short and a stream with a flipped byte are both
refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_zlib import ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB
from komira_zlib import zlib_compress_bound, zlib_deflate_into, zlib_inflate_into, zlib_skip_stream

var first = String("first stream, first stream").as_bytes()
var second = String("second").as_bytes()
var bound = zlib_compress_bound(len(first), ZLIB_WINDOW_BITS_ZLIB)
bound += zlib_compress_bound(len(second), ZLIB_WINDOW_BITS_ZLIB)
var packed = List[UInt8](length=bound, fill=0)
var a = zlib_deflate_into(Span(packed), first, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB)
var b = zlib_deflate_into(Span(packed)[a:], second, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB)
var both = Span(packed)[0 : a + b]

assert_equal(zlib_skip_stream(both), a)
var out = List[UInt8](length=len(second), fill=0)
assert_equal(zlib_inflate_into(Span(out), both[a:]), len(second))
assert_equal(String(unsafe_from_utf8=out), "second")

var short = List[UInt8](length=len(second) - 1, fill=0)
var refused = False
try:
    _ = zlib_inflate_into(Span(short), both[a:])
except:
    refused = True
assert_true(refused)

packed[a - 1] ^= 0xFF  # the last byte of the first stream's Adler-32
var big = List[UInt8](length=len(first), fill=0)
refused = False
try:
    _ = zlib_inflate_into(Span(big), Span(packed)[0:a])
except:
    refused = True
assert_true(refused)
```

The CRC-32 check value of the digits `123456789`, whole and in two pieces:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_zlib import zlib_crc32

assert_equal(zlib_crc32("123456789".as_bytes()), 0xCBF43926)
var head = zlib_crc32("1234".as_bytes())
assert_equal(zlib_crc32("56789".as_bytes(), head), 0xCBF43926)
assert_equal(zlib_crc32("".as_bytes()), 0)
```
