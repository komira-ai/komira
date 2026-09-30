# =============================================================================
# SourceCapabilities -- capability bitmask for morsel sources
# =============================================================================
#
# A format-agnostic capability descriptor with zero engine dependencies.
# Consulted by rewrite rules and the planner to gate source-specific
# optimization hooks (projection, decode filter, etc.).
# =============================================================================


struct SourceCapabilities(ImplicitlyCopyable, Movable):
    """Capability bitmask.

    Static source-of-truth consulted by rewrite rules and the planner. Every
    field defaults to False; sources opt in by setting them to True.
    Consumers gate calls on these bits -- a capability-guarded hook reached
    through a source that has it `False` is a planner bug.
    """

    var supports_projection: Bool
    var supports_decode_filter: Bool
    var supports_dict_preservation: Bool
    var supports_dynamic_filter: Bool
    var supports_row_group_pruning: Bool
    var supports_bypass_columns: Bool
    var supports_as_source: Bool

    # -------------------------------------------------------------------------
    # Streaming / boundedness bits. FIRST-CLASS capability flags the
    # streaming planner needs. Default False (a batch source is a bounded,
    # non-replayable scan). The
    # parallel surface for a *streaming* source is `StreamSourceCaps`
    # (`komira_morsel/streaming_source.mojo`); these bits exist HERE so the
    # plan-time check can consult one capability descriptor for any source
    # type without depending on the streaming-source trait: the exactly-once /
    # at-least-once plan-time decision and the unbounded global-sort
    # rejection both read them.
    # -------------------------------------------------------------------------

    var is_unbounded: Bool
    """True for a forever-running stream (broker tail, FS-tail, HTTP-WAL).
    A global sort / distinct / aggregate over an unbounded source with no
    bounding window is a plan-time error (the pipeline checker). False
    for every bounded scan (parquet / csv / in-memory / arrow)."""

    var replayable: Bool
    """True if the source can seek back to a checkpointed position and
    re-emit deterministically (the first requirement of exactly-once). Broker /
    WAL: yes; FS-tail: yes (re-discover + skip). A bounded scan is trivially
    replayable but leaves this False until a streaming source opts in."""

    var exactly_once_capable: Bool
    """True if the source satisfies its half of the EO contract: replayable
    AND its position is durably checkpointable. The planner ANDs this with
    the sink's `SinkClass` to decide exactly-once vs at-least-once at plan
    time."""

    def __init__(
        out self,
        supports_projection: Bool = False,
        supports_decode_filter: Bool = False,
        supports_dict_preservation: Bool = False,
        supports_dynamic_filter: Bool = False,
        supports_row_group_pruning: Bool = False,
        supports_bypass_columns: Bool = False,
        supports_as_source: Bool = False,
        is_unbounded: Bool = False,
        replayable: Bool = False,
        exactly_once_capable: Bool = False,
    ):
        self.supports_projection = supports_projection
        self.supports_decode_filter = supports_decode_filter
        self.supports_dict_preservation = supports_dict_preservation
        self.supports_dynamic_filter = supports_dynamic_filter
        self.supports_row_group_pruning = supports_row_group_pruning
        self.supports_bypass_columns = supports_bypass_columns
        self.supports_as_source = supports_as_source
        self.is_unbounded = is_unbounded
        self.replayable = replayable
        self.exactly_once_capable = exactly_once_capable
