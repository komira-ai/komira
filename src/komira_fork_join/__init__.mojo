# =============================================================================
# komira_fork_join -- run one body on N threads and join them all
# =============================================================================
#
# A leaf package with no first-party dependencies. `fork_join(body, n)` runs
# `body.run(tid)` on `n` real threads and returns after every one has exited,
# which is the shape multi-threaded tests and benchmarks need. The failure
# rules and the safety argument are in the header of `fork_join.mojo`.
#
#     from komira_fork_join import ForkJoinBody, fork_join
# =============================================================================

from .fork_join import ForkJoinBody, fork_join
