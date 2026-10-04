# =============================================================================
# kci_reconciler/tests/test_fault_domain_defaults_to_ours.mojo — the FALSIFIER for
#   "an unclassified deploy error is OUR responsibility".
# =============================================================================
#
# ★ THE QUESTION: which deploy errors are OUR responsibility to fix?
# The whole scheme turns on ONE decision — an error
# NOBODY classified reads as OURS — and this file is what makes that decision
# falsifiable rather than a docstring.
#
# WHY THIS IS THE TEST THAT MATTERS. Flipping the default the other way is a
# one-character change that breaks nothing visible: every deploy still runs,
# every error still surfaces, every existing test still passes. The only symptom
# is that our own bugs stop arriving in our queue — which is invisible exactly
# because it is silence. So the default is asserted here from FIVE independent
# directions (the constant, the type's default ctor, an unknown domain, an
# untagged error, and a classifier that itself failed), because a single
# assertion on a single spelling is the kind of guard a refactor walks past.
#
# ── §A — the predicate + the type, in isolation.
# ── §B — the two carriers, over the REAL `apply_graph`. §B is the half that can
#        catch a WIRING regression: the classification travels conformer ->
#        `ErasedResource` vtable -> `engine._node_fault_domain` -> the raised
#        error's token, and any link dropped makes B2/B3 red while everything
#        else in the repo stays green. Deleting `ErasedResource.fault_domain`'s
#        forward — the single most likely future mistake, because it FAILS SAFE
#        and therefore produces no other symptom — reds B2 and B3 specifically.
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
    FAULT_OURS,
    FAULT_CUSTOMER,
    FAULT_PROVIDER,
    FaultAttribution,
    is_our_responsibility,
    fault_domain_is_classified,
    fault_domain_word,
    fault_domain_of_word,
    fault_error,
    fault_domain_of_error,
    fault_message_of_error,
)


# =============================================================================
# §A — the predicate + the type.
# =============================================================================
def test_unset_is_ours() raises:
    """THE DECISION ITSELF. `FAULT_UNSET` — the value every unconsidered site
    produces — is OUR responsibility."""
    assert_true(
        is_our_responsibility(FAULT_UNSET),
        String("an UNCLASSIFIED error must read as OURS"),
    )
    assert_true(is_our_responsibility(FAULT_OURS))
    assert_false(is_our_responsibility(FAULT_CUSTOMER))
    assert_false(is_our_responsibility(FAULT_PROVIDER))


def test_unset_is_zero() raises:
    """`FAULT_UNSET` is 0 SPECIFICALLY, so that a zero-initialised field, an
    omitted argument and a default-constructed record all land on the fail-safe
    value rather than on whichever constant happened to be numbered first."""
    assert_equal(FAULT_UNSET, 0)


def test_a_domain_this_build_never_heard_of_is_ours() raises:
    """FORWARD COMPATIBILITY, IN THE SAFE DIRECTION. A row written by a newer
    binary carrying a domain code this one does not know must land in OUR queue,
    not somebody else's. This is what `is_our_responsibility`'s exclusion-list
    spelling buys, and it is why adding a constant cannot silently de-file our
    own errors."""
    assert_true(is_our_responsibility(99))
    assert_true(is_our_responsibility(-1))


def test_default_constructed_attribution_is_ours_and_unclassified() raises:
    """A caller that declares a `FaultAttribution` and never has it filled —
    because the failure came from a path nobody has retrofitted — reports OUR
    responsibility, and reports that nobody classified it. The two facts are
    separate on purpose: "ours" and "nobody looked" must never be indis-
    tinguishable to whoever decides whether to page."""
    var a = FaultAttribution()
    assert_equal(a.domain, FAULT_UNSET)
    assert_true(a.is_ours())
    assert_false(a.is_classified())
    assert_false(fault_domain_is_classified(a.domain))
    # An explicit OURS is ours AND classified — the distinction that makes the
    # classified fraction a meaningful coverage number.
    var b = FaultAttribution(
        FAULT_OURS, String("n"), String("create"), String("boom")
    )
    assert_true(b.is_ours())
    assert_true(b.is_classified())


