# =============================================================================
# komira_kg_capture -- the capture server of the knowledge-graph port, core.
# =============================================================================
#
# A server over one snapshot store that takes records from a push and writes
# them to the graph, with no kind of record, service or vocabulary of its own.
#
#   * dispatcher   -- `CaptureDispatcher`, a `komira_http_server`
#                     `RequestDispatcher`: `GET /health` (open),
#                     `POST /capture?surface=<tag>` (the adapter registered
#                     under the tag lowers the record, each episode is ingested),
#                     `POST /ingest-structured` (known entities and edges),
#                     `POST /query` and `POST /query-federated`, and the host's
#                     own routes. `CaptureConfig` holds the bearer
#                     token, default partition, body limit and fold threshold.
#   * routes       -- `CaptureRoutes`, the trait a host implements to add routes
#                     over the loaded working set; `NoRoutes`.
#   * clock        -- `CaptureClock`, the time source the server is given;
#                     `FixedClock`, `StepClock`.
#   * query_config -- `QueryConfig`: the synthesis prompt (a neutral default)
#                     and the limits of the query routes.
#   * query_spec   -- `QuerySpec`, `parse_query_request`: the query body.
#   * query_build  -- `build_query_result`: the subgraph a query matches in a
#                     merged working set; one partition or several.
#   * query_synthesis -- `evidence_pack`, `synthesize_answer`: the model's
#                     answer from the subgraph.
#   * structured   -- `parse_structured_request`, `StructuredRequest`: the
#                     structured-ingest body.
#   * http_util    -- `json_response`, `error_response`, `query_value` for a host's
#                     routes; the token and label checks.
#
# Every route but health needs the bearer token; bodies are limited; the server
# reads no clock and no environment.
# =============================================================================

from .clock import CaptureClock, FixedClock, StepClock
from .dispatcher import (
    CaptureConfig,
    CaptureDispatcher,
    ROUTE_CAPTURE,
    ROUTE_HEALTH,
    ROUTE_INGEST_STRUCTURED,
    ROUTE_QUERY,
    ROUTE_QUERY_FEDERATED,
)
from .http_util import (
    LABEL_MAX_BYTES,
    bearer_matches,
    check_label,
    check_token,
    error_response,
    json_response,
    query_value,
)
from .query_build import build_query_result
from .query_config import (
    DEFAULT_SYNTHESIS_PROMPT,
    SYNTHESIS_PROMPT_MAX_BYTES,
    QueryConfig,
)
from .query_spec import QuerySpec, parse_query_request
from .query_synthesis import (
    SYNTHESIS_MAX_EDGES,
    SYNTHESIS_MAX_NODES,
    evidence_pack,
    synthesize_answer,
)
from .routes import CaptureRoutes, NoRoutes
from .structured import StructuredRequest, parse_structured_request
