# =============================================================================
# test_graph_spec_validation.mojo -- validate_graph_spec refuses each defect
#   with a message of its own and accepts a well-formed spec.
# =============================================================================
#
#   valid      a rules spec, a model spec, a spec with a synthesis binding and a
#              spec with no sources are accepted; a valid spec keeps every field
#              it was built with; a graph with an owner over shared sources is
#              accepted (tighter is allowed).
#   scope      a source in another scope id, a source of another owner, a shared
#              graph over an owner's source and an empty scope or owner id each
#              raise, and each raises its own message; the check names the index
#              of the offending source.
#   mode       an undeclared extract mode raises; model without a binding
#              raises; rules without a binding is accepted.
#   trigger    an undeclared trigger kind raises; each declared kind is accepted.
#   endpoint   the default policy allows every endpoint; an injected policy that
#              refuses raises, naming the extract or the synthesis binding; the
#              policy sees the binding's endpoint string and the graph's scope.
#   source     the default policy allows every source; an injected policy that
#              refuses a named source raises with a message of its own naming
#              that source's index and lets the others through; the policy sees
#              the binding as written and the graph's scope.
#   opaque     an arbitrary selector, transport label, model id and source id
#              give the same outcome as an ordinary one.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg_mode import EXTRACT_MODE_MODEL, EXTRACT_MODE_RULES
from komira_kg_spec import (
    SCOPE_RANK_OWNER,
    SCOPE_RANK_SHARED,
    TRIGGER_MANUAL,
    TRIGGER_ON_SOURCE_VERSION_CHANGE,
    TRIGGER_SCHEDULED,
    AllowAllEndpoints,
    AllowAllSources,
    EndpointPolicy,
    ExtractConfig,
    GraphScopeRef,
    InferenceBinding,
    KnowledgeGraphSpec,
    SourceBinding,
    SourcePolicy,
    TriggerConfig,
    is_known_trigger,
    scope_rank,
    validate_graph_spec,
)


def _binding(endpoint: String) -> InferenceBinding:
    return InferenceBinding("transport-a", endpoint, "model-a")


def _shared(scope: String) -> GraphScopeRef:
    return GraphScopeRef.shared(scope)


def _owned(scope: String, owner: String) -> GraphScopeRef:
    return GraphScopeRef.owned(scope, owner)


def _spec_over(
    var sources: List[SourceBinding],
    var extract: ExtractConfig,
    var synthesis: Optional[InferenceBinding],
    var trigger: TriggerConfig,
) -> KnowledgeGraphSpec:
    return KnowledgeGraphSpec(
        sources^, extract^, synthesis^, trigger^
    )


def _rules_spec(var source_scope: GraphScopeRef) -> KnowledgeGraphSpec:
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("src-0", source_scope^, "any/selector"))
    return _spec_over(
        sources^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )


def _model_spec() -> KnowledgeGraphSpec:
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("src-0", _shared("s1"), "sel"))
    return _spec_over(
        sources^,
        ExtractConfig.model(_binding("ep-extract")),
        Optional[InferenceBinding](_binding("ep-synth")),
        TriggerConfig.on_source_version_change(),
    )


# ---------------------------------------------------------------- valid ----


def test_a_rules_spec_is_accepted() raises:
    validate_graph_spec(_rules_spec(_shared("s1")), _shared("s1"))


def test_a_model_spec_with_both_bindings_is_accepted() raises:
    validate_graph_spec(_model_spec(), _shared("s1"))


