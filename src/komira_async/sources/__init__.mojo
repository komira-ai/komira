# =============================================================================
# komira_async.sources — IO source operator scaffolding
# =============================================================================
# PrefetchSource trait + bulk-parallel pattern. This
# package hosts the canonical shape for IO operators. Operator authors
# compose `PrefetchRing[S, Output]` as a field on their struct and follow
# the documented `next_op` + `decode` shape; the ring handles the prefetch
# refill loop + completion polling + parking.
#
# Mojo 0.26.3 traits do not support associated types (`alias Output`)
# cleanly enough to express a trait shape directly. The closest
# workable shape is **composition**: ship
# `PrefetchRing[S, Output]` as a helper that operators compose, with the
# step body provided as a free-function template (`prefetch_source_step`)
# that operates on the ring + caller-supplied `next_op` / `decode`
# closures. This is structurally identical to the trait+default-impl
# shape — every operator goes through the same primitive — without
# requiring Mojo to support trait-default with associated types.
# =============================================================================
