# `komira_bump_arena`

An O(1)-reset bump allocator over a fixed-capacity byte region, built on
`komira_buffer` (`ByteView`).

- `bump_arena`: `BumpArena`. A request past capacity declines (the
  `ARENA_DECLINE` sentinel) instead of growing, so no page fault comes back
  inside a pull loop. Allocations are `ARENA_ALIGN`-aligned.
- The public API returns `ByteView` and typed scalars, never a raw pointer.

There are no root re-exports; import each name from its module.
