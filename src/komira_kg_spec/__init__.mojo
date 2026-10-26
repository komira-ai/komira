# =============================================================================
# komira_kg_spec -- the knowledge graph's build configuration and the checks
#   that decide whether it is well formed.
# =============================================================================
#
# The spec value (sources, extract config, synthesis binding, trigger), its
# scope reference, its validation and the fail-safe resolution of its extract
# mode. Endpoint and source policies are injected by the host; authorization is not decided
# here. Depends on `komira_kg_mode` only.
# =============================================================================

from .graph_spec import (
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
    describe_resolved_mode,
    is_known_trigger,
    resolve_extract_mode,
    scope_rank,
    validate_graph_spec,
)
