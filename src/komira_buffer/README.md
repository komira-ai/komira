# komira_buffer

Aligned, shared and memory-mapped byte buffers and the region trait that columns sit on.

The package root re-exports nothing; import each name from its module:

- `komira_buffer.owned_aligned_buffer`: `OwnedAlignedBuffer`, a single-owner
  heap buffer whose start is 64-byte aligned and whose capacity is rounded up
  to a multiple of 64 bytes, so a SIMD load at the tail stays inside the
  allocation. A new buffer's length equals the capacity it was asked for.
- `komira_buffer.shared_aligned_buffer`: `SharedAlignedBuffer[K]`, the
  reference-counted buffer over a region `K` (`HeapRegion` by default,
  `MmapRegion` for a mapped file). `from_owned` promotes an
  `OwnedAlignedBuffer` without copying; `share` and `share_range_as` hand out
  more owners of the same bytes, the latter of a checked sub-range.
- `komira_buffer.copyable_shared_aligned_buffer`:
  `CopyableSharedAlignedBuffer[K]`, the same buffer made `Copyable` (a copy
  is a reference-count increment).
- `komira_buffer.memory_region`, `heap_region`, `mmap_region`: the
  `MemoryRegion` trait (what keeps a buffer's bytes alive) and its two
  conformers: `HeapRegion` owns a `List[UInt8]`; `MmapRegion.open_readonly`
  maps a file read-only and private and unmaps it when dropped.
- `komira_buffer.byte_view`: `ByteView[origin]`, a borrowed byte range tied to
  its owner's lifetime, with little-endian reads (and, on a mutable view,
  writes), `sub` and `split_at`.
- `komira_buffer.byte_buffer`: `ByteBuffer`, an owned byte list with a read
  cursor (fixed-width little-endian, ULEB128 and zigzag reads), and
  `write_uleb128`, its encoder.
- `komira_buffer.aligned_buffer_trait`: `AlignedBufferTrait`, the read, write
  and view methods both aligned buffers share.
- `komira_buffer.file_identity`: `FileIdentity`, what `stat(2)` says about
  a path (size, mtime, inode, device), to tell whether a cached file changed.
- `komira_buffer.hugepage_span`: the opt-in transparent-hugepage advice for
  large allocations; `komira_buffer.constants`: SIMD widths and cache-line
  size.

## Examples

Write little-endian values into an aligned buffer, read them back through a
view, then share an 8-byte window of it without copying. A range outside the
buffer is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer

var buf = OwnedAlignedBuffer(100)
assert_equal(buf.len(), 100)
assert_equal(buf.capacity(), 128)  # rounded up to a multiple of 64
assert_true(buf.is_aligned())
buf.set_length(16)
buf.write_u32_le_at(0, 0x04030201)
buf.write_i64_le_at(8, -2)
assert_equal(buf.read_u8_at(0), 0x01)  # little-endian: low byte first

var view = buf.view_ro()
assert_equal(view.len(), 16)
assert_equal(view.sub(0, 4).read_u32_le_at(0), 0x04030201)
assert_equal(view.read_i64_le_at(8), -2)

var shared = SharedAlignedBuffer[HeapRegion].from_owned(buf^)
var window = shared.share_range_as[HeapRegion](8, 8)
assert_equal(window.len(), 8)
assert_equal(window.read_i64_le_at(0), -2)  # the same bytes, no copy

var message = String()
try:
    _ = shared.share_range_as[HeapRegion](12, 8)
except e:
    message = String(e)
assert_equal(message, "SharedAlignedBuffer.share_range_as: range [12, 20) exceeds buffer length 16")
```

Encode varints and read them back with a cursor:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_buffer.byte_buffer import ByteBuffer, write_uleb128

var bytes = List[UInt8]()
write_uleb128(300, bytes)
assert_equal(bytes, [UInt8(0xAC), UInt8(0x02)])
write_uleb128(5, bytes)  # zigzag of -3
bytes.append(0x2A)

var cursor = ByteBuffer(bytes^)
assert_equal(cursor.read_uleb128(), 300)
assert_equal(cursor.read_zigzag_varint(), -3)
assert_equal(cursor.remaining(), 1)
assert_equal(cursor.read_byte(), 0x2A)
assert_true(cursor.is_empty())

var message = String()
try:
    _ = cursor.read_byte()
except e:
    message = String(e)
assert_equal(message, "ByteBuffer: read_byte past end of buffer")
```

Map a file read-only and read it in place; then `FileIdentity` tells that a
rewrite changed the file. The example works in a temporary directory it
removes even if a step fails:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.os import remove, rmdir
from std.os.path import exists
from std.tempfile import mkdtemp
from komira_buffer.file_identity import FileIdentity
from komira_buffer.mmap_region import MmapRegion

var dir = mkdtemp()
var path = dir + "/mapped.txt"
try:
    with open(path, "w") as f:
        f.write("komira!")

    var region = MmapRegion.open_readonly(path)
    var view = region.data()
    assert_equal(view.len(), 7)
    assert_equal(view.read_u8_at(0), UInt8(ord("k")))
    assert_equal(String(from_utf8=view.into_span()), "komira!")
    _ = region^  # unmapped here

    var before = FileIdentity.stat_path(path)
    assert_true(before.same_file_as(FileIdentity.stat_path(path)))
    with open(path, "w") as f:
        f.write("komira, rewritten")
    assert_false(before.same_file_as(FileIdentity.stat_path(path)))  # the size changed
    remove(path)
    assert_false(FileIdentity.stat_path(path).valid)  # gone
finally:
    if exists(path):
        remove(path)
    rmdir(dir)
```
