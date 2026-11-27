# `chunk`

The persistent, arena-backed chunk container, built on `bump_arena`; its
`ChunkView` conforms to the `MorselView` seam of `arrow`.

- `chunk`: `Chunk`, `ChunkVector` and `ChunkView`. A chunk is built once,
  filled per pull and reset in O(1) (arena rewind plus a generation bump),
  never reconstructed. A `ChunkView` carries the generation it was taken at, so
  a view that outlived a reset is caught instead of reading stale memory.
- Every field is a tracked value (`OwnedPointer`, byte-backed `List[UInt8]`, an
  inline array of descriptors); there is no owning wildcard-origin field.

There are no root re-exports; import each name from its module.

## Fill, read, reset

A chunk is built with a row grain and an arena size, a column is bound once
with `bind_column`, and `store_scalar` fills it. `chunk_view_over` reads it
back. `reset` rewinds the arena in O(1), keeps the bound columns and bumps the
generation, so a generation captured before the reset is reported stale by
`is_generation_current`.

```mojo
from chunk.chunk import Chunk, chunk_view_over, CHUNK_KIND_FLAT
from std.sys import size_of
from std.testing import assert_equal, assert_false, assert_true

# The tag is a diagnostic dtype label; the typed load is chosen by DType.
var i64_tag = UInt8(10)
var grain = 64
var c = Chunk(grain, grain * size_of[Int64]() + 2048)
assert_true(c.bind_column(i64_tag, size_of[Int64]()))
assert_equal(c.num_live_cols(), 1)
assert_equal(Int(c.col_kind(0)), Int(CHUNK_KIND_FLAT))

for i in range(grain):
    c.store_scalar[DType.int64](0, i, Int64(i * 3))
c.set_n_rows(grain)
assert_equal(c.num_rows(), grain)

var cv = chunk_view_over(c)
assert_equal(cv.n_rows(), grain)
assert_true(cv.is_valid())
assert_equal(cv.col_load_scalar[DType.int64](0, 5), Int64(15))

var before = c.gen()
c.reset()
assert_false(c.is_generation_current(before))
assert_true(c.is_generation_current(c.gen()))
assert_equal(c.num_rows(), 0)
assert_equal(c.num_live_cols(), 1)
```