def test_a_spec_with_no_sources_is_accepted() raises:
    var spec = _spec_over(
        List[SourceBinding](),
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    validate_graph_spec(spec, _shared("s1"))


def test_an_owner_graph_over_shared_sources_is_accepted() raises:
    validate_graph_spec(_rules_spec(_shared("s1")), _owned("s1", "owner-a"))


def test_an_owner_graph_over_its_own_owner_source_is_accepted() raises:
    validate_graph_spec(
        _rules_spec(_owned("s1", "owner-a")), _owned("s1", "owner-a")
    )


def test_a_valid_spec_keeps_every_field_it_was_built_with() raises:
    var spec = _model_spec()
    var copy = spec.copy()
    validate_graph_spec(copy, _shared("s1"))
    assert_equal(len(copy.sources), 1)
    assert_equal(copy.sources[0].source_id, "src-0")
    assert_equal(copy.sources[0].scope.scope_id, "s1")
    assert_false(copy.sources[0].scope.has_owner())
    assert_equal(copy.sources[0].selector, "sel")
    assert_equal(copy.extract.mode, EXTRACT_MODE_MODEL)
    assert_equal(copy.extract.inference.value().transport, "transport-a")
    assert_equal(copy.extract.inference.value().endpoint, "ep-extract")
    assert_equal(copy.extract.inference.value().model_id, "model-a")
    assert_true(copy.has_synthesis())
    assert_equal(copy.synthesis.value().endpoint, "ep-synth")
    assert_equal(copy.trigger.kind, TRIGGER_ON_SOURCE_VERSION_CHANGE)


def test_synthesis_is_independent_of_the_extract_mode() raises:
    var spec = _rules_spec(_shared("s1"))
    spec.synthesis = Optional[InferenceBinding](_binding("ep-synth"))
    validate_graph_spec(spec, _shared("s1"))
    assert_equal(spec.extract.mode, EXTRACT_MODE_RULES)
    assert_true(spec.has_synthesis())
    assert_false(_rules_spec(_shared("s1")).has_synthesis())


def test_scope_ranks() raises:
    assert_equal(scope_rank(_shared("s1")), SCOPE_RANK_SHARED)
    assert_equal(scope_rank(_owned("s1", "owner-a")), SCOPE_RANK_OWNER)
    assert_true(SCOPE_RANK_OWNER > SCOPE_RANK_SHARED)


# ---------------------------------------------------------------- scope ----


def test_a_source_in_another_scope_is_refused() raises:
    with assert_raises(contains="is in a different scope than the graph"):
        validate_graph_spec(_rules_spec(_shared("s2")), _shared("s1"))


def test_a_source_of_another_owner_is_refused() raises:
    with assert_raises(contains="owned by a different owner"):
        validate_graph_spec(
            _rules_spec(_owned("s1", "owner-a")), _owned("s1", "owner-b")
        )


def test_a_shared_graph_over_an_owner_source_is_refused() raises:
    with assert_raises(contains="scope is looser than source 0"):
        validate_graph_spec(
            _rules_spec(_owned("s1", "owner-a")), _shared("s1")
        )


def test_the_message_names_the_offending_source() raises:
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("a", _shared("s1"), ""))
    sources.append(SourceBinding("b", _shared("s1"), ""))
    sources.append(SourceBinding("c", _shared("other"), ""))
    var spec = _spec_over(
        sources^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="source 2 is in a different scope"):
        validate_graph_spec(spec, _shared("s1"))


def test_an_empty_graph_scope_id_is_refused() raises:
    with assert_raises(contains="the graph's scope id is empty"):
        validate_graph_spec(_rules_spec(_shared("")), _shared(""))


def test_an_empty_graph_owner_id_is_refused() raises:
    with assert_raises(contains="the graph's owner id is present and empty"):
        validate_graph_spec(_rules_spec(_shared("s1")), _owned("s1", ""))


def test_an_empty_source_id_is_refused() raises:
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("", _shared("s1"), ""))
    var spec = _spec_over(
        sources^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="source 0 has an empty id"):
        validate_graph_spec(spec, _shared("s1"))


def test_an_empty_source_scope_id_is_refused() raises:
    with assert_raises(contains="source 0's scope id is empty"):
        validate_graph_spec(_rules_spec(_shared("")), _shared("s1"))


def test_an_empty_source_owner_id_is_refused() raises:
    with assert_raises(contains="source 0's owner id is present and empty"):
        validate_graph_spec(
            _rules_spec(_owned("s1", "")), _owned("s1", "owner-a")
        )


# ----------------------------------------------------------------- mode ----


def test_an_undeclared_extract_mode_is_refused() raises:
    var spec = _rules_spec(_shared("s1"))
    spec.extract.mode = 7
    with assert_raises(contains="extract.mode 7 is not a declared"):
        validate_graph_spec(spec, _shared("s1"))
    spec.extract.mode = -1
    with assert_raises(contains="extract.mode -1 is not a declared"):
        validate_graph_spec(spec, _shared("s1"))


