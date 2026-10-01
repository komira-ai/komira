# =============================================================================
# kci_edge/direct_edge_conformer.mojo — `DirectEdge`, the DIRECT/on-prem
#   NO-OP conformer for the kind-19 `API_EDGE` node.
# =============================================================================
#
# DESIGN RULE: on-prem uses NO API gateway — no edge resource at all. The
#   `API_EDGE` node may realize as ZERO resources on a target: on `K8S` /
#   `LOCAL_COMPOSE` this conformer creates NOTHING — no gateway, no ingress
#   controller, no proxy. Its SOLE obligation is the node's OUTPUT CONTRACT: the
#   published edge URL simply EQUALS the backend service's own URL, scheme
#   preserved VERBATIM (may be `http://localhost:<p>`, may be cluster-internal —
#   the contract promises resolvability, not public TLS). Registry + URL
#   discovery behave identically on every target; consumers read the
#   descriptor, never branch on platform.
#
# WHY THE NO-OP IS SAFE. The edge is a REACHABILITY BRIDGE, not a security
#   boundary: the app's middleware is the sole authorizer on EVERY target. The
#   GCP gateway exists to satisfy a GCP-specific org-policy IAM constraint;
#   on-prem there is no such plane to bridge, so removing the hop removes only
#   the artifact that existed to satisfy GCP IAM. DIRECT, the client
#   `Authorization` header arrives unmangled (no rewrite).
#
# THE VERB CONTRACT (normative):
#   * read_status — PURE, no I/O: MATCHED iff the backend URL is resolvable via
#     the shared `BackendAddressAccumulator`; ABSENT otherwise. No drift is
#     possible. (When resolvable it ALSO re-records the published URL into the
#     outcome sink — an in-process write, not I/O; this closes the
#     fresh-first-apply window where `create` ran before the backend node's
#     read_status had recorded the URL: the converge poll's re-read publishes
#     it. The GCP serverless-compute conformer's read_status records into its
#     accumulator the same way.)
#   * create — records the backend URL (scheme verbatim; joined with
#     `route_path` under SINGLE_PATH — the published shape) into the
#     outcome accumulator; returns it as the physical id. THIS IS THE ENTIRE
#     REALIZATION. In the fresh-first-deploy window (backend not yet serving a
#     URL) it records nothing and returns the logical id as a stable
#     placeholder physical id — the converge poll's read_status re-record
#     publishes the URL once the backend converges.
#   * update — no-op converge (re-records when resolvable). delete — no-op.
#   * converge_mode = CONVERGE_IN_PLACE; retention = RETAIN_DELETE.
#
# PATH FIDELITY: trivially true — there is no hop.
# VERB SURFACE: DIRECT forwards every HTTP method — more than the minimum.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Value-typed surface; erased into ONE `ErasedResource` at the graph door. ZERO
# UnsafePointer; no wildcard origin; no byte-slab.
# =============================================================================

from kci_iac.erased_resource import ErasedResource
from kci_iac.resource import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    RETAIN_DELETE,
    CONVERGE_IN_PLACE,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)

from kci_edge.edge_accumulators import (
    BackendAddressAccumulator,
    EdgeOutcomeAccumulator,
)


# =============================================================================
# 1 — the NEUTRAL route-mode codes (they mirror the deploy manifest's
#     `RouteMode` ordinals, so the translation preserves values).
# =============================================================================
comptime EDGE_ROUTE_MODE_SINGLE_PATH: Int = 1
"""ONE route at `route_path` (webhook inbound). The published URL is the JOINED
URL including `route_path` (consumers never append or derive)."""
comptime EDGE_ROUTE_MODE_CATCH_ALL: Int = 2
"""All paths, the minimum HTTP method set, forwarded verbatim. The published
URL is the bare base `scheme://host`."""


# =============================================================================
# 2 — the PER-MODE node logical ids: naming is per-mode so a webhook inbound
#     edge and a client edge COEXIST on one backend without collision.
# =============================================================================
def api_edge_inbound_node_id(backend_name: String) -> String:
    """The SINGLE_PATH edge node's logical id: `<backend>-inbound-edge`."""
    return backend_name + String("-inbound-edge")


def api_edge_client_node_id(backend_name: String) -> String:
    """The CATCH_ALL edge node's logical id: `<backend>-client-edge`."""
    return backend_name + String("-client-edge")


def api_edge_node_id(backend_name: String, route_mode: Int) -> String:
    """The per-mode edge node logical id: SINGLE_PATH ->
    `<backend>-inbound-edge`; CATCH_ALL -> `<backend>-client-edge`."""
    if route_mode == EDGE_ROUTE_MODE_SINGLE_PATH:
        return api_edge_inbound_node_id(backend_name)
    return api_edge_client_node_id(backend_name)


