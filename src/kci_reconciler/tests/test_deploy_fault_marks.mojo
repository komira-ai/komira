# =============================================================================
# kci_reconciler/tests/test_deploy_fault_marks.mojo -- the PERMANENT and
#   IN-FLIGHT marks, and their trip through the real engine.
# =============================================================================
#
# The rule under test: stop retrying at once only on a PROVEN-PERMANENT fault,
# and reset the fault streak only for a mutation the cloud ACCEPTED (in flight).
# Both marks are prefixes kci writes; a message that quotes a marked fault
# inherits nothing.
#
# -- §A -- the marks in isolation.
# -- §B -- the marks through the REAL `apply_graph`. The engine re-raises a
#           node's failure with the node and verb on the front, which would bury
#           an inner mark mid-message where a prefix test cannot see it. §B is
#           what goes red if that re-raise stops carrying the mark.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_reconciler import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    ResourceGraph,
    ErasedResource,
    InMemoryStateStore,
    apply_graph,
    RETAIN_DELETE,
    VERB_CREATE,
    FAULT_UNSET,
    FAULT_CUSTOMER,
    fault_error,
    fault_domain_of_error,
    PERMANENT_FAULT_PREFIX,
    IN_FLIGHT_FAULT_PREFIX,
    fault_is_permanent,
    mark_permanent_fault,
    fault_is_in_flight,
    mark_in_flight_fault,
    fault_is_retryable,
    deploy_fault_message,
)


comptime _MSG: String = "CreateService: HTTP 403 PERMISSION_DENIED"


def _count(haystack: String, needle: String) -> Int:
    var n = 0
    var at = haystack.find(needle)
    while at >= 0:
        n += 1
        at = haystack.find(needle, at + needle.byte_length())
    return n


# =============================================================================
# §A -- the marks in isolation.
# =============================================================================
def test_the_permanent_mark_counts_only_at_the_start() raises:
    """A stamped message is permanent; the same words without the stamp are not
    (permanence is asserted by the raiser, never sniffed from the text); and the
    mark anywhere but the front does not count."""
    var marked = mark_permanent_fault(_MSG)
    assert_true(fault_is_permanent(marked), "a stamped message is permanent")
    assert_equal(marked, PERMANENT_FAULT_PREFIX + _MSG)
    assert_false(fault_is_permanent(_MSG), "an unstamped message is not")
    assert_false(
        fault_is_permanent(String("x") + PERMANENT_FAULT_PREFIX + _MSG),
        "the mark one byte in from the front does not count",
    )
    assert_false(fault_is_permanent(String("")))
    assert_false(fault_is_permanent(String("PermanentDeployFault")))


def test_a_quoted_fault_does_not_inherit_the_mark() raises:
    """A wrapper that embeds a marked fault in its own message has NOT proven its
    fault permanent, and has NOT proven a mutation accepted."""
    var permanent = mark_permanent_fault(_MSG)
    var in_flight = mark_in_flight_fault(_MSG)
    var quoting_p = String("wrapper: the inner call failed with ") + permanent
    var quoting_f = String("wrapper: the inner call failed with ") + in_flight
    assert_false(fault_is_permanent(quoting_p))
    assert_true(fault_is_retryable(quoting_p))
    assert_false(fault_is_in_flight(quoting_f))
    # A fault-domain token in front of a QUOTE does not open a door either: only
    # the mark DIRECTLY after the token counts.
    var tagged_quote = String(fault_error(FAULT_CUSTOMER, quoting_p))
    assert_false(fault_is_permanent(tagged_quote))


def test_the_in_flight_mark_counts_only_at_the_start() raises:
    var marked = mark_in_flight_fault(_MSG)
    assert_true(fault_is_in_flight(marked))
    assert_equal(marked, IN_FLIGHT_FAULT_PREFIX + _MSG)
    assert_false(fault_is_in_flight(_MSG))
    assert_false(fault_is_in_flight(String("x") + IN_FLIGHT_FAULT_PREFIX))
    # The bare word in a message is not the mark.
    assert_false(fault_is_in_flight(String("op DeployWaitInFlight: x")))


