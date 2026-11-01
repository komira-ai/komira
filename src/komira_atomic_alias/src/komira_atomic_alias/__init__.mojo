# =============================================================================
# komira_atomic_alias — the ONE place this repo spells `Atomic[...]`.
# =============================================================================
#
# A komira SIBLING package with its own `-I` root and ZERO deps (it imports
# `std.atomic` and nothing else), so any package may depend on it without
# creating a cycle or pulling in a closure.
#
# Import it FLAT, the way komira packages are imported:
#
#     from komira_atomic_alias import AtomicI64
#     var counter = AtomicI64(0)
#     _ = counter.fetch_add(1)
#
# ⛔ DO NOT write `Atomic[DType.x]` in new code, and do not add an `Atomic`
# import to a module. `komira_atomic_alias/atypes.mojo` is the single file the
# Mojo 1.1 compiler cutover edits; a stray inline spelling puts a site back
# outside that window.
# =============================================================================

from .atypes import AtomicI8, AtomicI32, AtomicI64, AtomicU8, AtomicU32, AtomicU64
