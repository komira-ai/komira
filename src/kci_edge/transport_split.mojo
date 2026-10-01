# =============================================================================
# kci_edge/transport_split.mojo — the TRANSPORT SPLIT planner.
#
#   Given an app's declared route inventory, decide which routes the MANAGED
#   gateway can carry and which need a second backend, then answer the two
#   questions that decide whether the split is worth doing:
#     (1) EXPRESSIBILITY — can the edge in front actually SEPARATE the two
#         halves? (a path-only edge cannot, when the halves share a path.)
#     (2) REACHABILITY   — is there a public hop for the second half that does
#         not require the `allUsers` binding the org policy blocks?
#
#   A PLANNER, NOT A DEPLOYER. Every function here is pure over values; nothing
#   in this file touches a cloud, a socket, or a clock. That is deliberate: the
#   split has to be decidable BEFORE anyone provisions the second backend,
#   because the cost of discovering it is inexpressible is two live services.
# =============================================================================
#
# ★ WHY THIS LIVES IN `kci_edge`. This package is the NEUTRAL kind-19
#   substrate — its only dep is `kci_iac` and it holds ZERO cloud vocabulary.
#   A managed app must deploy into the CUSTOMER's cloud (GCP, AWS or Azure);
#   putting the split planner anywhere with
#   a GCP dep would make "does this survive on AWS" a question about an import
#   graph rather than about the plan. Here it is structurally cloud-free: the
#   per-cloud facts enter as VALUES (`EdgeCapability`), one row per edge product,
#   each carrying the doc URL that establishes it.
#
# ⚠ WHAT THIS FILE DOES NOT DO, AND WHY. It does not render a url-map, an ALB
#   listener rule or a Front Door route. Those renders already exist (or would be
#   one adapter each) and rendering them first would hide the decision: for
#   many apps the split is REFUSED before any render, and a renderer that
#   emitted config for a refused plan would be config that cannot be
#   deployed. `split_verdict` is therefore the product, and the render is
#   downstream of a PROCEED.
#
# ENCAPSULATION: every type here is a flat value POD over `String` / `List` /
#   `Int` / `Bool`. NO UnsafePointer in any signature, NO wildcard origins, NO
#   byte-slab, no FFI.
# =============================================================================


# =============================================================================
# 1 — TRANSPORT CLASSES. What about a route makes it hard to carry.
# =============================================================================
#
# The four classes are not a taste judgement; each names a DIFFERENT documented
# reason a managed gateway declines the route, and they are ordered by how much
# of the stack has to change to serve them.

comptime TRANSPORT_JSON: Int = 1
"""A standard-verb request/response inside the managed body cap. The half the
managed gateway carries today, unchanged."""

comptime TRANSPORT_EXT_METHOD: Int = 2
"""An HTTP EXTENSION verb (PROPFIND / REPORT / MKCALENDAR / MKCOL / PROPPATCH /
COPY / MOVE / LOCK / UNLOCK). Declines for a CONFIG-LANGUAGE reason, not a
runtime one: the managed gateway is OpenAPI-configured and OpenAPI 2.0/3.0's
Path Item Object has a FIXED method list, so the verb has no spelling in the
document. The proxy underneath (ESPv2 -> Envoy) would forward it fine."""

comptime TRANSPORT_UPGRADE: Int = 3
"""A protocol UPGRADE (WebSocket). Declines for a RUNTIME reason: the managed
wrapper states `Streaming is not supported`. ESPv2 itself lists web sockets as
supported, so this is the wrapper, not the proxy."""

comptime TRANSPORT_BULK: Int = 4
"""A standard verb whose body or response exceeds the managed cap. Declines for
a SIZE reason. Distinct from EXT_METHOD because the fix is different: a bulk
route can often be moved OFF the request path entirely (a signed URL), where an
extension verb cannot."""


comptime MANAGED_GATEWAY_BODY_CAP_BYTES: Int = 32 * 1024 * 1024
"""32 MB — the managed API Gateway's per-request AND per-response cap.
https://docs.cloud.google.com/api-gateway/docs/quotas (the same page states
"Streaming is not supported", which is the TRANSPORT_UPGRADE decline).

★★ THIS CAP AND `CLOUD_RUN_HTTP1_BODY_CAP_BYTES` BELOW LOOK EQUAL AND ARE NOT,
AND THE ASYMMETRY DECIDES WHETHER A BULK ROUTE CAN BE SERVED AT ALL.

Both constants are `32 * 1024 * 1024`, so a planner that compares them finds no
delta. But Cloud Run's RESPONSE row carries an escape clause this one does not:

  Cloud Run   — "Maximum HTTP/1 response size: 32 MiB IF NOT USING
                 `Transfer-Encoding: chunked` or streaming mechanisms."
  API Gateway — 32 MB per response, and "Streaming is not supported." No clause.

A backend that emits a large response chunked (for example a git server's
`fetch` pack reply or an LFS `download`) lifts the RESPONSE ceiling on a DIRECT
Cloud Run binding — without it, a repo whose pack exceeded 32 MiB could not be
cloned at all. **Routing those same routes through the managed edge re-closes
it.** Those are exactly the routes an app's inventory marks TRANSPORT_BULK.

⇒ A `TRANSPORT_BULK` decline is NOT symmetric between the two directions. On the
REQUEST axis the backend caps identically and a split is a no-op (the reasoning
under `CLOUD_RUN_HTTP1_BODY_CAP_BYTES` stands, unchanged). On the RESPONSE axis a
split to a DIRECT Cloud Run backend is a REAL lift, because that backend can
chunk and the edge cannot. If `split_verdict` is ever taught to reason
per-direction, this is the fact it needs."""