def test_operator_line_says_unclassified_out_loud() raises:
    """The operator surface must not render an unclassified fault identically to
    a deliberately-attributed one."""
    var unclassified = FaultAttribution().operator_line()
    assert_true(String("OURS") in unclassified)
    assert_true(String("unclassified") in unclassified)
    var stated = FaultAttribution(
        FAULT_OURS, String("svc"), String("create"), String("boom")
    ).operator_line()
    assert_true(String("OURS") in stated)
    assert_false(String("unclassified") in stated)
    assert_true(String("node=svc") in stated)
    assert_true(String("verb=create") in stated)
    var theirs = FaultAttribution(
        FAULT_CUSTOMER, String("svc"), String("create"), String("boom")
    ).operator_line()
    assert_true(String("NOT OURS") in theirs)


def test_wire_tokens_round_trip_and_unknown_words_are_ours() raises:
    """The tokens cross a process boundary (a stored log row, a JSON body), so
    an Int renumbering must never silently re-attribute a row a previous binary
    wrote. An unrecognised WORD is `FAULT_UNSET` — ours — never a raise and never
    a guess."""
    assert_equal(fault_domain_of_word(fault_domain_word(FAULT_OURS)), FAULT_OURS)
    assert_equal(
        fault_domain_of_word(fault_domain_word(FAULT_CUSTOMER)), FAULT_CUSTOMER
    )
    assert_equal(
        fault_domain_of_word(fault_domain_word(FAULT_PROVIDER)), FAULT_PROVIDER
    )
    assert_equal(fault_domain_of_word(String("martian")), FAULT_UNSET)
    assert_true(is_our_responsibility(fault_domain_of_word(String(""))))
    # An unknown Int renders as the fail-safe word, not as a number.
    assert_equal(fault_domain_word(99), String("unset"))


def test_an_untagged_error_is_ours_and_byte_identical() raises:
    """AN UNTAGGED ERROR IS THE COMMON CASE. Reading one must yield OURS,
    and stripping one must return it UNCHANGED — so this scheme existing cannot
    move a single character of a message an operator already greps for."""
    var raw = String("CreateService: HTTP 403 PERMISSION_DENIED on projects/p")
    assert_equal(fault_domain_of_error(raw), FAULT_UNSET)
    assert_true(is_our_responsibility(fault_domain_of_error(raw)))
    assert_equal(fault_message_of_error(raw), raw)
    var recovered = FaultAttribution.of_error(
        raw, String("svc"), String("create")
    )
    assert_true(recovered.is_ours())
    assert_false(recovered.is_classified())
    assert_equal(recovered.reason, raw)


def test_a_stated_domain_survives_the_raise() raises:
    """The raise-site carrier: the only channel a Mojo `Error` has is a String,
    so a stated domain rides a canonical token WE author. The message is
    otherwise verbatim."""
    var msg = String("the customer revoked roles/run.admin on their project")
    var e = fault_error(FAULT_CUSTOMER, msg)
    assert_equal(fault_domain_of_error(String(e)), FAULT_CUSTOMER)
    assert_false(is_our_responsibility(fault_domain_of_error(String(e))))
    assert_equal(fault_message_of_error(String(e)), msg)
    # An explicitly-UNSET stamp is legal and still reads as ours: a site that
    # looked and genuinely could not tell must be able to SAY so, and it must
    # not thereby move the error out of our queue.
    var u = fault_error(FAULT_UNSET, msg)
    assert_equal(fault_domain_of_error(String(u)), FAULT_UNSET)
    assert_true(is_our_responsibility(fault_domain_of_error(String(u))))
    assert_equal(fault_message_of_error(String(u)), msg)


def test_a_malformed_token_is_ours() raises:
    """The reader matches ONE fixed prefix that `fault_error` wrote. Anything
    that merely LOOKS like it — an unterminated token, an unknown word, the word
    `customer` appearing in a backend message — is not our token, and not-our-
    token means UNSET, which means ours. This is the guard against the reader
    ever drifting into prose matching."""
    assert_true(is_our_responsibility(fault_domain_of_error(String("[fault=cus"))))
    assert_true(
        is_our_responsibility(fault_domain_of_error(String("[fault=martian] x")))
    )
    assert_true(
        is_our_responsibility(
            fault_domain_of_error(
                String("403: the customer principal is not permitted")
            )
        )
    )
    # ...and a token that is not at the FRONT does not count either.
    assert_true(
        is_our_responsibility(
            fault_domain_of_error(String("backend said [fault=customer] once"))
        )
    )
    # A malformed token is left in place by the stripper rather than half-eaten.
    var half = String("[fault=cus")
    assert_equal(fault_message_of_error(half), half)


