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
a source is also the host's decision, made before it declares a spec.

Host contract: `SourceBinding.scope` is a claim written in the spec. Nothing in
this package ties it to `source_id`. The host must check each source's real
scope and owner against its own records before calling `validate_graph_spec`;
otherwise a spec can name another owner's source with the graph's own scope and
validate. A `SourcePolicy` the host injects (`AllowAllSources` is the default)
is where it refuses a source it knows the caller may not read; a stored spec
that names such a source then fails safe to rules on `resolve_extract_mode`. The
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
    ExtractConfig.model(InferenceBinding("transport-a", "endpoint-1", "model-1")),
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
        ExtractConfig.model(InferenceBinding("transport-a", "endpoint-1", "model-1")),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    with assert_raises(contains="refused by the endpoint policy"):
        validate_graph_spec(spec, GraphScopeRef.shared("team-a"), NoEndpointOne())
```

A source policy the host injects can refuse a source it knows the caller may not
read, and the stored spec then resolves to rules:

```mojo module
from std.testing import assert_equal, assert_raises
from komira_kg_mode import EXTRACT_MODE_RULES
from komira_kg_spec import (
    AllowAllEndpoints,
    ExtractConfig,
    GraphScopeRef,
    InferenceBinding,
    KnowledgeGraphSpec,
    SourceBinding,
    SourcePolicy,
    TriggerConfig,
    resolve_extract_mode,
    validate_graph_spec,
)


struct NoSourceOne(SourcePolicy):
    def __init__(out self):
        pass

    def allows(self, source: SourceBinding, graph: GraphScopeRef) -> Bool:
        # A real host looks the source up in its own records here.
        return source.source_id != "source-1"


def main() raises:
    var sources = List[SourceBinding]()
    sources.append(
        SourceBinding("source-1", GraphScopeRef.shared("team-a"), "")
    )
    var spec = KnowledgeGraphSpec(
        sources^,
        ExtractConfig.model(InferenceBinding("transport-a", "endpoint-1", "model-1")),
        Optional[InferenceBinding](),
        TriggerConfig.manual(),
    )
    var graph = GraphScopeRef.shared("team-a")
    with assert_raises(contains="refused by the source policy"):
        validate_graph_spec(spec, graph, AllowAllEndpoints(), NoSourceOne())
    assert_equal(
        resolve_extract_mode(spec, graph, AllowAllEndpoints(), NoSourceOne()),
        EXTRACT_MODE_RULES,
    )
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_kg_spec`, version 0.1.0
(`mopm.toml`). The library is `src/komira_kg_spec/` (`graph_spec.mojo`, and the `__init__.mojo` that re-exports it),
its tests are `tests/` (`test_graph_spec_resolve.mojo`, `test_graph_spec_validation.mojo`). It depends on one
package, `komira_kg_mode`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_kg_mode",
version = "0.1" }`), so the `.conda` of this package records `mojo-komira_kg_mode >=0.1,<0.2` as a dependency and
holds none of that package's files: installing `komira_kg_spec` installs `komira_kg_mode` with it. The package has no
native archive and calls no foreign function. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependency, as `mopm lock` writes them (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_kg_mode`, and exists only once the tests of `tests/` have
passed. After any change to a source, a test, a manifest of this package or of the sibling, run `buildrules mojo sync`
with both packages staged, commit what it writes, and build `komira//src/komira_kg_spec:lib` on the farm. A test file
that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_kg_spec-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`), which
therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job
that takes that file, not a build action.

`:komira_kg_spec` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted target
of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It
also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