def test_both_stamps_are_idempotent() raises:
    """A re-stamp on a re-raise cannot double the mark."""
    var p = mark_permanent_fault(_MSG)
    assert_equal(mark_permanent_fault(p), p)
    var f = mark_in_flight_fault(_MSG)
    assert_equal(mark_in_flight_fault(f), f)
    var tagged = mark_permanent_fault(String(fault_error(FAULT_CUSTOMER, _MSG)))
    assert_equal(mark_permanent_fault(tagged), tagged)


def test_the_mark_and_the_fault_domain_compose_in_one_order() raises:
    """Stamping before or after `fault_error` gives the SAME string, with the
    domain token first so `fault_domain_of_error` still reads it."""
    var mark_then_tag = String(
        fault_error(FAULT_CUSTOMER, mark_permanent_fault(_MSG))
    )
    var tag_then_mark = mark_permanent_fault(
        String(fault_error(FAULT_CUSTOMER, _MSG))
    )
    assert_equal(mark_then_tag, tag_then_mark)
    assert_equal(
        mark_then_tag,
        String("[fault=customer] ") + PERMANENT_FAULT_PREFIX + _MSG,
    )
    assert_equal(fault_domain_of_error(tag_then_mark), FAULT_CUSTOMER)
    assert_true(fault_is_permanent(tag_then_mark))
    var f = mark_in_flight_fault(String(fault_error(FAULT_CUSTOMER, _MSG)))
    assert_equal(fault_domain_of_error(f), FAULT_CUSTOMER)
    assert_true(fault_is_in_flight(f))


def test_only_a_permanent_fault_stops_the_retries() raises:
    assert_false(fault_is_retryable(mark_permanent_fault(_MSG)))
    assert_true(fault_is_retryable(mark_in_flight_fault(_MSG)))
    assert_true(fault_is_retryable(_MSG))
    # An in-flight report is not a permanent fault, and the reverse.
    assert_false(fault_is_permanent(mark_in_flight_fault(_MSG)))
    assert_false(fault_is_in_flight(mark_permanent_fault(_MSG)))


def test_the_outer_stamp_is_the_one_read() raises:
    var p_over_f = mark_permanent_fault(mark_in_flight_fault(_MSG))
    assert_true(fault_is_permanent(p_over_f))
    assert_false(fault_is_in_flight(p_over_f))
    var f_over_p = mark_in_flight_fault(mark_permanent_fault(_MSG))
    assert_true(fault_is_in_flight(f_over_p))
    assert_false(fault_is_permanent(f_over_p))


def test_deploy_fault_message_is_the_raisers_words() raises:
    assert_equal(deploy_fault_message(mark_permanent_fault(_MSG)), _MSG)
    assert_equal(deploy_fault_message(mark_in_flight_fault(_MSG)), _MSG)
    assert_equal(
        deploy_fault_message(
            mark_permanent_fault(String(fault_error(FAULT_CUSTOMER, _MSG)))
        ),
        _MSG,
    )
    assert_equal(deploy_fault_message(_MSG), _MSG)


# =============================================================================
# §B -- through the real engine.
# =============================================================================
comptime _HOW_UNMARKED: Int = 0
comptime _HOW_PERMANENT: Int = 1
comptime _HOW_PERMANENT_CUSTOMER: Int = 2
comptime _HOW_IN_FLIGHT: Int = 3
comptime _HOW_QUOTES_PERMANENT: Int = 4


struct _RaisingNode(Resource, Movable, Deinitable):
    """A conformer whose `create` always raises, in the shape `_how` names."""

    var _lid: String
    var _how: Int

    def __init__(out self, lid: String, how: Int):
        self._lid = lid
        self._how = how

    def logical_id(mut self) -> String:
        return self._lid.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(
            self._lid.copy(), VERB_CREATE, String("scripted"), RETAIN_DELETE
        )

    def create(mut self, creds: Creds) raises -> String:
        if self._how == _HOW_PERMANENT:
            raise Error(mark_permanent_fault(_MSG))
        if self._how == _HOW_PERMANENT_CUSTOMER:
            raise fault_error(FAULT_CUSTOMER, mark_permanent_fault(_MSG))
        if self._how == _HOW_IN_FLIGHT:
            raise Error(mark_in_flight_fault(_MSG))
        if self._how == _HOW_QUOTES_PERMANENT:
            raise Error(
                String("poll failed after: ") + mark_permanent_fault(_MSG)
            )
        raise Error(_MSG)

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1

    def fault_domain(mut self, verb: String) raises -> Int:
        return FAULT_UNSET


