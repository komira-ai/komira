# =============================================================================
# komira_kg_spec/graph_spec.mojo -- the build configuration of one knowledge
#   graph and the checks that decide whether it is well formed.
# =============================================================================
#
# A spec says which sources a graph is built from, how it is extracted (by
# typed rules, or by a model the host injects), which model answers questions
# over it, and when a build is submitted. `validate_graph_spec` is the write
# gate: it raises, with a message of its own for each defect, so a bad spec is
# refused when it is declared. `resolve_extract_mode` is the gate over a spec
# that is already stored: it never raises and never resolves to the model mode
# for a spec that does not validate, so a stale or damaged spec cannot send
# document bodies to a model.
#
# What the checks look at, and what they leave to the host:
#   * Scope containment. A graph is no wider than any source it is built from:
#     same scope id, no looser tier, and for an owner-tier source the same
#     owner. This is containment of two plain values, not authorization; who
#     may read which graph is the host's decision.
#   * Host contract for sources. `SourceBinding.scope` is a claim written in the
#     spec. Nothing in this package ties it to `source_id`: the host must check
#     each source's real scope and owner against its own records before it
#     calls `validate_graph_spec`, or a spec can name another owner's source
#     with the graph's own scope and validate. A `SourcePolicy` the host injects
#     can also refuse a source the caller may not read, and a stored spec then
#     fails safe to rules on resolve. The default allows every source.
#   * Endpoints. Whether an inference endpoint may be bound to a graph is an
#     `EndpointPolicy` the host injects. The default allows every endpoint.
#   * Opaque values. `SourceBinding.selector`, `InferenceBinding.transport`,
#     `InferenceBinding.endpoint`, `InferenceBinding.model_id` and the source id
#     are strings the host and the executor understand; nothing here parses or
#     branches on them.
#
# No pointer crosses this API, and nothing reads a clock or the environment.
# =============================================================================

from komira_kg_mode import (
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_RULES,
    KgExtractMode,
    extract_mode_name,
    is_known_extract_mode,
    normalize_extract_mode,
)


# =============================================================================
# Scope: a scope id and an optional owner id, both opaque.
# =============================================================================
comptime SCOPE_RANK_SHARED: Int = 0
"""A scope with no owner: everything in the scope id is one audience."""

comptime SCOPE_RANK_OWNER: Int = 1
"""A scope with an owner: the owner id narrows the audience to one party. Higher
is tighter."""


struct GraphScopeRef(Copyable, Movable):
    """Where a graph or a source lives, as two plain strings.

    `scope_id` is the containment boundary: a graph may only be built from
    sources in its own scope. `owner_id`, when present, narrows the scope to
    one owner. Both are chosen by the host; this type gives them no meaning
    beyond equality.
    """

    var scope_id: String
    var owner_id: Optional[String]

    def __init__(out self, var scope_id: String, var owner_id: Optional[String]):
        self.scope_id = scope_id^
        self.owner_id = owner_id^

    @staticmethod
    def shared(var scope_id: String) -> GraphScopeRef:
        """A scope with no owner."""
        return GraphScopeRef(scope_id^, Optional[String]())

    @staticmethod
    def owned(var scope_id: String, var owner_id: String) -> GraphScopeRef:
        """A scope narrowed to one owner."""
        return GraphScopeRef(scope_id^, Optional[String](owner_id^))

    def has_owner(self) -> Bool:
        return Bool(self.owner_id)


def scope_rank(scope: GraphScopeRef) -> Int:
    """The tier of a scope: `SCOPE_RANK_OWNER` when it has an owner, otherwise
    `SCOPE_RANK_SHARED`."""
    if scope.has_owner():
        return SCOPE_RANK_OWNER
    return SCOPE_RANK_SHARED


# =============================================================================
# The endpoint policy the host injects.
# =============================================================================
trait EndpointPolicy(Movable, Deinitable):
    """The host's rule for which inference endpoints a graph may bind."""

    def allows(self, endpoint: String, graph: GraphScopeRef) -> Bool:
        """True when a graph in scope `graph` may bind `endpoint`. `endpoint`
        is the opaque string of the binding, passed through unread."""
        ...


struct AllowAllEndpoints(EndpointPolicy):
    """The default policy: every endpoint is allowed."""

    def __init__(out self):
        pass

    def allows(self, endpoint: String, graph: GraphScopeRef) -> Bool:
        return True


