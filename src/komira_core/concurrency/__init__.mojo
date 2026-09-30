# komira_core.concurrency — concurrency primitives.
#
# Public re-exports. Currently houses `spawn_drop` (detached background-drop
# primitive used by parallel combine drivers).
#
# It lives in this foundation package so engine runtime code can use it
# without depending on a worker-pool implementation.

from .spawn_drop import spawn_drop