comptime CLOUD_RUN_HTTP1_BODY_CAP_BYTES: Int = 32 * 1024 * 1024
"""⚠ 32 MiB — CLOUD RUN'S OWN HTTP/1 request cap, unlimited only over HTTP/2
(https://docs.cloud.google.com/run/quotas).

★ THIS IS WHY A BULK SPLIT CAN BE A NO-OP. The obvious reading of the 32 MB
gateway cap is "move the big routes off the gateway and they fit". They do not:
the SECOND backend is also Cloud Run, and over HTTP/1 it caps at the same
32 MiB. Moving a 512 MiB git push to a second Cloud Run service behind a
load balancer changes which component answers 413, not whether one does. The
constraint is the BACKEND's, and an edge-only capability model cannot see it —
which is exactly the shape of wrong answer this planner exists to prevent, so
`SplitPlan` carries the backend cap and `split_verdict` refuses on it.

Use `BACKEND_BODY_CAP_UNLIMITED` for a backend with no request-body ceiling (an
h2 Cloud Run hop, an ECS/Fargate task behind an ALB, a Container App)."""

comptime BACKEND_BODY_CAP_UNLIMITED: Int = 0
"""A backend with no request-body ceiling. Zero rather than a large sentinel so
the "did anyone state a cap" question has an obviously-distinct answer from
"the cap is big"."""


def transport_class_name(cls: Int) -> StaticString:
    """The transport class as a stable token (for a census line, a test message,
    or a rendered plan comment). An unknown code names itself rather than
    defaulting to a plausible-looking class — a misclassified route is a route
    sent to the wrong backend."""
    if cls == TRANSPORT_JSON:
        return "json"
    if cls == TRANSPORT_EXT_METHOD:
        return "ext-method"
    if cls == TRANSPORT_UPGRADE:
        return "upgrade"
    if cls == TRANSPORT_BULK:
        return "bulk"
    return "unknown"


def is_standard_http_method(method: String) -> Bool:
    """True iff `method` is in the GUARANTEED-MINIMUM verb set every edge product
    in the capability table below can both MATCH and FORWARD:
    GET/PUT/POST/DELETE/PATCH/OPTIONS/HEAD.

    ★ THE SET IS THE INTERSECTION, NOT AN OPINION. It is exactly the set that
    (a) OpenAPI 2.0/3.0's Path Item Object can spell, (b) Azure Front Door's
    `RequestMethod` match condition accepts (minus TRACE, which no app here
    serves), and (c) CloudFront's `AllowedMethods` enumerates. Any verb outside
    it is an extension verb SOMEWHERE, so treating it as ordinary is how a plan
    that works on one cloud fails on the next.

    An EMPTY method means "any method" in a route table (the empty string
    matches ANY method). That is NOT a
    standard verb: a wildcard row could carry PROPFIND, so it is classified as an
    extension verb and the plan is forced to say so out loud."""
    if len(method.as_bytes()) == 0:
        return False
    if method == String("GET"):
        return True
    if method == String("PUT"):
        return True
    if method == String("POST"):
        return True
    if method == String("DELETE"):
        return True
    if method == String("PATCH"):
        return True
    if method == String("OPTIONS"):
        return True
    if method == String("HEAD"):
        return True
    return False


