# `komira_kg_spec`

## Responsibility

The build configuration of one knowledge graph, from
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md),
and the checks that decide whether it is well formed.

A `KnowledgeGraphSpec` has:

- `sources`: `SourceBinding`s, each an opaque source id, the `GraphScopeRef` the
  source lives in, and an opaque selector.
- `extract`: an `ExtractConfig`, a mode ordinal from `komira_kg_mode` (rules, the
  default, or model) and, for model, an `InferenceBinding`.
- `synthesis`: an optional `InferenceBinding` for the model that answers
  questions over the finished graph. It is independent of the extract mode, so a
  graph built by rules can still answer in natural language.
- `trigger`: a `TriggerConfig` (rebuild when a source's version token changes,
  on a schedule the host keeps, or only when asked).

A `GraphScopeRef` is a scope id and an optional owner id, both opaque strings.
It has two tiers: shared (no owner) and owner. This is containment, not
authorization: the package never decides who may read a graph.

`validate_graph_spec` is the write gate and raises a message of its own for each
defect: an empty id, a source in another scope, a graph looser than a source, a
source of another owner, an endpoint the policy refuses (the message names the
extract or the synthesis binding), an undeclared extract mode, model mode with no
binding, an undeclared trigger. `resolve_extract_mode` is the gate over a spec
that is already stored: it never raises, and a spec that fails validation
resolves to rules, never to model.

The host decides which inference endpoints a graph may bind by implementing
`EndpointPolicy`; `AllowAllEndpoints` is the default. Whether the caller may read
a source is also the host's decision, made before it declares a spec. The
transport label, endpoint, model id, source id and selector are never parsed or
branched on here. The package reads no clock and no environment, depends on
`komira_kg_mode` only, and no pointer crosses its API.

## Examples

A graph in a scope may be built from sources in the same scope. The default
policy allows every endpoint, and a valid model spec resolves to the model mode:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg_mode import EXTRACT_MODE_MODEL
from komira_kg_spec import (
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

var sources = List[SourceBinding]()
sources.append(SourceBinding("source-1", GraphScopeRef.shared("team-a"), "any/selector"))
var spec = KnowledgeGraphSpec(
    sources^,
    ExtractConfig.model(InferenceBinding("chat", "endpoint-1", "model-1")),
    Optional[InferenceBinding](),
    TriggerConfig.manual(),
)
var graph = GraphScopeRef.shared("team-a")
validate_graph_spec(spec, graph)
assert_equal(resolve_extract_mode(spec, graph), EXTRACT_MODE_MODEL)
assert_equal(describe_resolved_mode(spec, graph), "model")
```

A graph owned by one party cannot be built from another party's source, and a
spec that fails validation runs on rules:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises
-->
```mojo
from komira_kg_mode import EXTRACT_MODE_RULES
from komira_kg_spec import (
    ExtractConfig,
    GraphScopeRef,
    InferenceBinding,
    KnowledgeGraphSpec,
    SourceBinding,
    TriggerConfig,
    resolve_extract_mode,
    validate_graph_spec,
)

var sources = List[SourceBinding]()
sources.append(SourceBinding("source-1", GraphScopeRef.owned("team-a", "owner-a"), ""))
var spec = KnowledgeGraphSpec(
    sources^,
    ExtractConfig.rules(),
    Optional[InferenceBinding](),
    TriggerConfig.manual(),
)
var graph = GraphScopeRef.owned("team-a", "owner-b")
with assert_raises(contains="owned by a different owner"):
    validate_graph_spec(spec, graph)
assert_equal(resolve_extract_mode(spec, graph), EXTRACT_MODE_RULES)
```

An endpoint policy the host injects can refuse an endpoint:

```mojo module
from std.testing import assert_raises
from komira_kg_spec import (
    EndpointPolicy,
    ExtractConfig,
    GraphScopeRef,
    InferenceBinding,
    KnowledgeGraphSpec,
    SourceBinding,
    TriggerConfig,
    validate_graph_spec,
)


struct NoEndpointOne(EndpointPolicy):
    def __init__(out self):
        pass

    def allows(self, endpoint: String, graph: GraphScopeRef) -> Bool:
        return endpoint != "endpoint-1"


def main() raises:
    var spec = KnowledgeGraphSpec(
        List[SourceBinding](),
        ExtractConfig.model(InferenceBinding("chat", "endpoint-1", "model-1")),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="refused by the endpoint policy"):
        validate_graph_spec(spec, GraphScopeRef.shared("team-a"), NoEndpointOne())
```
