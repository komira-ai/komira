# =============================================================================
# DynamicFilter — runtime build-side filter handed to a probe-side source
# =============================================================================
#
# Container for the build-side `BloomFilter` + the join-key column name on
# the probe side. Phase 1 of the wave-8 bloom-pushdown design ships this
# struct as scaffolding; integration into the executor / source-hooks
# pipeline is deferred to Phase 2 (see `an internal doc
# _pushdown_design.md` §11 "Phased delivery").
#
# Construction site (Phase 2): right after a SINK_HASH_BUILD segment
# finalizes (when the build batch + key name are both available).
# Consumption site (Phase 2): handed to the probe segment's
# `ParquetMorselSource` via `set_dynamic_filter`. The probe-side late-
# materialization path consults the filter on every decoded key and
# short-circuits non-matching rows before the OP_JOIN_PROBE / agg sink
# ever sees them.
#
# This is the v0.4 analogue of DuckDB's `Dynamic Filters: orderkey IN
# BF(orderkey)` plan-tree node and v0.3's runtime-filter plumbing.
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
        - The bloom is constructed at SINK_HASH_BUILD finalize time on the
          executor's main thread; readers (probe-side workers) only see
          it after a happens-before edge through the executor (the same
          edge that publishes `sink_outputs` to dependent segments).
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

        Used by the source-hook bridge: hooks are copyable but
        DynamicFilter is Movable-only at the struct level; this method
        gives callers a clean per-worker handle.
        """
        return DynamicFilter(
            self.key_col_name, ArcPointer[BloomFilter](copy=self.bloom)
        )
