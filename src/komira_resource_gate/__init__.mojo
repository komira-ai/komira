"""komira_resource_gate: per-resource authorization in front of a dispatcher.

An application declares a `ResourceCatalog` (a pure route function, usually a
`ResourceRouteTable`) and binds an `AuthzPort`; `ResourceAuthzGate` refuses
every request the catalog does not declare, serves declared public routes
without an identity, and asks the port about every governed one.
"""

from .route_decision import (
    ROUTE_OUTCOME_DENY,
    ROUTE_OUTCOME_GOVERNED,
    ROUTE_OUTCOME_PUBLIC,
    ResourceRequirement,
    RouteDecision,
)
from .route_table import ResourceRouteTable, RouteRule, canonical_segments
from .gate import (
    AUTHZ_UNAVAILABLE_BODY,
    AUTHZ_UNAVAILABLE_RETRY_AFTER_S,
    FORBIDDEN_BODY,
    GATE_ATTRIBUTE_ACTION,
    GATE_ATTRIBUTE_RESOURCE_ID,
    GATE_ATTRIBUTE_RESOURCE_KIND,
    ResourceAuthzGate,
    ResourceCatalog,
    UNAUTHORIZED_BODY,
    authz_unavailable_response,
    forbidden_response,
    unauthorized_response,
)