# =============================================================================
# §B — the two carriers, driven through the REAL engine.
# =============================================================================
struct _FailingNode(Resource, Movable, Deinitable):
    """A synthetic conformer whose `create` always raises, parameterised by HOW
    it attributes the failure — so one struct exercises every arm of
    `engine._node_fault_domain`'s precedence.

      * `_declared`     — what `fault_domain(verb)` returns (the per-verb
                          carrier). `FAULT_UNSET` models a conformer nobody has
                          considered, which is the common case.
      * `_raise_domain` — when not `FAULT_UNSET`, `create` raises via
                          `fault_error` (the per-raise carrier).
      * `_classifier_explodes` — `fault_domain` itself raises, modelling the one
                          way a classifier can make a failing deploy WORSE."""

    var _lid: String
    var _declared: Int
    var _raise_domain: Int
    var _classifier_explodes: Bool

    def __init__(
        out self,
        lid: String,
        declared: Int,
        raise_domain: Int,
        classifier_explodes: Bool,
    ):
        self._lid = lid
        self._declared = declared
        self._raise_domain = raise_domain
        self._classifier_explodes = classifier_explodes

    def logical_id(mut self) -> String:
        return self._lid.copy()

    def depends_on(mut self) -> List[String]:
        return List[String]()

    def retention(mut self) -> Int:
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        # ABSENT -> the engine takes the CREATE branch, which is where we fail.
        return ResourceStatus.absent()

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(
            self._lid.copy(), VERB_CREATE, String("scripted"), RETAIN_DELETE
        )

    def create(mut self, creds: Creds) raises -> String:
        if self._raise_domain != FAULT_UNSET:
            raise fault_error(self._raise_domain, _BACKEND_MESSAGE)
        raise Error(_BACKEND_MESSAGE)

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return 1  # CONVERGE_IN_PLACE — never reached (we fail on create).

    def fault_domain(mut self, verb: String) raises -> Int:
        if self._classifier_explodes:
            raise Error("the classifier itself is broken")
        return self._declared


# The backend's own words. Deliberately worded like a CUSTOMER fault (it names
# the customer's project and a permission) while being, in every case below,
# whatever the DECLARATION says — which is the point: prose is not the input.
comptime _BACKEND_MESSAGE: String = (
    "CreateService: HTTP 403 PERMISSION_DENIED on projects/customer-proj"
)


def _apply_and_capture(var node: _FailingNode) raises -> String:
    """Drive the REAL `apply_graph` over one failing node and return the message
    it raised. The apply MUST raise — a node whose `create` raises and whose
    apply returned normally would make every assertion below vacuous, so that is
    checked rather than assumed."""
    var g = ResourceGraph()
    g.add(ErasedResource.erase(node^))
    var store = InMemoryStateStore()
    try:
        _ = apply_graph(g, Creds.none(), store)
    except e:
        return String(e)
    return String("")


def test_B1_an_unconsidered_conformer_is_ours() raises:
    """B1 — THE UNCONSIDERED CONFORMER. A conformer that has never been
    considered declares nothing, so the engine attributes its failure to US, and
    the backend's own customer-flavoured words do not change that."""
    var surfaced = _apply_and_capture(
        _FailingNode(String("svc"), FAULT_UNSET, FAULT_UNSET, False)
    )
    assert_true(
        surfaced.byte_length() > 0, String("the apply must have raised")
    )
    assert_true(is_our_responsibility(fault_domain_of_error(surfaced)))
    assert_equal(fault_domain_of_error(surfaced), FAULT_UNSET)
    # ...and the diagnosability the engine already provided is untouched: the
    # node, the verb and the backend's verbatim message all still there.
    assert_true(String("apply node 'svc'") in surfaced)
    assert_true(String("verb=create") in surfaced)
    assert_true(_BACKEND_MESSAGE in surfaced)
    # ...and NO TOKEN IS EMITTED AT ALL. Most deploy errors are
    # unclassified, so a token on the unclassified path would rewrite the front
    # of every one of them for the string `unset`. This assertion is what stops
    # a later edit from "tidying" the engine into stamping them uniformly.
    assert_false(String("[fault=") in surfaced)
    assert_equal(
        surfaced,
        String("apply node 'svc' verb=create failed: ") + _BACKEND_MESSAGE,
    )