# =============================================================================
# The spec's parts.
# =============================================================================
struct InferenceBinding(Copyable, Movable):
    """A binding to one inference endpoint.

    All three fields are opaque. `transport` is a label that selects a client in
    the executor; `endpoint` names where the model is reached (the executor
    resolves it, and the `EndpointPolicy` may refuse it); `model_id` is passed
    to the model unread. Adding a transport is never a change to the checks.
    """

    var transport: String
    var endpoint: String
    var model_id: String

    def __init__(
        out self,
        var transport: String,
        var endpoint: String,
        var model_id: String,
    ):
        self.transport = transport^
        self.endpoint = endpoint^
        self.model_id = model_id^


struct ExtractConfig(Copyable, Movable):
    """How the graph is extracted.

    `mode` is an ordinal from `komira_kg_mode`. `inference` is required when
    the mode is model; in rules mode a binding may be present and is then
    ignored by extraction, but it is still held to the endpoint policy.
    """

    var mode: Int
    var inference: Optional[InferenceBinding]

    def __init__(out self, mode: Int, var inference: Optional[InferenceBinding]):
        self.mode = mode
        self.inference = inference^

    @staticmethod
    def rules() -> ExtractConfig:
        """The default: extraction by typed rules, no model, no endpoint."""
        return ExtractConfig(EXTRACT_MODE_RULES, Optional[InferenceBinding]())

    @staticmethod
    def model(var binding: InferenceBinding) -> ExtractConfig:
        """Opt-in: a model reads raw document bodies at ingest. The binding is
        not optional here."""
        return ExtractConfig(
            EXTRACT_MODE_MODEL, Optional[InferenceBinding](binding^)
        )


struct SourceBinding(Copyable, Movable):
    """One source the graph is built from.

    `source_id` names the source; `scope` says where it lives, for the
    containment checks; `selector` says which part of it. All three are opaque
    to the checks except `scope`, which is compared field by field.

    `scope` is a claim written in the spec. Nothing in this package ties it to
    `source_id`: the host must check each source's real scope and owner against
    its own records before calling `validate_graph_spec`, or a spec can name
    another owner's source with the graph's own scope and validate. A
    `SourcePolicy` is where the host can refuse a source it knows the caller may
    not read.
    """

    var source_id: String
    var scope: GraphScopeRef
    var selector: String

    def __init__(
        out self,
        var source_id: String,
        var scope: GraphScopeRef,
        var selector: String,
    ):
        self.source_id = source_id^
        self.scope = scope^
        self.selector = selector^


# =============================================================================
# The source policy the host injects.
# =============================================================================
trait SourcePolicy(Movable, Deinitable):
    """The host's rule for which sources a graph may be built from."""

    def allows(self, source: SourceBinding, graph: GraphScopeRef) -> Bool:
        """True when a graph in scope `graph` may be built from `source`. The
        binding is passed through as written, including its claimed scope."""
        ...


struct AllowAllSources(SourcePolicy):
    """The default policy: every source is allowed."""

    def __init__(out self):
        pass

    def allows(self, source: SourceBinding, graph: GraphScopeRef) -> Bool:
        return True


comptime TRIGGER_ON_SOURCE_VERSION_CHANGE: Int = 0
"""Rebuild when a source's version token changes."""

comptime TRIGGER_SCHEDULED: Int = 1
"""Rebuild on a schedule the host keeps."""

comptime TRIGGER_MANUAL: Int = 2
"""Rebuild only when asked."""


def is_known_trigger(kind: Int) -> Bool:
    return (
        kind == TRIGGER_ON_SOURCE_VERSION_CHANGE
        or kind == TRIGGER_SCHEDULED
        or kind == TRIGGER_MANUAL
    )


struct TriggerConfig(Copyable, Movable):
    """When a build is submitted. The ordinal is stored in the spec."""

    var kind: Int

    def __init__(out self, kind: Int):
        self.kind = kind

    @staticmethod
    def on_source_version_change() -> TriggerConfig:
        return TriggerConfig(TRIGGER_ON_SOURCE_VERSION_CHANGE)

    @staticmethod
    def scheduled() -> TriggerConfig:
        return TriggerConfig(TRIGGER_SCHEDULED)

    @staticmethod
    def manual() -> TriggerConfig:
        return TriggerConfig(TRIGGER_MANUAL)


