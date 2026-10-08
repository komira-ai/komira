# komira_lz4

The LZ4 codecs over the system liblz4, in two framings that are not
interchangeable on the wire:

- `komira_lz4.codec`: the raw block. `lz4_compress` and `lz4_decompress`
  take a byte span and return a new `List[UInt8]`; `lz4_compress_into` and
  `lz4_decompress_into` write into a buffer the caller owns and return the
  number of bytes written; `lz4_compress_bound` is the size such a buffer
  needs. A raw block does not record its decoded size, so the caller keeps it.
- `komira_lz4.frame`: the LZ4 frame (magic `04 22 4D 18`, the framing Arrow IPC
  calls `LZ4_FRAME`). `lz4_frame_compress_into` writes one frame with liblz4's
  default preferences, `lz4_frame_decompress_into` decodes exactly one frame,
  `lz4_frames_decompress_into` decodes one or more concatenated frames, and
  `Lz4FrameDecoder` keeps one decompression context for reuse across frames.

liblz4 is opened at run time (`liblz4.so.1`, `liblz4.dylib` on macOS) once per
process, so there is nothing to link, but the library must be installed where
the program runs. A destination that is too small, a corrupt block or frame,
and a truncated frame each raise; nothing writes past the destination. The
package does no streaming compression and exposes no compression level or
frame preference.

## Examples

A raw block round trip. Repetitive input shrinks, and the caller passes the
original length back to decode it:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_lz4.codec import lz4_compress, lz4_decompress

var text = String("abcabcabc") * 100
var packed = lz4_compress(text.as_bytes())
assert_true(len(packed) < text.byte_length())

var unpacked = lz4_decompress(Span(packed), text.byte_length())
assert_equal(String(unsafe_from_utf8=unpacked), text)
```

Into a buffer the caller owns. The buffer must hold `lz4_compress_bound`
bytes; the empty input encodes as the one-byte empty block `0x00`, and a
corrupt block is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_lz4.codec import lz4_compress_bound, lz4_compress_into, lz4_decompress_into

var src = String("hello, hello, hello, hello").as_bytes()
var packed = List[UInt8](length=lz4_compress_bound(len(src)), fill=0)
var plen = lz4_compress_into(Span(packed), src)

var out = List[UInt8](length=len(src), fill=0)
assert_equal(lz4_decompress_into(Span(out), Span(packed)[0:plen]), len(src))
assert_equal(String(unsafe_from_utf8=out), "hello, hello, hello, hello")

var empty_src = List[UInt8]()
var empty_block = List[UInt8](length=lz4_compress_bound(0), fill=0)
assert_equal(lz4_compress_into(Span(empty_block), Span(empty_src)), 1)
assert_equal(empty_block[0], 0x00)

var corrupt: List[UInt8] = [0xFF, 0xFF, 0xFF]
var refused = False
try:
    _ = lz4_decompress_into(Span(out), Span(corrupt))
except:
    refused = True
assert_true(refused)
```

An LZ4 frame starts with its magic number, decodes with a fresh context or
with a reusable `Lz4FrameDecoder`, and a frame cut short is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_lz4.frame import Lz4FrameDecoder, lz4_frame_compress_bound
from komira_lz4.frame import lz4_frame_compress_into, lz4_frame_decompress_into

var data = (String("frame payload ") * 50).as_bytes()
var frame = List[UInt8](length=lz4_frame_compress_bound(len(data)), fill=0)
var flen = lz4_frame_compress_into(Span(frame), data)
assert_equal(frame[0], 0x04)
assert_equal(frame[1], 0x22)
assert_equal(frame[2], 0x4D)
assert_equal(frame[3], 0x18)

var out = List[UInt8](length=len(data), fill=0)
assert_equal(lz4_frame_decompress_into(Span(out), Span(frame)[0:flen]), len(data))
assert_equal(String(unsafe_from_utf8=out), String("frame payload ") * 50)

var decoder = Lz4FrameDecoder()
for _ in range(2):
    var again = List[UInt8](length=len(data), fill=0)
    assert_equal(decoder.decompress_into(Span(again), Span(frame)[0:flen]), len(data))

var truncated = False
try:
    _ = lz4_frame_decompress_into(Span(out), Span(frame)[0:flen - 1])
except:
    truncated = True
assert_true(truncated)
```
