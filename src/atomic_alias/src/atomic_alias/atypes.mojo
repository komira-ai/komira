# =============================================================================
# atomic_alias/atypes.mojo — the six fixed-width `Atomic` types of this repo.
# =============================================================================
#
# ⛔ DO NOT SPELL `Atomic[...]` ANYWHERE ELSE IN THIS REPO — import a name
#     from here.
#
# WHY IT EXISTS
# -------------
# `Atomic`'s type parameter is the generation-specific part of its spelling:
#
#     1.0.0   struct Atomic[dtype: DType, *, scope: StringSpan[ImmStaticOrigin]]
#     1.1.0   struct Atomic[T: Deinitable & Movable, *, scope: StringSpan[...]]
#
# The tree builds with Mojo 1.1.0, so the rows spell `Atomic[Int64]` and
# friends; 1.0.0 refuses that spelling. Keeping every spelling in this file
# bounds a later change of the parameter to these six lines instead of every
# call site. Each row is the `Atomic` type itself, not a wrapper, so no
# layout, movability or codegen question arises.
#
# ⚠ A `comptime` alias is elaborated LAZILY: a row nothing imports is never
# type-checked, so it would NOT fail on a compiler that cannot spell it. The
# welded test imports every row for exactly that reason, which is why the set
# is six fixed widths and not a speculative nine.
#
# `atomic_alias/tests/test_atomic_alias_widths.mojo` pins the width,
# signedness and round-trip of every row.
#
# Code that cannot depend on this package (because it is built without a
# komira `-I` root, or keeps no first-party deps by design) spells the
# native form, `Atomic[Int64]` and friends, inline.
# =============================================================================

from std.atomic import Atomic

comptime AtomicI8 = Atomic[Int8]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicI32 = Atomic[Int32]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicI64 = Atomic[Int64]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU8 = Atomic[UInt8]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU32 = Atomic[UInt32]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
comptime AtomicU64 = Atomic[UInt64]  # cov: unreachable a comptime alias emits no code, so no test binary holds a line of it
