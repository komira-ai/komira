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
#                     `POST /ingest-structured` (known entities and edges), and
#                     the host's own routes. `CaptureConfig` holds the bearer
#                     token, default partition, body limit and fold threshold.
#   * routes       -- `CaptureRoutes`, the trait a host implements to add routes
#                     over the loaded working set; `NoRoutes`.
#   * clock        -- `CaptureClock`, the time source the server is given;
#                     `FixedClock`, `StepClock`.
#   * structured   -- `parse_structured_request`, `StructuredRequest`: the
#                     structured-ingest body.
#   * http_util    -- `json_response`, `error_response`, `query_value` for a host's
#                     routes; the token and label checks.
#
# Every route but health needs the bearer token; bodies are limited; the server
# reads no clock and no environment. The query routes are the next part.
# =============================================================================

from .clock import CaptureClock, FixedClock, StepClock
from .dispatcher import (
    CaptureConfig,
    CaptureDispatcher,
    ROUTE_CAPTURE,
    ROUTE_HEALTH,
    ROUTE_INGEST_STRUCTURED,
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
from .routes import CaptureRoutes, NoRoutes
from .structured import StructuredRequest, parse_structured_request
