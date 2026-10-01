"""`kci_edge` — the provider-neutral kind-19 `API_EDGE` substrate (no cloud
coupling).

The provider-neutral half of the `RESOURCE_KIND_API_EDGE = 19` node:
  * edge_accumulators.mojo    — the two shared output->input seams:
      `BackendAddressAccumulator` (backend -> edge: the live backend URL;
      `komira_gcp_bridge` re-exports it) and `EdgeOutcomeAccumulator`
      (edge -> driver: the KEYED published-edge-URL sink the registry publish
      reads).
  * network_accumulators.mojo — `NetworkOutcomeAccumulator`, the network ->
      scoped-node seam (see below).
  * direct_edge_conformer.mojo — `DirectEdge`, the DIRECT/on-prem NO-OP
      conformer (on-prem uses NO edge resource; the published edge URL == the
      backend URL, scheme verbatim) + `make_direct_edge_node` + the neutral
      EDGE_ROUTE_MODE_* codes + the per-mode node-id helpers + `join_edge_url`.
  * transport_split.mojo      — the TRANSPORT-SPLIT planner. Given an app's
      route inventory, measures which routes a MANAGED gateway can carry and
      which need a second backend, then decides whether the split is
      EXPRESSIBLE at a given edge (can it route on the HTTP method?) and
      REACHABLE (does the exotic half have a public hop that avoids the
      `allUsers` binding `iam.allowedPolicyMemberDomains` rejects?). Pure over
      values; the per-cloud facts enter as CITED `EdgeCapability` rows, which is
      what keeps "does this survive on AWS" a question about the plan rather
      than about an import graph.
  * transport_split_render.mojo — the routing render for the clouds whose edge
      can express a method split.

The GCP conformer (`GcpApiEdge` — the gateway-trio realization) lives in
`komira_gcp_bridge` and imports THIS package for the shared seams; an on-prem
build imports THIS package alone (zero GCP deps). AWS/Azure conformers do the
same — no proto change, no change here.
"""

from kci_edge.edge_accumulators import (
    BackendAddressAccumulator,
    EdgeOutcomeAccumulator,
)

# ★ THE THIRD ACCUMULATOR SEAM — and the one that makes this
# package's real charter visible: it is the NEUTRAL HOME FOR SEAMS THAT CARRY AN
# APPLY-TIME-DISCOVERED VALUE BETWEEN GRAPH NODES, not an edge-only substrate.
# `NetworkOutcomeAccumulator` carries a kind-25 `RESOURCE_KIND_NETWORK` node's
# DISCOVERED network id (a server-assigned `vpc-…`, which no mapper can compute)
# to every node scoped to it — kind 26 `RESOURCE_KIND_INGRESS_POLICY` today.
from kci_edge.network_accumulators import NetworkOutcomeAccumulator
from kci_edge.direct_edge_conformer import (
    DirectEdge,
    make_direct_edge_node,
    EDGE_ROUTE_MODE_SINGLE_PATH,
    EDGE_ROUTE_MODE_CATCH_ALL,
    api_edge_inbound_node_id,
    api_edge_client_node_id,
    api_edge_node_id,
    join_edge_url,
    # ★ THE ONE origin-former: a bare `default_hostname` -> `https://<host>`, no
    # route, no trailing slash. The published edge URL, the registry URL a
    # caller POSTs to, and the `x-google-audiences` the gateway pins are ALL
    # formed from its output, so they cannot drift apart.
    edge_origin_from_host,
)
from kci_edge.transport_split import (
    # the transport classes + the ONE classifier
    TRANSPORT_JSON,
    TRANSPORT_EXT_METHOD,
    TRANSPORT_UPGRADE,
    TRANSPORT_BULK,
    MANAGED_GATEWAY_BODY_CAP_BYTES,
    CLOUD_RUN_HTTP1_BODY_CAP_BYTES,
    BACKEND_BODY_CAP_UNLIMITED,
    transport_class_name,
    is_standard_http_method,
    classify_transport,
    # the inventory + the measurement
    RouteFacet,
    SplitCensus,
    split_census,
    census_line,
    # the per-cloud capability rows (each carries the URL that establishes it)
    EdgeCapability,
    edge_gcp_api_gateway,
    edge_gcp_global_alb,
    edge_aws_alb,
    edge_aws_cloudfront,
    edge_azure_front_door,
    # the auth model + the decision
    VERIFIER_NONE,
    VERIFIER_APP_MIDDLEWARE,
    VERIFIER_EDGE_JWT,
    verifier_name,
    verifier_is_weaker_than,
    SplitPlan,
    SplitVerdict,
    split_verdict,
    verdict_name,
    SPLIT_PROCEED,
    SPLIT_UNNECESSARY,
    SPLIT_INEXPRESSIBLE,
    SPLIT_UNREACHABLE,
    SPLIT_UNVERIFIED_HALF,
    SPLIT_EDGE_CANNOT_CARRY,
    SPLIT_BACKEND_CAP,
    SPLIT_VERIFIER_ASYMMETRY,
)
from kci_edge.transport_split_render import (
    # the ROUTING, for the two clouds whose edge can
    # express a method split. There is deliberately no CloudFront / Azure Front
    # Door render: both lack the primitive, so a render would be config that
    # cannot be applied.
    lb_prefix_of,
    exotic_methods_of,
    exotic_prefixes_of,
    render_gcp_route_rules,
    render_aws_listener_rules,
)
