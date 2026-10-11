# `komira_chunk`

The persistent, arena-backed chunk container, built on `komira_bump_arena`; its
`ChunkView` conforms to the `MorselView` seam of `komira_arrow`.

- `chunk`: `Chunk`, `ChunkVector` and `ChunkView`. A chunk is built once,
  filled per pull and reset in O(1) (arena rewind plus a generation bump),
  never reconstructed. A `ChunkView` carries the generation it was taken at, so
  a view that outlived a reset is caught instead of reading stale memory.
- Every field is a tracked value (`OwnedPointer`, byte-backed `List[UInt8]`, an
  inline array of descriptors); there is no owning wildcard-origin field.

There are no root re-exports; import each name from its module.
