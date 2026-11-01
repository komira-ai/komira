# =============================================================================
# komira_atomic_alias/atypes.mojo — THE MOJO 1.1 ATOMIC CUTOVER FILE.
# =============================================================================
#
# ⛔⛔ THIS FILE IS THE ENTIRE CUTOVER WINDOW FOR `Atomic`. DO NOT SPELL
#     `Atomic[...]` ANYWHERE ELSE IN THIS REPO — import a name from here.
#
# WHY IT EXISTS
# -------------
# `Atomic`'s type parameter changes generation between the Mojo compiler we
# ship today and the next one, and the two spellings do not overlap:
#
#     1.0.0   struct Atomic[dtype: DType, *, scope: StringSpan[ImmStaticOrigin]]
#     1.1.0   struct Atomic[T: Deinitable & Movable, *, scope: StringSpan[...]]
#
# On a 1.0.0 compiler the `Atomic[DType.int64]` spelling builds and
# `Atomic[Int64]` does not; on 1.1.0 it is the other way round. Either way the
# failure is in THIS FILE AND NOWHERE ELSE. That is the whole point: it bounds
# the blast radius of the compiler cutover to these six lines instead of every
# call site that would otherwise spell `Atomic[DType.x]` inline.
# `size_of`/`align_of` agree across both spellings, so this is the SAME TYPE,
# not a wrapper — no layout, movability or codegen question arises.
#
# ⚠ A `comptime` alias is elaborated LAZILY: a row nothing imports is never
# type-checked, so it would NOT fail on a compiler that cannot spell it. The
# welded test imports every row for exactly that reason, which is why the set
# is six fixed widths and not a speculative nine.
#
# AT CUTOVER, and only at cutover, rewrite the six RHS spellings to
# `Atomic[Int64]` / `Atomic[Int32]` / `Atomic[Int8]` / `Atomic[UInt64]` /
# `Atomic[UInt32]` / `Atomic[UInt8]`.
# Falsifier: `komira_atomic_alias/tests/test_atomic_alias_widths.mojo`, which
# pins the width, signedness and round-trip of every row and must stay green
# across that edit.
#
# Other code that spells `Atomic[DType.x]` natively must also be edited at
# cutover. Code that cannot depend on this package (because it is built
# without a komira `-I` root, or keeps no first-party deps by design) spells
# the native form inline; its cutover edit is to `Atomic[Int64]` and friends,
# and a missed one turns into a build failure.
# =============================================================================

from std.atomic import Atomic

comptime AtomicI8 = Atomic[DType.int8]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicI32 = Atomic[DType.int32]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicI64 = Atomic[DType.int64]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU8 = Atomic[DType.uint8]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU32 = Atomic[DType.uint32]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU64 = Atomic[DType.uint64]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