struct KnowledgeGraphSpec(Copyable, Movable):
    """The build configuration of one graph.

    `extract.inference` (the model that reads documents at build time) and
    `synthesis` (the model that answers questions over the finished graph) are
    separate bindings, so a graph can be built by rules and still answer in
    natural language; one flag for both would make that impossible.
    """

    var sources: List[SourceBinding]
    var extract: ExtractConfig
    var synthesis: Optional[InferenceBinding]
    var trigger: TriggerConfig

    def __init__(
        out self,
        var sources: List[SourceBinding],
        var extract: ExtractConfig,
        var synthesis: Optional[InferenceBinding],
        var trigger: TriggerConfig,
    ):
        self.sources = sources^
        self.extract = extract^
        self.synthesis = synthesis^
        self.trigger = trigger^

    def has_synthesis(self) -> Bool:
        """True when a synthesis binding is present, whatever the extract mode."""
        return Bool(self.synthesis)


# =============================================================================
# Validation: the write gate. Raises a message of its own for each defect.
# =============================================================================
def validate_graph_spec(
    spec: KnowledgeGraphSpec, graph: GraphScopeRef
) raises:
    """`validate_graph_spec` with the default policies, which allow every
    endpoint and every source."""
    validate_graph_spec(spec, graph, AllowAllEndpoints(), AllowAllSources())


def validate_graph_spec[
    P: EndpointPolicy
](spec: KnowledgeGraphSpec, graph: GraphScopeRef, policy: P) raises:
    """`validate_graph_spec` with an endpoint policy and the default source
    policy, which allows every source."""
    validate_graph_spec(spec, graph, policy, AllowAllSources())


def validate_graph_spec[
    P: EndpointPolicy, S: SourcePolicy
](
    spec: KnowledgeGraphSpec,
    graph: GraphScopeRef,
    policy: P,
    sources: S,
) raises:
    """Check a graph's build configuration; raise on the first defect.

    The checks, in this order:

    1. the graph's scope id and owner id, when present, are not empty;
    2. for each source: its id and scope id are not empty, its scope id is the
       graph's, the graph is no looser than it, and an owner-tier source has the
       graph's owner, and `sources` allows it;
    3. each inference binding present (extract, then synthesis) is allowed by
       `policy`;
    4. the extract mode is a declared ordinal;
    5. the model mode has an inference binding;
    6. the trigger kind is a declared ordinal.

    Host contract: `SourceBinding.scope` is a claim written in the spec, and
    nothing here ties it to `source_id`. The host must check each source's real
    scope and owner against its own records before calling this, or a spec can
    name another owner's source with the graph's own scope and validate.
    `sources` is where the host refuses a source the caller may not read.

    Nothing here parses a selector, reads a transport label or branches on a
    source id, so a new kind of source or transport needs no change.

    Args:
        spec: The configuration to check.
        graph: Where the graph lives.
        policy: Which endpoints the graph may bind.
        sources: Which sources the graph may be built from.

    Raises:
        An error naming the first defect.
    """
    if graph.scope_id.byte_length() == 0:
        raise Error("graph_spec: the graph's scope id is empty")
    if graph.has_owner() and graph.owner_id.value().byte_length() == 0:
        raise Error("graph_spec: the graph's owner id is present and empty")

    for i in range(len(spec.sources)):
        ref src = spec.sources[i]
        if src.source_id.byte_length() == 0:
            raise Error(
                String("graph_spec: source ") + String(i) + " has an empty id"
            )
        if src.scope.scope_id.byte_length() == 0:
            raise Error(
                String("graph_spec: source ")
                + String(i)
                + "'s scope id is empty"
            )
        if src.scope.has_owner() and src.scope.owner_id.value().byte_length() == 0:
            raise Error(
                String("graph_spec: source ")
                + String(i)
                + "'s owner id is present and empty"
            )
        if src.scope.scope_id != graph.scope_id:
            raise Error(
                String("graph_spec: source ")
                + String(i)
                + " is in a different scope than the graph. A graph is built"
                " only from sources in its own scope."
            )
        if scope_rank(graph) < scope_rank(src.scope):
            raise Error(
                String("graph_spec: the graph's scope is looser than source ")
                + String(i)
                + "'s. A graph over an owner's source must have an owner too,"
                " or it would publish that source's derivative to the whole"
                " scope."
            )
        if src.scope.has_owner():
            if src.scope.owner_id.value() != graph.owner_id.value():
                raise Error(
                    String("graph_spec: source ")
                    + String(i)
                    + " is owned by a different owner than the graph. Equal"
                    " tiers are not equal scopes: the graph's owner would"
                    " receive a derivative of data that was never theirs."
                )
        if not sources.allows(src, graph):
            raise Error(
                String("graph_spec: source ")
                + String(i)
                + " is refused by the source policy for this graph"
            )

    if spec.extract.inference:
        _require_endpoint_allowed(
            spec.extract.inference.value(), graph, policy, "extract"
        )
    if spec.synthesis:
        _require_endpoint_allowed(
            spec.synthesis.value(), graph, policy, "synthesis"
        )

    if not is_known_extract_mode(spec.extract.mode):
        raise Error(
            String("graph_spec: extract.mode ")
            + String(spec.extract.mode)
            + " is not a declared extract mode (the vocabulary is defined in"
            " komira_kg_mode)"
        )

    if spec.extract.mode == EXTRACT_MODE_MODEL:
        if not spec.extract.inference:
            raise Error(
                "graph_spec: extract.mode is model but no inference binding is"
                " present. Model extraction sends raw document bodies to a"
                " model, so a half-configured one is refused, not resolved."
            )

    if not is_known_trigger(spec.trigger.kind):
        raise Error(
            String("graph_spec: trigger kind ")
            + String(spec.trigger.kind)
            + " is not a declared trigger. A scheduler that does not recognize"
            " it would never rebuild the graph."
        )


