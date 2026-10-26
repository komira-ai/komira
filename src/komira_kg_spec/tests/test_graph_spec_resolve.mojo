# =============================================================================
# test_graph_spec_resolve.mojo -- resolve_extract_mode never raises and never
#   resolves an invalid spec to the model mode.
# =============================================================================
#
#   valid      a valid model spec resolves to model and a valid rules spec to
#              rules, whatever the default or an injected allowing policy.
#   fail-safe  a valid model spec is changed in one way at a time (a source in
#              another scope, another owner, a looser graph, an undeclared
#              mode, a negative mode, model with no binding, an undeclared
#              trigger, an empty id, a policy that refuses the extract or the
#              synthesis endpoint); each change makes validation raise and the
#              resolution land on rules.
#   describe   the described name is the resolved mode's, "model" or "rules", so
#              it differs from the configured mode exactly when the fail-safe
#              fired.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_kg_mode import EXTRACT_MODE_MODEL, EXTRACT_MODE_RULES
from komira_kg_spec import (
    EndpointPolicy,
    ExtractConfig,
    GraphScopeRef,
    InferenceBinding,
    KnowledgeGraphSpec,
    SourceBinding,
    TriggerConfig,
    describe_resolved_mode,
    resolve_extract_mode,
    validate_graph_spec,
)


struct _Refuse(EndpointPolicy):
    var endpoint: String

    def __init__(out self, endpoint: String):
        self.endpoint = endpoint

    def allows(self, endpoint: String, graph: GraphScopeRef) -> Bool:
        return endpoint != self.endpoint


def _graph() -> GraphScopeRef:
    return GraphScopeRef.owned("s1", "owner-a")


def _valid_model_spec() -> KnowledgeGraphSpec:
    var sources = List[SourceBinding]()
    sources.append(
        SourceBinding("src-0", GraphScopeRef.owned("s1", "owner-a"), "sel")
    )
    return KnowledgeGraphSpec(
        sources^,
        ExtractConfig.model(InferenceBinding("chat", "ep-extract", "m")),
        Optional[InferenceBinding](InferenceBinding("chat", "ep-synth", "m")),
        TriggerConfig.manual(),
    )


def _assert_fails_safe(spec: KnowledgeGraphSpec, graph: GraphScopeRef) raises:
    with assert_raises():
        validate_graph_spec(spec, graph)
    assert_equal(resolve_extract_mode(spec, graph), EXTRACT_MODE_RULES)
    assert_equal(describe_resolved_mode(spec, graph), "rules")


def test_a_valid_model_spec_resolves_to_model() raises:
    var spec = _valid_model_spec()
    validate_graph_spec(spec, _graph())
    assert_equal(resolve_extract_mode(spec, _graph()), EXTRACT_MODE_MODEL)
    assert_equal(describe_resolved_mode(spec, _graph()), "model")


def test_a_valid_rules_spec_resolves_to_rules() raises:
    var spec = _valid_model_spec()
    spec.extract = ExtractConfig.rules()
    validate_graph_spec(spec, _graph())
    assert_equal(resolve_extract_mode(spec, _graph()), EXTRACT_MODE_RULES)
    assert_equal(describe_resolved_mode(spec, _graph()), "rules")


def test_an_allowing_policy_keeps_the_model_mode() raises:
    assert_equal(
        resolve_extract_mode(_valid_model_spec(), _graph(), _Refuse("other")),
        EXTRACT_MODE_MODEL,
    )
    assert_equal(
        describe_resolved_mode(_valid_model_spec(), _graph(), _Refuse("other")),
        "model",
    )


def test_a_source_in_another_scope_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.sources[0].scope = GraphScopeRef.owned("s2", "owner-a")
    _assert_fails_safe(spec, _graph())


def test_a_source_of_another_owner_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.sources[0].scope = GraphScopeRef.owned("s1", "owner-b")
    _assert_fails_safe(spec, _graph())


def test_a_graph_looser_than_its_source_fails_safe() raises:
    _assert_fails_safe(_valid_model_spec(), GraphScopeRef.shared("s1"))


def test_an_undeclared_mode_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.extract.mode = 2
    _assert_fails_safe(spec, _graph())
    spec.extract.mode = -1
    _assert_fails_safe(spec, _graph())


def test_model_with_no_binding_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.extract.inference = Optional[InferenceBinding]()
    _assert_fails_safe(spec, _graph())


def test_an_undeclared_trigger_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.trigger = TriggerConfig(42)
    _assert_fails_safe(spec, _graph())


def test_an_empty_source_id_fails_safe() raises:
    var spec = _valid_model_spec()
    spec.sources[0].source_id = String("")
    _assert_fails_safe(spec, _graph())


def test_a_refused_endpoint_fails_safe() raises:
    var spec = _valid_model_spec()
    assert_equal(
        resolve_extract_mode(spec, _graph(), _Refuse("ep-extract")),
        EXTRACT_MODE_RULES,
    )
    assert_equal(
        resolve_extract_mode(spec, _graph(), _Refuse("ep-synth")),
        EXTRACT_MODE_RULES,
    )
    assert_equal(
        describe_resolved_mode(spec, _graph(), _Refuse("ep-synth")), "rules"
    )
    with assert_raises():
        validate_graph_spec(spec, _graph(), _Refuse("ep-synth"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
