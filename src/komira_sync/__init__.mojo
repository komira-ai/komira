# =============================================================================
# komira_sync -- a small mutual-exclusion lock for plain (non-async) code
# =============================================================================
#
# `SpinMutex` guards state that several OS threads reach through one shared
# handle (an `ArcPointer`), where the critical section is short and may do
# blocking work once in a while (a credential refresh over the network). A
# waiter spins, yields its time slice, then sleeps in short steps, so a long
# critical section does not burn a core per waiter.
#
#     from komira_sync import SpinMutex
# =============================================================================

from .spin_mutex import SpinMutex