def classify_transport(
    method: String, max_body_bytes: Int, is_upgrade: Bool
) -> Int:
    """THE ONE CLASSIFIER. Every count in this file resolves through it, so a
    route cannot be censused as one class and routed as another.

    ORDER IS LOAD-BEARING and is by DECLINE STRENGTH, strongest first:
      1. UPGRADE — a WebSocket route is unservable by the managed wrapper at any
         size and under any verb, so the size and verb tests below are moot.
      2. EXT_METHOD — a verb the config language cannot spell. Checked before
         size because a 1-byte PROPFIND is still unservable.
      3. BULK — a standard verb that only fails on size. Last, because it is the
         only class with a route-preserving fix (move the bytes off the path).
      4. JSON.
    Reversing 2 and 3 would report `PUT <200MB> /x.git/info/lfs/objects/<oid>` as
    an ordinary bulk route on an app where it is also the LFS transfer — which is
    the classification the signed-URL design depends on being right."""
    if is_upgrade:
        return TRANSPORT_UPGRADE
    if not is_standard_http_method(method):
        return TRANSPORT_EXT_METHOD
    if max_body_bytes > MANAGED_GATEWAY_BODY_CAP_BYTES:
        return TRANSPORT_BULK
    return TRANSPORT_JSON


# =============================================================================
# 2 — RouteFacet: ONE route of an app's declared inventory.
# =============================================================================