def _require_endpoint_allowed[
    P: EndpointPolicy
](
    binding: InferenceBinding,
    graph: GraphScopeRef,
    policy: P,
    which: StaticString,
) raises:
    """Ask the policy about one binding; the message names which binding."""
    if not policy.allows(binding.endpoint, graph):
        raise Error(
            String("graph_spec: the ")
            + String(which)
            + " inference endpoint is refused by the endpoint policy for this"
            " graph"
        )


# =============================================================================
# Resolution: the execute gate over a stored spec. Never raises.
# =============================================================================
def resolve_extract_mode(
    spec: KnowledgeGraphSpec, graph: GraphScopeRef
) -> KgExtractMode:
    """`resolve_extract_mode` with the default policies."""
    return resolve_extract_mode(
        spec, graph, AllowAllEndpoints(), AllowAllSources()
    )


def resolve_extract_mode[
    P: EndpointPolicy
](spec: KnowledgeGraphSpec, graph: GraphScopeRef, policy: P) -> KgExtractMode:
    """`resolve_extract_mode` with an endpoint policy and the default source
    policy."""
    return resolve_extract_mode(spec, graph, policy, AllowAllSources())


def resolve_extract_mode[
    P: EndpointPolicy, S: SourcePolicy
](
    spec: KnowledgeGraphSpec,
    graph: GraphScopeRef,
    policy: P,
    sources: S,
) -> KgExtractMode:
    """The mode the spec actually runs at.

    A spec that fails `validate_graph_spec` resolves to rules, never to model,
    and this function cannot raise. It is for a spec already stored, which may
    have stopped validating since it was written (a source moved, a policy
    changed, a source the caller may no longer read, a newer writer stored an ordinal this build does not know); the
    only safe answer there is the mode that sends nothing to a model. A valid
    spec resolves to its own mode.
    """
    try:
        validate_graph_spec(spec, graph, policy, sources)
    except:
        return EXTRACT_MODE_RULES
    return normalize_extract_mode(spec.extract.mode)


def describe_resolved_mode(
    spec: KnowledgeGraphSpec, graph: GraphScopeRef
) -> String:
    """`describe_resolved_mode` with the default policies."""
    return describe_resolved_mode(
        spec, graph, AllowAllEndpoints(), AllowAllSources()
    )


def describe_resolved_mode[
    P: EndpointPolicy
](spec: KnowledgeGraphSpec, graph: GraphScopeRef, policy: P) -> String:
    """`describe_resolved_mode` with an endpoint policy and the default source
    policy."""
    return describe_resolved_mode(spec, graph, policy, AllowAllSources())


def describe_resolved_mode[
    P: EndpointPolicy, S: SourcePolicy
](
    spec: KnowledgeGraphSpec,
    graph: GraphScopeRef,
    policy: P,
    sources: S,
) -> String:
    """The canonical name of the resolved mode, for a build record that must say
    which mode ran and not which was configured. The two differ exactly when
    the fail-safe fired."""
    return String(extract_mode_name(resolve_extract_mode(spec, graph, policy, sources)))
