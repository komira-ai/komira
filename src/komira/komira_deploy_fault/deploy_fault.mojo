# =============================================================================
# komira_deploy_fault/deploy_fault.mojo -- the deploy-fault RAISE PROTOCOL.
# =============================================================================
#
# A deploy step that raises can tell the reconciler driving it two things beyond
# "this failed":
#
#   * PERMANENT -- the raiser has OBSERVED that the fault cannot heal (for example
#     a 403 the wire actually returned). The reconciler converges on the first
#     attempt instead of spending its retry budget. The marker is a PREFIX, so a
#     fault that merely quotes another fault's text does not inherit it, and a
#     truncated durable `last_error` keeps it.
#   * IN FLIGHT -- the cloud already ACCEPTED the mutation and is still running it.
#     The reconciler RESETS its consecutive-fault streak instead of spending it.
#     Only for a wait that is independently bounded.
#
# Both stamps are idempotent. Raisers (the cloud bridges) and the reconciler share
# this vocabulary; it lives in its own leaf package so a raiser needs no
# dependency on the reconciler's package.
# =============================================================================

comptime PERMANENT_FAULT_PREFIX: String = "PermanentDeployFault: "


@always_inline
def fault_is_permanent(err: String) -> Bool:
    """True iff `err` carries the `PERMANENT_FAULT_PREFIX` a raiser stamps on a
    fault it has proven cannot heal. A PREFIX test, not a substring scan: a fault
    that merely QUOTES another fault's text (a wrapper, a log line echoed into a
    message) must not inherit its permanence."""
    var eb = err.as_bytes()
    var pb = PERMANENT_FAULT_PREFIX.as_bytes()
    if len(eb) < len(pb):
        return False
    for i in range(len(pb)):
        if eb[i] != pb[i]:
            return False
    return True


@always_inline
def mark_permanent_fault(message: String) -> String:
    """Stamp `message` as a fault the raiser has PROVEN will not heal, so the
    reconciler converges on the first attempt instead of spending the budget.
    Idempotent — a message already carrying the prefix is returned unchanged, so a
    re-stamp on a re-raise cannot double it."""
    if fault_is_permanent(message):
        return message.copy()
    return PERMANENT_FAULT_PREFIX + message


comptime IN_FLIGHT_FAULT_MARKER: String = "DeployWaitInFlight"


@always_inline
def fault_is_in_flight(err: String) -> Bool:
    """True iff `err` is a raiser REPORTING PROGRESS — a mutation the cloud has
    already ACCEPTED and is still executing — rather than a failure. Such a raise
    must RESET the entry-fault streak, never spend it."""
    return err.find(IN_FLIGHT_FAULT_MARKER) >= 0


@always_inline
def mark_in_flight_fault(message: String) -> String:
    """Stamp `message` as "accepted and still running — come back next tick".

    ⛔ ONLY for a wait that is INDEPENDENTLY BOUNDED (see the IN FLIGHT note in the file header). The
    stamper must also be able to prove the mutation was ACCEPTED: a raise that
    merely MIGHT have been accepted is a fault, and resetting the streak on it is
    how a permanently-stuck node becomes an infinite re-drive again.

    Idempotent, so a re-stamp on a re-raise cannot double it."""
    if fault_is_in_flight(message):
        return message.copy()
    return String("[") + IN_FLIGHT_FAULT_MARKER + String("] ") + message