def test_model_mode_without_a_binding_is_refused() raises:
    var spec = _rules_spec(_shared("s1"))
    spec.extract.mode = EXTRACT_MODE_MODEL
    with assert_raises(contains="extract.mode is model but no inference"):
        validate_graph_spec(spec, _shared("s1"))


def test_model_mode_with_a_binding_and_rules_without_one_are_accepted() raises:
    validate_graph_spec(_model_spec(), _shared("s1"))
    validate_graph_spec(_rules_spec(_shared("s1")), _shared("s1"))


# -------------------------------------------------------------- trigger ----


def test_an_undeclared_trigger_is_refused() raises:
    var spec = _rules_spec(_shared("s1"))
    spec.trigger = TriggerConfig(9)
    with assert_raises(contains="trigger kind 9 is not a declared trigger"):
        validate_graph_spec(spec, _shared("s1"))
    spec.trigger = TriggerConfig(-1)
    with assert_raises(contains="trigger kind -1 is not a declared trigger"):
        validate_graph_spec(spec, _shared("s1"))


def test_each_declared_trigger_is_accepted() raises:
    for kind in [
        TRIGGER_ON_SOURCE_VERSION_CHANGE,
        TRIGGER_SCHEDULED,
        TRIGGER_MANUAL,
    ]:
        var spec = _rules_spec(_shared("s1"))
        spec.trigger = TriggerConfig(kind)
        assert_true(is_known_trigger(kind))
        validate_graph_spec(spec, _shared("s1"))
    assert_false(is_known_trigger(3))
    assert_equal(TriggerConfig.scheduled().kind, TRIGGER_SCHEDULED)


# ------------------------------------------------------------- endpoint ----


struct _RefuseEndpoint(EndpointPolicy):
    """Refuses one endpoint string, for any graph in `only_scope` (or for every
    graph when `only_scope` is empty)."""

    var endpoint: String
    var only_scope: String

    def __init__(out self, endpoint: String, only_scope: String = ""):
        self.endpoint = endpoint
        self.only_scope = only_scope

    def allows(self, endpoint: String, graph: GraphScopeRef) -> Bool:
        if endpoint != self.endpoint:
            return True
        if self.only_scope.byte_length() > 0 and graph.scope_id != self.only_scope:
            return True
        return False


def test_the_default_policy_allows_every_endpoint() raises:
    assert_true(AllowAllEndpoints().allows("anything at all", _shared("s1")))
    assert_true(AllowAllEndpoints().allows("", _owned("s1", "owner-a")))
    validate_graph_spec(_model_spec(), _shared("s1"))
    validate_graph_spec(_model_spec(), _shared("s1"), AllowAllEndpoints())


def test_an_injected_policy_that_refuses_the_extract_endpoint_raises() raises:
    with assert_raises(
        contains="the extract inference endpoint is refused by the endpoint policy"
    ):
        validate_graph_spec(
            _model_spec(), _shared("s1"), _RefuseEndpoint("ep-extract")
        )


def test_an_injected_policy_that_refuses_the_synthesis_endpoint_raises() raises:
    with assert_raises(
        contains="the synthesis inference endpoint is refused by the endpoint policy"
    ):
        validate_graph_spec(
            _model_spec(), _shared("s1"), _RefuseEndpoint("ep-synth")
        )


def test_a_policy_that_refuses_nothing_in_the_spec_accepts() raises:
    validate_graph_spec(
        _model_spec(), _shared("s1"), _RefuseEndpoint("some-other-endpoint")
    )


def test_the_policy_is_given_the_graphs_scope() raises:
    # The policy refuses ep-extract only for graphs in scope s9.
    var refuse_in_s9 = _RefuseEndpoint("ep-extract", "s9")
    validate_graph_spec(_model_spec(), _shared("s1"), refuse_in_s9)
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("src-0", _shared("s9"), ""))
    var spec = _spec_over(
        sources^,
        ExtractConfig.model(_binding("ep-extract")),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="the extract inference endpoint is refused"):
        validate_graph_spec(spec, _shared("s9"), refuse_in_s9)


