# =============================================================================
# kci_reconciler/deploy_fault.mojo -- the deploy-fault RAISE PROTOCOL.
# =============================================================================
#
# A deploy step that raises can tell the reconciler driving it two things beyond
# "this failed":
#
#   * PERMANENT -- the raiser has OBSERVED that the fault cannot heal (for example
#     a 403 the wire actually returned). The caller stops retrying at once
#     instead of spending its retry budget.
#   * IN FLIGHT -- the cloud already ACCEPTED the mutation and is still running it.
#     The caller RESETS its consecutive-fault streak instead of spending it.
#     Only for a wait that is independently bounded.
#
# An unmarked fault is neither: it is retried, and it spends the streak.
#
# Both are tokens kci writes itself, never a match on the cloud's error text,
# and both are PREFIXES: a message that merely QUOTES a marked fault (a wrapper,
# a log line echoed into a message) does not inherit the mark. That matters most
# for IN FLIGHT, because a streak reset inherited by quotation is how a node that
# is stuck for good gets re-driven forever.
#
# The one thing allowed in front of a mark is our own fault-domain token
# (`fault_domain.fault_error`), so the two carriers compose in ONE order:
#
#     [fault=user] PermanentDeployFault: <message>
#
# Stamping in either order yields that shape, so `fault_domain_of_error` keeps
# reading the domain off the front. Both stamps are idempotent. When a fault is
# stamped twice with DIFFERENT marks the outer (later) stamp is the one read.
#
# The engine re-raises a node's failure with the node and verb added
# (`engine._node_verb_error`). That frame is not quoting: it carries the same
# fault, so it moves the inner mark to the front of the enriched error.
# =============================================================================

from kci_reconciler.fault_domain import fault_message_of_error


comptime PERMANENT_FAULT_PREFIX: String = "PermanentDeployFault: "
"""The PERMANENT mark. Stamped by `mark_permanent_fault`."""

comptime IN_FLIGHT_FAULT_MARKER: String = "DeployWaitInFlight"
"""The IN-FLIGHT word. `mark_in_flight_fault` writes it as
`IN_FLIGHT_FAULT_PREFIX`."""

comptime IN_FLIGHT_FAULT_PREFIX: String = "[DeployWaitInFlight] "
"""The IN-FLIGHT mark as it sits on the front of a message."""


@always_inline
def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _fault_tag_of(err: String) -> String:
    """The leading fault-domain token of `err` exactly as written (empty when
    there is none), so a re-stamp keeps it byte-for-byte."""
    var rest_len = fault_message_of_error(err).byte_length()
    var tag_len = err.byte_length() - rest_len
    if tag_len <= 0:
        return String("")
    return String(err[byte=0:tag_len])


def _has_mark(err: String, mark: String) -> Bool:
    """True iff `mark` is at the front of `err`, or directly after its leading
    fault-domain token. Nowhere else counts."""
    if _starts_with(err, mark):
        return True
    return _starts_with(fault_message_of_error(err), mark)


def _stamp(message: String, mark: String) -> String:
    """`mark` placed after any leading fault-domain token, else at the front."""
    var tag = _fault_tag_of(message)
    if tag.byte_length() == 0:
        return mark + message
    return tag + mark + fault_message_of_error(message)


def fault_is_permanent(err: String) -> Bool:
    """True iff `err` carries the PERMANENT mark a raiser stamps on a fault it has
    proven cannot heal. A PREFIX test, not a substring scan: a fault that merely
    QUOTES another fault's text has not proven ITS fault permanent."""
    return _has_mark(err, PERMANENT_FAULT_PREFIX)


def mark_permanent_fault(message: String) -> String:
    """Stamp `message` as a fault the raiser has PROVEN will not heal.

    Only for a fault the raiser observed (an answer the cloud actually returned),
    never for one it guesses at: a wrong PERMANENT mark turns a transient into a
    failed deploy. Idempotent: a message already carrying the mark is returned
    unchanged, so a re-stamp on a re-raise cannot double it."""
    if fault_is_permanent(message):
        return message.copy()
    return _stamp(message, PERMANENT_FAULT_PREFIX)


def fault_is_in_flight(err: String) -> Bool:
    """True iff `err` is a raiser REPORTING PROGRESS (a mutation the cloud has
    already ACCEPTED and is still executing) rather than a failure. Such a raise
    resets the consecutive-fault streak instead of spending it. A PREFIX test,
    like `fault_is_permanent`, so quoting an in-flight message resets nothing."""
    return _has_mark(err, IN_FLIGHT_FAULT_PREFIX)


def mark_in_flight_fault(message: String) -> String:
    """Stamp `message` as "accepted and still running, come back next tick".

    Only for a wait that is INDEPENDENTLY BOUNDED, and only when the stamper can
    prove the mutation was ACCEPTED: a raise that merely MIGHT have been accepted
    is a fault, and resetting the streak on it makes a node that is stuck for
    good an endless re-drive. Idempotent."""
    if fault_is_in_flight(message):
        return message.copy()
    return _stamp(message, IN_FLIGHT_FAULT_PREFIX)


def fault_is_retryable(err: String) -> Bool:
    """The retry decision: stop at once only on a PROVEN-PERMANENT fault. Every
    other fault, marked in flight or unmarked, is retried."""
    return not fault_is_permanent(err)


def deploy_fault_message(err: String) -> String:
    """`err` with its leading fault-domain token and its leading deploy-fault
    mark removed: the message as the raiser wrote it. A message with neither is
    returned byte-identical."""
    var body = fault_message_of_error(err)
    if _starts_with(body, PERMANENT_FAULT_PREFIX):
        var n = PERMANENT_FAULT_PREFIX.byte_length()
        return String(body[byte=n : body.byte_length()])
    if _starts_with(body, IN_FLIGHT_FAULT_PREFIX):
        var n = IN_FLIGHT_FAULT_PREFIX.byte_length()
        return String(body[byte=n : body.byte_length()])
    return body^


def carry_deploy_fault_mark(inner: String, message: String) -> String:
    """`message` (a re-raise of the fault `inner`) stamped with the mark that
    `inner` carries, if any. This is for a frame that re-raises the SAME fault
    with more context; a frame raising a fault of its own must not use it."""
    if fault_is_permanent(inner):
        return mark_permanent_fault(message)
    if fault_is_in_flight(inner):
        return mark_in_flight_fault(message)
    return message.copy()