def test_B2_a_declaring_conformer_reaches_the_engine() raises:
    """B2 — THE PER-VERB CARRIER, END TO END. The declaration has to survive the
    `ErasedResource` vtable, which is the link most likely to be dropped by a
    future edit precisely because dropping it fails SAFE and produces no other
    symptom."""
    var surfaced = _apply_and_capture(
        _FailingNode(String("svc"), FAULT_CUSTOMER, FAULT_UNSET, False)
    )
    assert_equal(fault_domain_of_error(surfaced), FAULT_CUSTOMER)
    assert_false(is_our_responsibility(fault_domain_of_error(surfaced)))
    assert_true(_BACKEND_MESSAGE in surfaced)


def test_B3_the_raise_site_outranks_the_per_verb_declaration() raises:
    """B3 — PRECEDENCE. A site that knew about THIS failure outranks a claim
    about the verb in general. The node declares CUSTOMER for every create and
    the raise says PROVIDER about this one; PROVIDER wins."""
    var surfaced = _apply_and_capture(
        _FailingNode(String("svc"), FAULT_CUSTOMER, FAULT_PROVIDER, False)
    )
    assert_equal(fault_domain_of_error(surfaced), FAULT_PROVIDER)
    # EXACTLY ONE token survives, at the front. Two would answer correctly and
    # still leave a second one mid-message for a human to misread.
    assert_true(_BACKEND_MESSAGE in surfaced)
    assert_false(String("[fault=provider] " + _BACKEND_MESSAGE) in surfaced)


def test_B4_a_broken_classifier_is_ours_and_costs_nothing() raises:
    """B4 — THE FAIL-SAFE. A classifier that raises produced no classification,
    so the answer is OURS; and critically the operator's REAL error survives
    intact. A deploy failure must never be replaced by a message about
    attribution."""
    var surfaced = _apply_and_capture(
        _FailingNode(String("svc"), FAULT_CUSTOMER, FAULT_UNSET, True)
    )
    assert_true(is_our_responsibility(fault_domain_of_error(surfaced)))
    assert_equal(fault_domain_of_error(surfaced), FAULT_UNSET)
    assert_true(_BACKEND_MESSAGE in surfaced)
    assert_true(String("apply node 'svc'") in surfaced)
    assert_false(String("the classifier itself is broken") in surfaced)


def test_B5_the_attribution_is_recoverable_many_frames_up() raises:
    """B5 — WHAT A CALLER ACTUALLY DOES. A deploy-log writer runs many
    frames above the apply; `FaultAttribution.of_error` is the whole read side,
    and it yields a record whose `reason` is the message WITHOUT our token."""
    var surfaced = _apply_and_capture(
        _FailingNode(String("svc"), FAULT_CUSTOMER, FAULT_UNSET, False)
    )
    var a = FaultAttribution.of_error(
        surfaced, String("svc"), String("create")
    )
    assert_equal(a.domain, FAULT_CUSTOMER)
    assert_false(a.is_ours())
    assert_true(a.is_classified())
    assert_true(_BACKEND_MESSAGE in a.reason)
    assert_false(String("[fault=") in a.reason)
    assert_true(String("NOT OURS") in a.operator_line())


def main() raises:
    test_unset_is_ours()
    test_unset_is_zero()
    test_a_domain_this_build_never_heard_of_is_ours()
    test_default_constructed_attribution_is_ours_and_unclassified()
    test_operator_line_says_unclassified_out_loud()
    test_wire_tokens_round_trip_and_unknown_words_are_ours()
    test_an_untagged_error_is_ours_and_byte_identical()
    test_a_stated_domain_survives_the_raise()
    test_a_malformed_token_is_ours()
    test_B1_an_unconsidered_conformer_is_ours()
    test_B2_a_declaring_conformer_reaches_the_engine()
    test_B3_the_raise_site_outranks_the_per_verb_declaration()
    test_B4_a_broken_classifier_is_ours_and_costs_nothing()
    test_B5_the_attribution_is_recoverable_many_frames_up()
    print("OK test_fault_domain_defaults_to_ours")