def edge_origin_from_host(hostname: String) -> String:
    """★ THE ONE PLACE a bare edge hostname becomes an ORIGIN — scheme +
    authority, NO route, NO trailing slash.

    ⛔ WHY THIS IS ONE FUNCTION AND NOT THREE COPIES. This value is used for TWO
    things that must agree BYTE FOR BYTE or requests are refused with no
    explanation:

      1. it is the base of the published edge URL a deployer records in a
         registry, which a caller POSTs to VERBATIM, and
      2. it is the `aud` that caller mints (it takes the ORIGIN of that same
         URL), which is ALSO the `x-google-audiences` the gateway's own
         ApiConfig pins.

    `aud` is compared as a WHOLE STRING. A trailing slash, an added scheme, a
    lower-cased host — any of them makes (1) and (2) two different audiences, the
    edge answers 401, and a 401 from ESPv2 carries no body saying why. Three
    sites forming this string independently is three chances to drift; one
    function is zero. See `GcpApiEdge` for how the SAME observed hostname feeds
    both the render and the published URL.

    EMPTY IN, EMPTY OUT — and an empty origin means "no public front door has
    been observed yet", NEVER "use something else". Every caller must branch on
    it rather than substitute a plausible-looking default; that substitution is
    exactly the failure this function exists to prevent.

    Accepts either a bare host (the live `Gateway.default_hostname` shape — no
    scheme) or an already-scheme'd host (idempotent)."""
    if hostname.byte_length() == 0:
        return String("")
    var base = (
        hostname.copy() if (String("://") in hostname)
        else (String("https://") + hostname)
    )
    while base.endswith(String("/")):
        # 1.0.0: `base = String(base[...])` ALIASES -- the initializer reads
        # `base` while the assignment constructs into it. Bind the trimmed value
        # first, then transfer. Same program, no extra copy.
        var trimmed = String(base[byte = 0 : base.byte_length() - 1])
        base = trimmed^
    return base^


def join_edge_url(base: String, route_path: String) -> String:
    """Join a base URL and a route path into the published shape: the
    scheme/host pass through VERBATIM (never rewritten — the DIRECT contract
    preserves `http://localhost:<port>` exactly); a trailing `/` on the base and
    a missing leading `/` on the path are normalized to exactly one separator.
    An empty `route_path` returns the base verbatim."""
    if route_path.byte_length() == 0:
        return base.copy()
    var b = base.copy()
    while b.byte_length() > 0 and b.endswith(String("/")):
        # 1.0.0 aliasing: bind the trimmed value, then transfer (see above).
        var trimmed = String(b[byte = 0 : b.byte_length() - 1])
        b = trimmed^
    if route_path.startswith(String("/")):
        return b + route_path
    return b + String("/") + route_path