def test_a_binding_in_rules_mode_is_still_held_to_the_policy() raises:
    var spec = _rules_spec(_shared("s1"))
    spec.extract.inference = Optional[InferenceBinding](_binding("ep-extract"))
    validate_graph_spec(spec, _shared("s1"))
    with assert_raises(contains="the extract inference endpoint is refused"):
        validate_graph_spec(spec, _shared("s1"), _RefuseEndpoint("ep-extract"))


# --------------------------------------------------------------- source ----


struct _RefuseSource(SourcePolicy):
    """Refuses the source with one id, for every graph."""

    var source_id: String

    def __init__(out self, source_id: String):
        self.source_id = source_id

    def allows(self, source: SourceBinding, graph: GraphScopeRef) -> Bool:
        return source.source_id != self.source_id


struct _RefuseSourceInScope(SourcePolicy):
    """Refuses every source when the graph is in one scope, and every source
    that claims one scope when it is not."""

    var graph_scope: String
    var claimed_scope: String

    def __init__(out self, graph_scope: String, claimed_scope: String):
        self.graph_scope = graph_scope
        self.claimed_scope = claimed_scope

    def allows(self, source: SourceBinding, graph: GraphScopeRef) -> Bool:
        if graph.scope_id == self.graph_scope:
            return False
        return source.scope.scope_id != self.claimed_scope


def _two_source_spec() -> KnowledgeGraphSpec:
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("src-0", _shared("s1"), ""))
    sources.append(SourceBinding("src-1", _shared("s1"), ""))
    return _spec_over(
        sources^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )


def test_the_default_policy_allows_every_source() raises:
    var src = SourceBinding("anything", _owned("s1", "owner-a"), "")
    assert_true(AllowAllSources().allows(src, _shared("s9")))
    validate_graph_spec(_two_source_spec(), _shared("s1"))
    validate_graph_spec(
        _two_source_spec(), _shared("s1"), AllowAllEndpoints(), AllowAllSources()
    )


def test_an_injected_policy_that_refuses_a_named_source_raises() raises:
    with assert_raises(
        contains="source 1 is refused by the source policy for this graph"
    ):
        validate_graph_spec(
            _two_source_spec(),
            _shared("s1"),
            AllowAllEndpoints(),
            _RefuseSource("src-1"),
        )


def test_a_source_policy_that_refuses_no_listed_source_accepts() raises:
    validate_graph_spec(
        _two_source_spec(),
        _shared("s1"),
        AllowAllEndpoints(),
        _RefuseSource("not-listed"),
    )


def test_the_source_policy_sees_the_binding_and_the_graph_scope() raises:
    # Refuses graphs in s9; and sources claiming scope s1 in any other graph.
    var policy = _RefuseSourceInScope("s9", "s1")
    with assert_raises(contains="refused by the source policy"):
        validate_graph_spec(
            _two_source_spec(), _shared("s1"), AllowAllEndpoints(), policy
        )
    var sources = List[SourceBinding]()
    sources.append(SourceBinding("src-0", _shared("s9"), ""))
    var spec = _spec_over(
        sources^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="refused by the source policy"):
        validate_graph_spec(spec, _shared("s9"), AllowAllEndpoints(), policy)
    var other = List[SourceBinding]()
    other.append(SourceBinding("src-0", _shared("s2"), ""))
    var ok = _spec_over(
        other^,
        ExtractConfig.rules(),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    validate_graph_spec(ok, _shared("s2"), AllowAllEndpoints(), policy)


def test_a_scope_defect_is_reported_before_the_source_policy() raises:
    with assert_raises(contains="different scope"):
        validate_graph_spec(
            _two_source_spec(),
            _shared("s2"),
            AllowAllEndpoints(),
            _RefuseSource("src-0"),
        )


# --------------------------------------------------------------- opaque ----


def test_opaque_strings_do_not_change_the_outcome() raises:
    var sources = List[SourceBinding]()
    sources.append(
        SourceBinding(
            "\x01 é source / kind: never-declared",
            _shared("s1"),
            "{[not a selector\n ]} ../../",
        )
    )
    var spec = _spec_over(
        sources^,
        ExtractConfig.model(
            InferenceBinding("a transport nobody has", "::???::", "m")
        ),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    validate_graph_spec(spec, _shared("s1"))
    # The same spec with an ordinary scope defect fails exactly as an ordinary
    # one does.
    with assert_raises(contains="different scope"):
        validate_graph_spec(spec, _shared("s2"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
