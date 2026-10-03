# =============================================================================
# komira_async.observability — per-worker observability primitives
# =============================================================================
# Per-worker single-owner watchdogs for reactor stalls
# (20ms threshold) and hot-shard imbalance (CV > 0.3 alert). NOT shared
# across workers — aggregation is via borrowed-ref + stack-local sample
# collection, not ArcPointer.
#
# Standalone primitives. Worker integration (the `_stall_detector` +
# `_imbalance_metrics` fields on Worker[S]) waits for a real task scheduler.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer in any field — single-owner
#   - ZERO wildcard origins on public surface.
#   - ZERO unsafe_from_address.
# =============================================================================
