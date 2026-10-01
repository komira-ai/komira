# =============================================================================
# komira_async.sync — async sync primitives
# =============================================================================
#
# Mirrors tokio's tokio/src/sync/{mutex,rwlock,semaphore,notify}.rs.
# Each is wait queue + Mechanism D futex park; guards implement RAII release
# on Drop; cancellation is observed between park-resume cycles.
#
# Pointer discipline: every guard uses `ref [origin] T` field shape tied to its parent lock's origin. ZERO
# wildcard origins; ZERO UnsafePointer in any guard surface.
#
# SelectFirstNotify
# combinator added. Two-source first-fires gating with idempotent second
# fires; consumed by a pool's PendingCheckout late-binding
# race (and any future two-source-race consumer).
# =============================================================================

from komira_async.sync.select import SelectFirstNotify
