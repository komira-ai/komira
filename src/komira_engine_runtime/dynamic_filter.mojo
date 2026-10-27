# =============================================================================
# DynamicFilter — runtime build-side filter handed to a probe-side source
# =============================================================================
#
# Container for the build-side `BloomFilter` plus the join-key column name on
# the probe side. It is built when a hash-build sink finalizes, and handed to
# the probe side's source, which tests each decoded key against the bloom and
# drops non-matching rows early.
# =============================================================================

from std.memory import ArcPointer

from komira_dynamic_filter.bloom_filter import BloomFilter


struct DynamicFilter(Movable):
    """Runtime build-side filter shared between build sink and probe source.

    Fields:
        key_col_name: The probe-side column to test against the bloom.
            Resolution to a column index happens lazily inside the late-
            mat path so we don't depend on the source's projection state
            at construction time.
        bloom: ArcPointer-shared BloomFilter populated from the build-side
            join-key column. Read-only after construction (no concurrent
            inserts); the parallel probe workers all share one filter via
            independent Arc clones.

    Lifetime / safety:
        - The bloom is constructed when the hash-build sink finalizes;
          readers (probe-side workers) must only see it after a
          happens-before edge from that point.
        - ArcPointer's atomic refcount makes the cross-thread clone /
          drop safe; the underlying BloomFilter has no mutable state once
          insert_int64 has finished.
    """

    var key_col_name: String
    var bloom: ArcPointer[BloomFilter]

    def __init__(out self, key_col_name: String, var bloom: ArcPointer[BloomFilter]):
        self.key_col_name = key_col_name
        self.bloom = bloom^

    def copy(self) -> DynamicFilter:
        """Clone the filter (refcount bump on the underlying bloom).

        DynamicFilter is Movable-only at the struct level; this method
        gives each worker its own handle on the same bloom.
        """
        return DynamicFilter(
            self.key_col_name, ArcPointer[BloomFilter](copy=self.bloom)
        )
