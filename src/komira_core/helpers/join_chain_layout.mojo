# =============================================================================
# join_chain_layout -- the width of one hash-join chain entry
# =============================================================================
#
# The chain entry is `key + next`, 16 B fused, and the build-side index array
# is elided so `chain_idx` IS the build row. The build payload is not in the
# entry: every output row fetches it by index out of the build-side column.
# =============================================================================


# Words per chain entry under the fused layout: [key, next].
comptime JOIN_KN_WORDS: Int = 2
