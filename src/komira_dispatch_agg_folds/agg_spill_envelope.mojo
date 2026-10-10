# =============================================================================
# agg_spill_envelope — the grace-hash spill ENVELOPE VERDICT vocabulary
# =============================================================================
#
# The codes and the value type that say WHETHER the grace-hash agg spill driver
# may serve an aggregate, and ON WHAT TERMS. The EVALUATION that produces one is
# `agg_spill_driver.spill_envelope_verdict` — it has to read that file's private
# key-surrogate and op maps, which is why the two are split: this file is the
# vocabulary every reader (router, trace, test) shares.
#
# ⛔ WHY A VERDICT AND NOT A BOOLEAN. A bare predicate makes the ROUTE it
# selects observable only as a wall-clock difference: a change to this envelope
# (admitting AVG, say) can move an aggregate between the spill driver and the
# strategy leaf by an order of magnitude in wall time while the routing decision
# above it (`route=spill_or_strategy`) reads the same, because that branch does
# not change when the envelope's answer does. The verdict is what makes the
# answer sayable: `code` is the decision, `describe()` names the terms or the
# descriptor that refused, and `agg_driver_witness` records the code.
# =============================================================================

comptime SPILL_ENV_NOT_CONSULTED: Int = -1
"""The envelope was never asked — this aggregate never reached the spill arm."""
comptime SPILL_ENV_ADMIT: Int = 0
"""In the envelope: the grace-hash spill driver may serve this aggregate."""
comptime SPILL_ENV_DECLINE_NO_KEYS: Int = 1
"""Zero group keys — a scalar agg has no grace-hash partitioning axis."""
comptime SPILL_ENV_DECLINE_KEY_SURROGATE: Int = 2
"""A group key with no canonical 8-byte surrogate (today: a STRING key)."""
comptime SPILL_ENV_DECLINE_NO_AGGS: Int = 3
"""Zero aggregates."""
comptime SPILL_ENV_DECLINE_OP_UNMAPPED: Int = 4
"""An aggregand op outside the row-format op map (today: STDDEV/VAR_SAMP)."""
comptime SPILL_ENV_DECLINE_STATE_WIDTH: Int = 5
"""An admitted op whose declared state does not fit the row format's ONE
8-byte cell — the guard that stops the NEXT widening from folding garbage."""


struct SpillEnvelopeVerdict(Copyable, Movable):
    """Whether the grace-hash spill envelope admits an aggregate, AND on what
    terms. `code` is the decision; the rest is what the trace needs to say why.

    ⚠ `at` is the INDEX of the descriptor that declined (key index for
    `..._KEY_SURROGATE`, agg index for `..._OP_UNMAPPED` / `..._STATE_WIDTH`),
    -1 when no single descriptor is responsible. It is what turns "declined"
    into "declined because agg 3 is a Welford state"."""

    var code: Int
    var at: Int
    var n_keys: Int
    var n_aggs: Int
    var n_avg_expanded: Int
    var keys_need_decode: Bool

    def __init__(
        out self,
        code: Int,
        at: Int = -1,
        n_keys: Int = 0,
        n_aggs: Int = 0,
        n_avg_expanded: Int = 0,
        keys_need_decode: Bool = False,
    ):
        self.code = code
        self.at = at
        self.n_keys = n_keys
        self.n_aggs = n_aggs
        self.n_avg_expanded = n_avg_expanded
        self.keys_need_decode = keys_need_decode

    def admitted(self) -> Bool:
        """THE GATE. `spill_route_supported` is exactly this."""
        return self.code == SPILL_ENV_ADMIT

    def describe(self) -> String:
        """One trace-safe token: `admit(...)` names the terms the driver runs on
        (how many keys, whether the drain has to invert a key surrogate, how many
        AVG outputs are served by the SUM+COUNT decomposition), `decline(...)`
        names the descriptor that refused."""
        if self.code == SPILL_ENV_NOT_CONSULTED:
            return String("not_consulted")
        if self.code == SPILL_ENV_ADMIT:
            return (
                String("admit(keys=")
                + String(self.n_keys)
                + String(",key_decode=")
                + String(self.keys_need_decode)
                + String(",aggs=")
                + String(self.n_aggs)
                + String(",avg_expanded=")
                + String(self.n_avg_expanded)
                + String(")")
            )
        if self.code == SPILL_ENV_DECLINE_NO_KEYS:
            return String("decline(no_group_keys)")
        if self.code == SPILL_ENV_DECLINE_NO_AGGS:
            return String("decline(no_aggs)")
        if self.code == SPILL_ENV_DECLINE_KEY_SURROGATE:
            return (
                String("decline(key")
                + String(self.at)
                + String("_no_canonical_surrogate)")
            )
        if self.code == SPILL_ENV_DECLINE_OP_UNMAPPED:
            return (
                String("decline(agg")
                + String(self.at)
                + String("_op_outside_row_map)")
            )
        if self.code == SPILL_ENV_DECLINE_STATE_WIDTH:
            return (
                String("decline(agg")
                + String(self.at)
                + String("_state_wider_than_one_cell)")
            )
        return String("decline(unknown)")
