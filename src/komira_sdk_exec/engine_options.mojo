# =============================================================================
# engine_options -- the flags struct of an EngineContext
# =============================================================================
#
# One struct of values the caller fills from its own flags. Nothing in this
# package reads an environment variable: an absent variable and an empty one
# are the same bytes, and a flag can be required. A field whose absence differs
# from a value is an `Optional`.
#
# An option that changes the lowered plan reaches `lower` through the host
# profile (`EngineContext.host_profile`), so a plan's render shows it.

struct EngineOptions(Copyable, Movable):
    """What a caller may set on an engine context. Absent means the host
    profile's own value (what the hardware probe derives)."""

    var worker_count: Optional[Int]
    """Compute workers. Present values must be at least 1."""
    var memory_budget_bytes: Optional[Int]
    """The bytes the sinks of a query may reserve in total, which is the size
    of the segment pool. Present values must be at least 1."""

    def __init__(
        out self,
        worker_count: Optional[Int] = None,
        memory_budget_bytes: Optional[Int] = None,
    ):
        self.worker_count = worker_count
        self.memory_budget_bytes = memory_budget_bytes