# =============================================================================
# 3 — DirectEdge — the ZERO-resource conformer.
# =============================================================================
struct DirectEdge(Resource, Movable, Deinitable):
    """The DIRECT/on-prem conformer for the kind-19 `API_EDGE` node: ZERO cloud
    resources; the published edge URL EQUALS the backend's own URL (joined with
    `route_path` under SINGLE_PATH), scheme preserved verbatim. See the module
    header for the full verb contract. Flat value fields +
    the two shared ArcPointer accumulators; no wildcard origin, no byte-slab."""

    # The per-mode node logical id (`<backend>-{inbound,client}-edge`).
    var _logical_id: String
    # The route mode (EDGE_ROUTE_MODE_*) — selects the published shape.
    var _route_mode: Int
    # The SINGLE_PATH route path (empty under CATCH_ALL — the mapper validates).
    var _route_path: String
    # INPUT: the backend's LIVE serving URL (the backend node records it).
    var _backend_addr: BackendAddressAccumulator
    # OUTPUT: the published-edge-URL sink the driver reads post-apply.
    var _acc: EdgeOutcomeAccumulator
    # The graph IN-edges (= [backend logical id], ORDERING-only).
    var _deps: List[String]

    def __init__(
        out self,
        logical_id: String,
        route_mode: Int,
        route_path: String,
        var backend_addr: BackendAddressAccumulator,
        var acc: EdgeOutcomeAccumulator,
        var deps: List[String],
    ):
        self._logical_id = logical_id.copy()
        self._route_mode = route_mode
        self._route_path = route_path.copy()
        self._backend_addr = backend_addr^
        self._acc = acc^
        self._deps = deps^

    def _published_url(self) -> String:
        """The published URL: the backend's own URL verbatim (CATCH_ALL)
        or joined with `route_path` (SINGLE_PATH). Empty while the backend has
        not converged a URL (the fresh-first-deploy window)."""
        var base = self._published_origin()
        if base.byte_length() == 0:
            return String("")
        if self._route_mode == EDGE_ROUTE_MODE_SINGLE_PATH:
            return join_edge_url(base, self._route_path)
        return base^

    def _published_origin(self) -> String:
        """The BASE the published url is built on — for a DIRECT edge the edge URL
        IS the backend URL, so the origin is the backend address verbatim
        (`http://localhost:8080` on LOCAL_COMPOSE — the scheme and port pass
        through UNREWRITTEN, which is the DIRECT contract). Empty in the
        fresh-first-deploy window, which is what the accumulator's `origin_for`
        contract means by empty."""
        return self._backend_addr.address()

    # =========================================================================
    # the neutral Resource surface.
    # =========================================================================
    def logical_id(mut self) -> String:
        return self._logical_id.copy()

    def depends_on(mut self) -> List[String]:
        """The IN-edges — the backend node (ORDERING-only; the backend's
        read_status records the URL this conformer publishes)."""
        return self._deps.copy()

    def retention(mut self) -> Int:
        """RETAIN_DELETE — there is nothing to retain; a recreated edge
        re-publishes at the next deploy (the registry is the URL's single source
        of truth)."""
        return RETAIN_DELETE

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        """PURE, no I/O: MATCHED iff the backend URL is resolvable via
        the shared accumulator (physical id + live digest = the published URL);
        ABSENT otherwise. NO DRIFT IS POSSIBLE. When resolvable, ALSO re-record
        the published URL into the outcome sink (an in-process write — the
        converge-poll re-read is what publishes the URL after a genuinely fresh
        first apply; see the module header)."""
        var url = self._published_url()
        if url.byte_length() == 0:
            return ResourceStatus.absent()
        self._acc.record_url(self._logical_id, url, self._published_origin())
        return ResourceStatus.matched(url, url)

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        """A PURE diff: ABSENT -> VERB_CREATE (record-the-URL is the entire
        realization); MATCHED -> VERB_NOOP. DRIFTED is unreachable (read_status
        never returns it) — mapped defensively to VERB_UPDATE (a no-op)."""
        if live.is_absent():
            return ChangeAction(
                self._logical_id.copy(),
                VERB_CREATE,
                String("absent -> publish edge URL (= backend URL; no resource)"),
                RETAIN_DELETE,
            )
        if live.is_matched():
            return ChangeAction(
                self._logical_id.copy(),
                VERB_NOOP,
                String("backend URL resolvable -> noop (no drift possible)"),
                RETAIN_DELETE,
            )
        return ChangeAction(
            self._logical_id.copy(),
            VERB_UPDATE,
            String("unreachable drifted -> no-op converge"),
            RETAIN_DELETE,
        )

    def create(mut self, creds: Creds) raises -> String:
        """Record the published URL (THE ENTIRE REALIZATION) and return
        it as the physical id. Fresh-first-deploy window (backend URL not yet
        converged): record nothing, return the logical id as a stable
        placeholder physical id — the converge poll's read_status re-record
        publishes the URL once the backend converges."""
        var url = self._published_url()
        if url.byte_length() == 0:
            return self._logical_id.copy()
        self._acc.record_url(self._logical_id, url, self._published_origin())
        return url^

    def update(mut self, creds: Creds) raises:
        """No-op converge — re-record the published URL when resolvable
        (idempotent; nothing to mutate on the target)."""
        var url = self._published_url()
        if url.byte_length() > 0:
            self._acc.record_url(
                self._logical_id, url, self._published_origin()
            )

    def delete(mut self, physical_id: String, creds: Creds) raises:
        """No-op — there is no resource to tear down. The registry row is the
        driver's concern (the registry is the URL's single source of truth)."""
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        """CONVERGE_IN_PLACE."""
        return CONVERGE_IN_PLACE


# =============================================================================
# 4 — the construction seam (the make_*_node mapper hook; erased early).
# =============================================================================
def make_direct_edge_node(
    logical_id: String,
    route_mode: Int,
    route_path: String,
    var backend_addr: BackendAddressAccumulator,
    var acc: EdgeOutcomeAccumulator,
    var deps: List[String],
) raises -> ErasedResource:
    """Construct the DIRECT/on-prem `API_EDGE` node (ZERO resources — the
    output contract only), erased. The mapper's kind-19 arm dispatches
    `K8S` / `LOCAL_COMPOSE` here (every provider has an arm); the
    conformer publishes edge URL == backend URL (scheme verbatim; joined with
    `route_path` under SINGLE_PATH) into `acc` and touches NO cloud seam."""
    return ErasedResource.erase(
        DirectEdge(logical_id, route_mode, route_path, backend_addr^, acc^, deps^)
    )