struct RouteFacet(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One (method, path-pattern) row of an app's route inventory, plus the two
    transport facts a route table does not carry.

    ★ `path_pattern` IS THE APP'S OWN PATTERN, VERBATIM — `/rooms/{room}/send`,
    `/{space}/{owner}/{c}`, `/{repo}.git/git-upload-pack`. It is NOT normalized
    into an LB path glob here, deliberately: the SPLIT decision turns on whether
    two rows share a path, and two rows that share a pattern share a path under
    every glob translation, while two rows that differ can be COLLAPSED into
    sharing by a lossy translation. Comparing the app's own strings cannot
    manufacture an overlap that is not there, and cannot hide one that is.

    `distinct_port` records that the route is served by a listener on a DIFFERENT
    container port than the app's main one. It is here because it changes the
    split from a routing question into a PACKAGING question — see
    `SplitCensus.distinct_port_count`."""

    var method: String
    """The HTTP verb, or `""` for a route table's any-method wildcard row."""
    var path_pattern: String
    """The app's own declared pattern, verbatim."""
    var max_body_bytes: Int
    """The largest body this route must accept. 0 = the app's default cap."""
    var is_upgrade: Bool
    """True iff the route is a protocol upgrade (WebSocket)."""
    var distinct_port: Bool
    """True iff served by a listener on a different container port."""

    def __init__(
        out self,
        var method: String,
        var path_pattern: String,
        max_body_bytes: Int = 0,
        is_upgrade: Bool = False,
        distinct_port: Bool = False,
    ):
        self.method = method^
        self.path_pattern = path_pattern^
        self.max_body_bytes = max_body_bytes
        self.is_upgrade = is_upgrade
        self.distinct_port = distinct_port

    def transport(self) -> Int:
        """This facet's transport class, through the ONE classifier."""
        return classify_transport(
            self.method, self.max_body_bytes, self.is_upgrade
        )

    def rides_managed_gateway(self) -> Bool:
        """True iff the MANAGED gateway can carry this route as-is."""
        return self.transport() == TRANSPORT_JSON


# =============================================================================
# 3 — SplitCensus: the MEASUREMENT that decides whether the split is cheap.
# =============================================================================


struct SplitCensus(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The measured shape of one app's split.

    ★ `shared_path_count` IS THE NUMBER THAT DECIDES THIS OPTION, and it is the
    one a route COUNT hides. An app can be 60% JSON by row and still be
    unsplittable, because the JSON rows and the exotic rows sit on the SAME
    paths — which is exactly CalDAV, where `GET /calendars/{o}/{c}/{i}` and
    `PROPFIND /calendars/{o}/{c}/{i}` are one path and two transports. A
    path-only edge (GCP `pathRules`, CloudFront cache behaviors) has no way to
    send them to different backends, so for those edges the split is not
    expensive — it is IMPOSSIBLE, and the honest plan says so instead of
    reporting a favourable percentage."""

    var total: Int
    var managed: Int
    """Rows the managed gateway carries (TRANSPORT_JSON)."""
    var ext_method: Int
    var upgrade: Int
    var bulk: Int
    var shared_path_count: Int
    """Distinct path patterns carrying BOTH a managed row and an exotic row."""
    var distinct_port_count: Int
    """Exotic rows served on a different container port than the main listener."""
    var max_body_bytes: Int
    """The LARGEST body any row in this inventory must accept. Carried so the
    verdict can compare it against the EXOTIC BACKEND's own cap — see
    `CLOUD_RUN_HTTP1_BODY_CAP_BYTES`, the reason a bulk split can be a no-op."""

    def __init__(
        out self,
        total: Int,
        managed: Int,
        ext_method: Int,
        upgrade: Int,
        bulk: Int,
        shared_path_count: Int,
        distinct_port_count: Int,
        max_body_bytes: Int = 0,
    ):
        self.total = total
        self.managed = managed
        self.ext_method = ext_method
        self.upgrade = upgrade
        self.bulk = bulk
        self.shared_path_count = shared_path_count
        self.distinct_port_count = distinct_port_count
        self.max_body_bytes = max_body_bytes

    def exotic(self) -> Int:
        """Rows the managed gateway declines."""
        return self.ext_method + self.upgrade + self.bulk

    def managed_permille(self) -> Int:
        """The managed share in PER MILLE (integer; 1000 = every row). Per mille
        rather than percent so a 1-row-in-200 exotic tail does not round to
        "100% managed" and read as "nothing to move"."""
        if self.total <= 0:
            return 0
        return (self.managed * 1000) // self.total

    def needs_second_backend(self) -> Bool:
        """True iff ANY row is exotic. One WebSocket route costs a whole second
        service, which is why the count matters less than the fact."""
        return self.exotic() > 0

    def needs_method_match(self) -> Bool:
        """True iff separating the halves REQUIRES matching on the HTTP method —
        i.e. at least one path carries both a managed and an exotic row. When
        False the split is a PATH split and every edge in the table can do it."""
        return self.shared_path_count > 0


def split_census(facets: List[RouteFacet]) -> SplitCensus:
    """Measure one app's split. Pure over the facet list.

    THE SHARED-PATH COUNT is computed by grouping on the VERBATIM pattern (see
    `RouteFacet.path_pattern`): a pattern is shared when it carries at least one
    managed row and at least one exotic row. O(n^2) over a route table of tens of
    rows, which is the right trade for a function whose correctness must be
    readable."""
    var total = len(facets)
    var managed = 0
    var ext_method = 0
    var upgrade = 0
    var bulk = 0
    var distinct_port_count = 0
    var max_body = 0

    for i in range(total):
        if facets[i].max_body_bytes > max_body:
            max_body = facets[i].max_body_bytes
        var cls = facets[i].transport()
        if cls == TRANSPORT_JSON:
            managed += 1
        elif cls == TRANSPORT_EXT_METHOD:
            ext_method += 1
        elif cls == TRANSPORT_UPGRADE:
            upgrade += 1
        elif cls == TRANSPORT_BULK:
            bulk += 1
        if cls != TRANSPORT_JSON and facets[i].distinct_port:
            distinct_port_count += 1

    # Distinct patterns carrying BOTH halves. `seen` keeps each pattern counted
    # once, so a path with three exotic verbs is one shared path, not three.
    var shared = 0
    var seen = List[String]()
    for i in range(total):
        var pat = facets[i].path_pattern.copy()
        var already = False
        for s in range(len(seen)):
            if seen[s] == pat:
                already = True
                break
        if already:
            continue
        var has_managed = False
        var has_exotic = False
        for j in range(total):
            if facets[j].path_pattern != pat:
                continue
            if facets[j].rides_managed_gateway():
                has_managed = True
            else:
                has_exotic = True
        if has_managed and has_exotic:
            shared += 1
        seen.append(pat^)

    return SplitCensus(
        total,
        managed,
        ext_method,
        upgrade,
        bulk,
        shared,
        distinct_port_count,
        max_body,
    )


# =============================================================================
# 4 — EdgeCapability: what ONE cloud's edge product can actually do.
# =============================================================================
#
# ★ EVERY FIELD BELOW IS A CITED FACT, NOT AN ESTIMATE. Claims about a cloud
#   component's capabilities are easy to get wrong, so each constructor carries
#   the URL that establishes its row and any field
#   that is UNVERIFIED is named as such in `unverified` rather than guessed.


struct EdgeCapability(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One edge product's ability to serve as the FRONT of a transport split.

    `can_match_method` is the discriminating field: without it, the front door
    cannot send `PROPFIND /x` and `GET /x` to different backends, so an app whose
    census reports `needs_method_match()` cannot be split at that edge AT ALL."""

    var name: String
    var can_match_method: Bool
    """Can the edge ROUTE on the HTTP method?"""
    var forwards_extension_methods: Bool
    """Does the edge FORWARD a verb outside the guaranteed-minimum set?"""
    var carries_upgrade: Bool
    """Does the edge proxy a WebSocket upgrade?"""
    var public_without_allusers: Bool
    """★ Can this edge be PUBLICLY reachable without an `allUsers` IAM binding on
    the compute behind it? An `iam.allowedPolicyMemberDomains` org policy
    REJECTS `allUsers` on Cloud Run, which under such a policy is the entire
    reason the managed gateway is in the request path — see section 5."""
    var citation: String
    """The URL that establishes the row."""
    var unverified: String
    """Any field of THIS row that is inferred rather than documented, named. Empty
    = every field above is cited. A non-empty value is carried into the verdict
    so a plan is never reported as PROCEED on an unchecked capability."""

    def __init__(
        out self,
        var name: String,
        can_match_method: Bool,
        forwards_extension_methods: Bool,
        carries_upgrade: Bool,
        public_without_allusers: Bool,
        var citation: String,
        var unverified: String = String(""),
    ):
        self.name = name^
        self.can_match_method = can_match_method
        self.forwards_extension_methods = forwards_extension_methods
        self.carries_upgrade = carries_upgrade
        self.public_without_allusers = public_without_allusers
        self.citation = citation^
        self.unverified = unverified^


def edge_gcp_api_gateway() -> EdgeCapability:
    """GCP API Gateway (the MANAGED wrapper) — the usual front door for the JSON
    half, and the reason a split is being considered at all.

    It is in the table as an EDGE candidate to record the finding that it cannot
    be the front of its own split: it cannot match on method (its config language
    is OpenAPI, whose Path Item Object has a fixed method list), so it can neither
    forward an extension verb nor route one elsewhere.

    ★ `public_without_allusers = True` is its ONE irreplaceable property here: the
    managed gateway is public BY DESIGN, without an `allUsers` binding, and
    reaches the private Cloud Run backend through a SCOPED `run.invoker` grant on
    its own service account. That is what satisfies the
    `iam.allowedPolicyMemberDomains` org policy."""
    return EdgeCapability(
        String("gcp-api-gateway"),
        False,
        False,
        False,
        True,
        String("https://docs.cloud.google.com/api-gateway/docs/quotas"),
    )


def edge_gcp_global_alb() -> EdgeCapability:
    """GCP Global External Application Load Balancer, `routeRules` mode.

    ★ CAN MATCH METHOD — the claim that it cannot is REFUTED. `HttpHeaderMatch`:
    "The name of the HTTP header to match. For matching against the HTTP
    request's authority, use a headerMatch with the header name ":authority". For
    matching a request's method, use the headerName ":method"." So a single
    url-map CAN send `PROPFIND /calendars/*` and `GET /calendars/*` to different
    backend services.

    ⚠ `forwards_extension_methods` is UNVERIFIED. The `:method` match proves the
    LB can DECIDE on an arbitrary verb; no Google document found states whether
    the GFE FORWARDS an extension verb to the backend. Recorded as unverified
    rather than assumed — it is a one-request experiment against a live LB, and
    it gates this whole option for CalDAV."""
    return EdgeCapability(
        String("gcp-global-alb"),
        True,
        True,
        True,
        False,
        String(
            "https://googleapis.dev/java/google-api-services-compute/latest/"
            "com/google/api/services/compute/model/HttpHeaderMatch.html"
        ),
        String(
            "forwards_extension_methods: no doc found stating the GFE forwards"
            " PROPFIND/REPORT/MKCALENDAR to a backend; :method MATCHING is"
            " documented, FORWARDING is not"
        ),
    )


def edge_aws_alb() -> EdgeCapability:
    """AWS Application Load Balancer.

    ★ The `http-request-method` rule condition is FIRST-CLASS and explicitly
    admits non-standard verbs: "You can specify standard or custom HTTP methods.
    The match evaluation is case-sensitive." — with `"Values": ["CUSTOM-METHOD"]`
    as the doc's own example. AWS also states that Elastic Load Balancing accepts
    all standard and non-standard HTTP methods, so unlike the GCP row, FORWARDING
    is documented too. This is the strongest method-split primitive of the four.

    `public_without_allusers = True`: AWS has no `iam.allowedPolicyMemberDomains`
    analogue in the request path — an ALB target is reached over the network, and
    the anti-bypass layer is a security group / VPC boundary rather than an IAM
    binding on the compute."""
    return EdgeCapability(
        String("aws-alb"),
        True,
        True,
        True,
        True,
        String(
            "https://docs.aws.amazon.com/elasticloadbalancing/latest/"
            "application/rule-condition-types.html"
        ),
    )


def edge_aws_cloudfront() -> EdgeCapability:
    """AWS CloudFront.

    ⛔ CANNOT MATCH OR FORWARD AN EXTENSION VERB. "Allowed HTTP methods" is a
    FIXED THREE-CHOICE ENUM — `GET, HEAD` / `GET, HEAD, OPTIONS` /
    `GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE`. There is no fourth choice and
    no free-form list, so PROPFIND has no spelling. In the table because it is the
    obvious AWS answer to "what is the LB" for a static-SPA-plus-API front door,
    and it is the WRONG answer for any app with a WebDAV surface."""
    return EdgeCapability(
        String("aws-cloudfront"),
        False,
        False,
        True,
        True,
        String(
            "https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/"
            "DownloadDistValuesCacheBehavior.html"
        ),
    )


def edge_azure_front_door() -> EdgeCapability:
    """Azure Front Door (Standard/Premium), rule-set mode.

    ⛔ The `RequestMethod` match condition enumerates its accepted values:
    "One or more HTTP methods from: `GET`, `POST`, `PUT`, `DELETE`, `HEAD`,
    `OPTIONS`, `TRACE`." No WebDAV verb appears, so the ROUTING PRIMITIVE for a
    method split does not exist — independently of whether AFD forwards such a
    verb to an origin.

    ⚠ `forwards_extension_methods` is recorded UNVERIFIED for the same reason as
    the GCP row, and it does not rescue the option here: an edge that forwards a
    verb it cannot match can only send it to the DEFAULT origin."""
    return EdgeCapability(
        String("azure-front-door"),
        False,
        True,
        True,
        True,
        String(
            "https://learn.microsoft.com/en-us/azure/frontdoor/"
            "rules-match-conditions"
        ),
        String(
            "forwards_extension_methods: assumed pass-through; not documented."
            " Irrelevant to the verdict — without a method MATCH the verb can"
            " only reach the default origin"
        ),
    )


# =============================================================================
# 5 — THE AUTH / REACHABILITY MODEL. What verifies the exotic half.
# =============================================================================
#
# ★ THE PREMISE THAT HAS TO BE CHECKED FIRST. The obvious worry about this
#   option is "the JSON half keeps gateway-verified identity; the exotic half
#   loses it."
#
#   For a client-passthrough edge (`EdgeAuthPolicy.client_passthrough()` in the
#   GCP bridge: no `securityDefinitions`, no per-operation `security`, and a
#   documentation marker `x-komira-edge-auth: client-passthrough`) that worry is
#   misdirected. The sole authorizer on the JSON half is already the app's own
#   middleware doing the offline JWKS verify, so a split introduces NO auth
#   asymmetry: `VERIFIER_APP_MIDDLEWARE` is what the managed half has.
#
#   ⚠ AND THAT IS A PROPERTY OF THE EDGE'S AUTH MODE, NOT OF THE DESIGN. An
#   identity-JWT edge (`EdgeAuthPolicy.identity_jwt(issuer, audience)`) emits a
#   real `securityDefinitions` with the JWKS uri derived from the issuer plus
#   `x-google-audiences`. Under it the managed half is `VERIFIER_EDGE_JWT`, and a
#   split whose exotic half is still `VERIFIER_APP_MIDDLEWARE` DOES introduce
#   the asymmetry — for the half that carries the app's data. That is why
#   `SplitPlan` carries the two verifiers SEPARATELY instead of one "is it
#   authenticated" flag: the comparison this option needs is not a boolean, and
#   it changes answer when the edge's auth mode changes. An exotic half that
#   wants to keep pace needs edge-level verification of its own — which is
#   exactly what an Envoy `jwt_authn` filter with `remote_jwks` provides.
#
#   What the split puts at risk in the passthrough case is REACHABILITY, and that
#   is a different thing wearing the same clothes. The managed gateway is in the
#   request path
#   because it is public WITHOUT an `allUsers` binding and reaches the private
#   Cloud Run service through a scoped `run.invoker` grant on its own service
#   account — which is how a deployment satisfies an
#   `iam.allowedPolicyMemberDomains` org policy that REJECTS `allUsers`. A second
#   backend that skips the gateway has no such hop.

comptime VERIFIER_NONE: Int = 0
"""NOTHING verifies the caller: a request with `Bearer not-a-real-grant-token`
gets a 200 with real rows. A plan proposing this is REFUSED, always."""

comptime VERIFIER_APP_MIDDLEWARE: Int = 1
"""The app's own middleware verifies the issuer-minted ES256 identity token
OFFLINE against the published JWKS, with audience containment. The issuer is
not in the request path. ★ This is what BOTH halves have behind a
client-passthrough edge."""

comptime VERIFIER_EDGE_JWT: Int = 2
"""The edge verifies the token before the backend is reached (`jwt_authn` with
`remote_jwks`, or a gateway rendering `securityDefinitions`). Strictly stronger
than APP_MIDDLEWARE — the unauthenticated request never reaches the app.

★ Modelled because the whole point of carrying the two halves' verifiers
separately is to detect the asymmetry the moment one half moves up and the
other does not (see section 5)."""


def verifier_is_weaker_than(a: Int, b: Int) -> Bool:
    """True iff verifier `a` is strictly weaker than `b`, on the total order
    NONE < APP_MIDDLEWARE < EDGE_JWT (which is exactly the numeric order, stated
    as a function so the ordering is a named decision rather than an accident of
    the constants).

    ★ THE ASYMMETRY DETECTOR. `split_verdict` refuses NONE outright, but the
    interesting case is subtler: an exotic half at APP_MIDDLEWARE behind a
    managed half at EDGE_JWT is not unsafe in isolation — it is a REGRESSION for
    the half that carries the app's data. This is what makes that comparable
    without spelling the order out at each call site."""
    return a < b


def verifier_name(v: Int) -> StaticString:
    """The verifier as a stable token."""
    if v == VERIFIER_EDGE_JWT:
        return "edge-jwt"
    if v == VERIFIER_APP_MIDDLEWARE:
        return "app-middleware"
    if v == VERIFIER_NONE:
        return "none"
    return "unknown"


struct SplitPlan(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A PROPOSED transport split for one app: which edge fronts it, what
    verifies each half, and whether the exotic half has an org-policy-safe public
    hop of its own."""

    var app: String
    var edge: EdgeCapability
    var managed_verifier: Int
    var exotic_verifier: Int
    var exotic_hop_public_without_allusers: Bool
    """★ Does the EXOTIC backend have a public hop that does not need `allUsers`?
    False means the second service must either take an `allUsers` binding the org
    policy rejects, or obtain a per-project policy exception — which is a change
    to the anti-bypass layer, not a routing change."""
    var exotic_backend_body_cap_bytes: Int
    """★ The EXOTIC backend's OWN request-body ceiling.
    `BACKEND_BODY_CAP_UNLIMITED` (0) = no ceiling.

    Here because moving a route off a capped edge onto an equally-capped backend
    changes which component answers 413, not whether one does. A Cloud Run
    service over HTTP/1 caps at `CLOUD_RUN_HTTP1_BODY_CAP_BYTES` — the SAME
    32 MiB as the gateway it was moved off — so a bulk split that does
    not also arrange an h2 hop is a no-op that looks like a fix."""

    def __init__(
        out self,
        var app: String,
        var edge: EdgeCapability,
        managed_verifier: Int,
        exotic_verifier: Int,
        exotic_hop_public_without_allusers: Bool,
        exotic_backend_body_cap_bytes: Int = BACKEND_BODY_CAP_UNLIMITED,
    ):
        self.app = app^
        self.edge = edge^
        self.managed_verifier = managed_verifier
        self.exotic_verifier = exotic_verifier
        self.exotic_hop_public_without_allusers = (
            exotic_hop_public_without_allusers
        )
        self.exotic_backend_body_cap_bytes = exotic_backend_body_cap_bytes


# =============================================================================
# 6 — THE VERDICT. Every refusal names itself.
# =============================================================================

comptime SPLIT_PROCEED: Int = 0
comptime SPLIT_UNNECESSARY: Int = 1
"""No exotic row — the app is already wholly on the managed gateway."""
comptime SPLIT_INEXPRESSIBLE: Int = 2
"""The halves share a path and the edge cannot match on method."""
comptime SPLIT_UNREACHABLE: Int = 3
"""The exotic half has no org-policy-safe public hop."""
comptime SPLIT_UNVERIFIED_HALF: Int = 4
"""Something in the plan would serve traffic with nothing verifying the caller."""
comptime SPLIT_EDGE_CANNOT_CARRY: Int = 5
"""The edge itself cannot forward the exotic transport, so the split has no front
door even though the routing could be expressed."""
comptime SPLIT_VERIFIER_ASYMMETRY: Int = 7
"""★ Both halves are verified, but the EXOTIC one verifies more weakly than the
managed one: the half carrying the app's data would be the one with the weaker
check. Refused ahead of every routing arm for the same
reason UNVERIFIED_HALF is: a security regression is not a routing problem."""


comptime SPLIT_BACKEND_CAP: Int = 6
"""★ The routing works, the edge carries it, and the SECOND BACKEND still cannot
accept the body. The no-op split: a route moved off a 32 MB gateway onto a
32 MiB Cloud Run HTTP/1 hop is a route that still 413s, from a different
component. Distinct from every other arm because the fix is neither the url-map
nor the IAM binding — it is the backend's protocol or its platform."""


struct SplitVerdict(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The decision, with the reason attached. A refusal that does not say WHY is
    a refusal the next engineer deletes."""

    var code: Int
    var reason: String
    var caveat: String
    """A PROCEED that rests on an unverified capability carries it here. Never
    empty-string-away an `EdgeCapability.unverified` — a plan built on an
    unchecked platform behaviour must say so at the point of decision."""

    def __init__(out self, code: Int, var reason: String, var caveat: String = String("")):
        self.code = code
        self.reason = reason^
        self.caveat = caveat^

    def proceeds(self) -> Bool:
        return self.code == SPLIT_PROCEED


def split_verdict(census: SplitCensus, plan: SplitPlan) -> SplitVerdict:
    """Decide whether `plan` can carry `census`. Pure; total; every arm names
    itself.

    ORDER IS LOAD-BEARING — strongest refusal first, so a plan is never reported
    as blocked on the cheapest fixable thing while a harder one is also true:
      1. UNVERIFIED_HALF  — a correctness/security refusal outranks everything.
      2. UNNECESSARY      — nothing to split; say so before evaluating an edge.
      3. INEXPRESSIBLE    — the edge cannot separate the halves at all.
      4. EDGE_CANNOT_CARRY— it can separate them but cannot forward one.
      5. UNREACHABLE      — routing works; the second backend cannot be reached.
      6. PROCEED."""
    if plan.managed_verifier == VERIFIER_NONE:
        return SplitVerdict(
            SPLIT_UNVERIFIED_HALF,
            String("the managed half has no verifier"),
        )
    if plan.exotic_verifier == VERIFIER_NONE:
        return SplitVerdict(
            SPLIT_UNVERIFIED_HALF,
            String(
                "the exotic half has no verifier — this is the model that"
                " answered 200 to `Bearer not-a-real-grant-token`"
            ),
        )
    if verifier_is_weaker_than(plan.exotic_verifier, plan.managed_verifier):
        return SplitVerdict(
            SPLIT_VERIFIER_ASYMMETRY,
            String("the exotic half verifies at `")
            + verifier_name(plan.exotic_verifier)
            + String("` behind a managed half at `")
            + verifier_name(plan.managed_verifier)
            + String(
                "` — the weaker check lands on the half carrying the app's data"
            ),
        )
    if not census.needs_second_backend():
        return SplitVerdict(
            SPLIT_UNNECESSARY,
            String("every route rides the managed gateway; no split needed"),
        )
    if census.needs_method_match() and not plan.edge.can_match_method:
        return SplitVerdict(
            SPLIT_INEXPRESSIBLE,
            String("the two halves share ")
            + String(census.shared_path_count)
            + String(" path pattern(s) and ")
            + plan.edge.name
            + String(" cannot route on the HTTP method"),
        )
    if census.ext_method > 0 and not plan.edge.forwards_extension_methods:
        return SplitVerdict(
            SPLIT_EDGE_CANNOT_CARRY,
            plan.edge.name
            + String(" does not forward extension verbs (")
            + String(census.ext_method)
            + String(" route(s) need one)"),
        )
    if census.upgrade > 0 and not plan.edge.carries_upgrade:
        return SplitVerdict(
            SPLIT_EDGE_CANNOT_CARRY,
            plan.edge.name + String(" does not carry a protocol upgrade"),
        )
    if not plan.exotic_hop_public_without_allusers:
        return SplitVerdict(
            SPLIT_UNREACHABLE,
            String(
                "the exotic backend has no public hop that avoids an `allUsers`"
                " binding, which `iam.allowedPolicyMemberDomains` rejects"
            ),
        )
    if (
        plan.exotic_backend_body_cap_bytes != BACKEND_BODY_CAP_UNLIMITED
        and census.max_body_bytes > plan.exotic_backend_body_cap_bytes
    ):
        return SplitVerdict(
            SPLIT_BACKEND_CAP,
            String("the exotic backend caps request bodies at ")
            + String(plan.exotic_backend_body_cap_bytes)
            + String(" bytes and the app needs ")
            + String(census.max_body_bytes)
            + String(
                " — moving the route changes which component answers 413, not"
                " whether one does"
            ),
        )
    return SplitVerdict(
        SPLIT_PROCEED, String("split is expressible and reachable"),
        plan.edge.unverified.copy(),
    )


def verdict_name(code: Int) -> StaticString:
    """The verdict as a stable token."""
    if code == SPLIT_PROCEED:
        return "PROCEED"
    if code == SPLIT_UNNECESSARY:
        return "UNNECESSARY"
    if code == SPLIT_INEXPRESSIBLE:
        return "INEXPRESSIBLE"
    if code == SPLIT_UNREACHABLE:
        return "UNREACHABLE"
    if code == SPLIT_UNVERIFIED_HALF:
        return "UNVERIFIED_HALF"
    if code == SPLIT_EDGE_CANNOT_CARRY:
        return "EDGE_CANNOT_CARRY"
    if code == SPLIT_BACKEND_CAP:
        return "BACKEND_CAP"
    if code == SPLIT_VERIFIER_ASYMMETRY:
        return "VERIFIER_ASYMMETRY"
    return "UNKNOWN"


def census_line(app: String, census: SplitCensus) -> String:
    """One census line, stable enough to diff across commits. The shape a report
    quotes and a test asserts, so the number in the report and the number the
    gate checked are the same string."""
    return (
        app
        + String(" total=")
        + String(census.total)
        + String(" managed=")
        + String(census.managed)
        + String(" exotic=")
        + String(census.exotic())
        + String(" (ext=")
        + String(census.ext_method)
        + String(" upgrade=")
        + String(census.upgrade)
        + String(" bulk=")
        + String(census.bulk)
        + String(") shared_paths=")
        + String(census.shared_path_count)
        + String(" managed_permille=")
        + String(census.managed_permille())
    )
