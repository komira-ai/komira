# =============================================================================
# komira_async.morsel — morsel-stealing pool for OLAP partition skew
# =============================================================================
#
#
# MorselPool steals DATA CHUNKS (T = morsel descriptor), NOT parked tasks
# with their working sets. The compute kernel processing morsels is already
# on the stealing worker; only morsel data is loaded fresh.
#
# Single-owner OwnedPointer pattern. NO ArcPointer;
# NO runtime refcount. Workers borrow via `ref [pool_origin] MorselPool[T]`
# parameters threaded through TaskScope.spawn — Mojo's borrow checker
# enforces "pool outlives all spawned tasks" statically.
# =============================================================================