def _apply_and_capture(how: Int) raises -> String:
    """Drive the real `apply_graph` over one failing node and return what it
    raised. The apply MUST raise; that is checked, not assumed."""
    var g = ResourceGraph()
    g.add(ErasedResource.erase(_RaisingNode(String("svc"), how)))
    var store = InMemoryStateStore()
    try:
        _ = apply_graph(g, Creds.none(), store)
    except e:
        return String(e)
    raise Error("apply_graph returned although the node's create raised")


def test_B1_a_permanent_fault_stays_permanent_through_the_engine() raises:
    var surfaced = _apply_and_capture(_HOW_PERMANENT)
    assert_true(fault_is_permanent(surfaced), surfaced)
    assert_false(fault_is_retryable(surfaced))
    # The engine still names the node and the verb, and the mark is not
    # repeated mid-message.
    assert_equal(
        surfaced,
        PERMANENT_FAULT_PREFIX
        + String("apply node 'svc' verb=create failed: ")
        + _MSG,
    )
    assert_equal(_count(surfaced, PERMANENT_FAULT_PREFIX), 1)


def test_B2_the_mark_and_a_stated_domain_both_survive() raises:
    var surfaced = _apply_and_capture(_HOW_PERMANENT_CUSTOMER)
    assert_equal(fault_domain_of_error(surfaced), FAULT_CUSTOMER)
    assert_true(fault_is_permanent(surfaced), surfaced)
    assert_equal(
        surfaced,
        String("[fault=customer] ")
        + PERMANENT_FAULT_PREFIX
        + String("apply node 'svc' verb=create failed: ")
        + _MSG,
    )


def test_B3_an_in_flight_report_stays_in_flight_through_the_engine() raises:
    var surfaced = _apply_and_capture(_HOW_IN_FLIGHT)
    assert_true(fault_is_in_flight(surfaced), surfaced)
    assert_true(fault_is_retryable(surfaced))
    assert_false(fault_is_permanent(surfaced))
    assert_equal(_count(surfaced, IN_FLIGHT_FAULT_PREFIX), 1)
    assert_equal(deploy_fault_message(surfaced), String(
        "apply node 'svc' verb=create failed: "
    ) + _MSG)


def test_B4_the_engine_does_not_sniff_a_quoted_mark() raises:
    """The node's own fault QUOTES a permanent one. The engine carries only a
    mark at the front of what the node raised, so this stays retryable."""
    var surfaced = _apply_and_capture(_HOW_QUOTES_PERMANENT)
    assert_false(fault_is_permanent(surfaced), surfaced)
    assert_true(fault_is_retryable(surfaced))


def test_B5_an_unmarked_fault_is_retryable_and_byte_identical() raises:
    var surfaced = _apply_and_capture(_HOW_UNMARKED)
    assert_true(fault_is_retryable(surfaced))
    assert_false(fault_is_in_flight(surfaced))
    assert_equal(
        surfaced, String("apply node 'svc' verb=create failed: ") + _MSG
    )


def main() raises:
    test_the_permanent_mark_counts_only_at_the_start()
    test_a_quoted_fault_does_not_inherit_the_mark()
    test_the_in_flight_mark_counts_only_at_the_start()
    test_both_stamps_are_idempotent()
    test_the_mark_and_the_fault_domain_compose_in_one_order()
    test_only_a_permanent_fault_stops_the_retries()
    test_the_outer_stamp_is_the_one_read()
    test_deploy_fault_message_is_the_raisers_words()
    test_B1_a_permanent_fault_stays_permanent_through_the_engine()
    test_B2_the_mark_and_a_stated_domain_both_survive()
    test_B3_an_in_flight_report_stays_in_flight_through_the_engine()
    test_B4_the_engine_does_not_sniff_a_quoted_mark()
    test_B5_an_unmarked_fault_is_retryable_and_byte_identical()
    print("OK test_deploy_fault_marks")
