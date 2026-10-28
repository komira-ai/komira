# =============================================================================
# SessionStats -- POD snapshot of session-wide worker statistics.
# =============================================================================
#
# A leaf translation unit holding the snapshot struct, so the engine context's
# `stats()` and the session context can both return it without a module cycle.
# The struct is a Copyable/Movable POD of three Int32 worker counts.
# =============================================================================


struct SessionStats(Copyable, Movable):
    """Plain-old-data snapshot of session-wide statistics.

    Read by user code (for observability) and by rate controllers. New
    fields (channel depths) are added at the end so existing consumers keep
    reading the same leading fields.
    """

    var num_compute_workers: Int32
    """Total worker count (num_p_workers + num_e_workers). 10 on M4."""

    var num_p_workers: Int32
    """P-tier worker count (USER_INITIATED QoS). 4 on M4."""

    var num_e_workers: Int32
    """E-tier worker count (BACKGROUND QoS). 6 on M4."""

    def __init__(out self):
        self.num_compute_workers = Int32(0)
        self.num_p_workers = Int32(0)
        self.num_e_workers = Int32(0)

    def __init__(
        out self,
        num_compute_workers: Int32,
        num_p_workers: Int32,
        num_e_workers: Int32,
    ):
        self.num_compute_workers = num_compute_workers
        self.num_p_workers = num_p_workers
        self.num_e_workers = num_e_workers
