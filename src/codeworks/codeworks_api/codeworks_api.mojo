# =============================================================================
# src/codeworks/codeworks_api/codeworks_api.mojo — THE CodeWorks API SURFACE:
#   the one declaration of what CodeWorks' HTTP surface IS — which routes are the
#   CONTROL plane, which are the git WIRE dataplane, and which ARM of the ONE
#   service owns each.
# =============================================================================
#
# ★ THE MODEL: git, review and the coordinator are all the SAME API plane, but git
#   is a little more complex because its dataplane is separate. The git APIs CRUD
#   repositories; RBAC then governs the underlying git operations.
#
# ★ ONE SERVICE: CodeWorks is one managed application with one service that serves
#   the git repo APIs, the code review APIs and the device registry. ONE app id, ONE
#   service id, ONE deployed service, ONE binary — and THREE dispatch ARMS. "Which
#   service serves this path" is not a question; "which arm owns it" is, and it is
#   answered by `codeworks_owner_for` below.
#
# So CodeWorks has exactly TWO protocol surfaces, and confusing them is what
# produces drift (a standalone coordinator catalog app; an ungated git wire):
#
#   1. THE CONTROL PLANE — ONE coherent JSON/HTTP API over CodeWorks' RESOURCES.
#      Three sub-surfaces, one plane:
#        * REPO        — repository CRUD (`POST /repos`, `GET /repos`). A repo is a
#                        RESOURCE; creating one hands back a clone URL.
#        * REVIEW      — code review (`/workspaces/:wid/reviews*`,
#                        `/workspaces/:wid/review-policy`, `/reviews/*`).
#        * COORDINATOR — the device farm (`/v1/reservations*`, `/v1/devices*`,
#                        `POST /internal/dispatch/tick`).
#      All three are ordinary request/response APIs over a customer datastore, and
#      all three are governed the SAME way (see the RBAC seam below).
#
#   2. THE GIT WIRE DATAPLANE — `/<repo>.git/...`: the git smart/dumb-HTTP protocol
#      (`info/refs`, `git-upload-pack` ls-refs+fetch, `git-receive-pack`, the dumb
#      `objects/<2>/<38>` reads). This is NOT a JSON API and never will be: the
#      client is `git`, the framing is pkt-line, the payload is a packfile, and the
#      verbs are fetch/push — not CRUD. It is deliberately a SEPARATE SURFACE with
#      its own store (an object-store ODB, not the document DB) and its OWN gate —
#      but NOT its own binary. It is an ARM of the one service; the arm IS the gate
#      (see §3).
#
# ── WHY THIS MODULE EXISTS ───────────────────────────────────────────────────
# Without it, the topology is implicit — split across the git router (control repo
# routes + wire), the service's composite dispatcher (review vs coordinator) and the
# coordinator's own table, with no place that says what the API IS. Anyone asking
# "is this path control or dataplane, and who serves it?" would have to read three
# dispatchers. That is exactly how a route gets added on the wrong plane, or gated
# on neither. This module is the SINGLE declaration; the dispatchers consult it.
#
# ── ★ THE RBAC ATTACH SEAM (declared here, NOT implemented here) ─────────────
# There is NO authorization IN THIS FILE. That is a statement about this module, and
# it must not be read as a statement about CodeWorks: the git wire IS gated (attach
# point 2). A declaration module must not carry a "there is no auth here" claim
# about the surface it declares — that is exactly the sentence someone cites when
# deciding they may add an ungated route.
#
#   ATTACH POINT 1 — THE CONTROL PLANE. **STILL OPEN as a single catalog**, and
#     deliberately so. Review and the coordinator are each gated by their own
#     mechanisms — review behind `GrantVerifyingDispatcher` + a claim-based authz
#     adapter (identity from the VERIFIED claim, never a header); the coordinator
#     behind its device-enrollment / control-plane secret gates. What does NOT yet
#     exist is ONE `resource_catalog.ResourceCatalog` conformer covering all three
#     sub-surfaces. Two real components block it: a review row addressed by its own
#     id needs a store-backed `ContainerResolver` (`GET /reviews/{id}` names a row,
#     not its workspace, and `ResourceCatalog.route` is PURE by design), and the
#     device registry authenticates a DEVICE by an enrollment secret, not a
#     per-resource grant — moving it behind the resource gate is a redesign of device
#     identity, not a catalog row. Consolidating the PROCESS does not require
#     consolidating the AUTHORIZATION MODEL.
#
#   ATTACH POINT 2 — THE GIT WIRE. **FILLED.** The wire is gated per-REPO by
#     `ResourceAuthzGate` over the git resource catalog, keyed on the repo name
#     captured from the first path segment:
#     `ResourceRef.from_name("codeworks.repo", "<repo>")` — the exact registry-free
#     addressing `resource_catalog` provides for apps whose URLs name a string.
#     `codeworks_git_wire_repo_name(path)` below extracts that name and is the ONLY
#     place the extraction happens, so the gate and the router can never disagree
#     about which repo a request touches. Clone/fetch requires READ on that repo,
#     push requires WRITE; no claim => 401; a claim with no grant on the addressed
#     repo => 403; `POST`/`GET /repos` are DECLARED refusals; `/healthz` + `/livez`
#     are DECLARED public rows served with the identity headers STRIPPED. There is
#     no off switch — `KOMIRA_GIT_REQUIRE_AUTH` accepts only `1` or unset and the
#     binary REFUSES TO BOOT on anything else. Action mapping (fetch -> read,
#     push -> write) is the gate's business, not this module's.
#
#   ★ WHERE THE GIT GATE LIVES, because getting this backwards is a TOTAL OUTAGE.
#     The gate is the GIT ARM of the composite — it is NOT wrapped around the
#     composite. The git resource catalog declares no rows for the review or
#     coordinator surfaces, and the gate's test is AFFIRMATIVE (serve only what was
#     positively declared), so wrapping the whole application in it would 403 every
#     review and every device route — correctly, silently, and totally. One gate per
#     arm; three arms; zero shared auth context.
#
# Neither attach point is wired here: this module answers WHICH PLANE / WHICH ARM /
# WHICH REPO, never WHETHER ALLOWED. Classification is not a decision, and an
# unclassified path is `CODEWORKS_PLANE_UNKNOWN` — which a gate must treat as deny,
# exactly as an unrouted path denies.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# A NEUTRAL LEAF with ZERO deps — pure `String` -> `Int` / `Bool` / `String`
# functions, no transport types, no store, no Komira vocabulary. ZERO
# UnsafePointer, no wildcard origins, nothing in a byte-slab. Mojo 1.0.0b2 (def).
# =============================================================================


# =============================================================================
# §1 — THE PLANES. A CodeWorks request belongs to exactly one.
# =============================================================================

comptime CODEWORKS_PLANE_UNKNOWN: Int = 0
"""Not a declared CodeWorks route. The dispatchers 404 it; a gate must DENY it (an
unclassified path is never implicitly public — same posture as
`resource_catalog`'s deny-by-default zero value)."""

comptime CODEWORKS_PLANE_INFRA: Int = 1
"""An infrastructure liveness probe (`/healthz`, `/livez`, `/health`). Carries no
resource, returns no customer data, and is reached by the platform's own prober —
so it is a DECLARED public row, never an omission."""

comptime CODEWORKS_PLANE_CONTROL: Int = 2
"""The CodeWorks CONTROL plane: the ONE coherent resource API (repo CRUD + review +
coordinator). See `codeworks_control_surface_for` for which sub-surface."""

comptime CODEWORKS_PLANE_GIT_WIRE: Int = 3
"""The git WIRE dataplane (`/<repo>.git/...`): the git smart/dumb-HTTP protocol.
Separate framing, separate binary, separate store, separate gate."""


# =============================================================================
# §2 — THE CONTROL SUB-SURFACES. One plane, three surfaces.
# =============================================================================

comptime CODEWORKS_SURFACE_NONE: Int = 0
"""Not a control-plane path (the zero value — an infra, wire or unknown path)."""

comptime CODEWORKS_SURFACE_REPO: Int = 1
"""Repository CRUD — `POST /repos` (create, 201 + clone URL), `GET /repos` (list).
The repo is the tier-1 governed resource `codeworks.repo`; this surface is where a
human creates and enumerates them, and the git WIRE is where they are read/written
by the `git` client."""

comptime CODEWORKS_SURFACE_REVIEW: Int = 2
"""Code review — `/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`,
`/reviews/*`. The tier-1 governed resource `codeworks.review`."""

comptime CODEWORKS_SURFACE_COORDINATOR: Int = 3
"""The device farm — `/v1/reservations*`, `/v1/devices*`,
`POST /internal/dispatch/tick`."""


# =============================================================================
# §3 — THE SERVICE. ONE app (`codeworks`), ONE served container, THREE ARMS.
#
# Why git does NOT get its own binary, even though its store is a raw object
# database and its protocol is pkt-line over a single-threaded serve loop: both
# of those are satisfied INSIDE one process.
#
#   * STORAGE — the service already constructs an object-store client (for the
#     review blob CAS) alongside its document-store handles. The git ODB is a
#     second instance of the same store type, bound to a different bucket — not a
#     new capability. (The two buckets stay two buckets: different key shapes,
#     different lifecycles, different erasure semantics.)
#   * PROTOCOL — the libgit2 codec is built WITHOUT `-DUSE_THREADS`, so codec calls
#     must be SERIALIZED. A single-threaded serve loop satisfies that, and the
#     service's serve loop is single-threaded (one poll cycle, one request at a
#     time; concurrency 1 per instance, scale by INSTANCES). The invariant
#     constrains the LOOP, never the number of binaries.
#
# So a split would be ORGANISATIONAL, and it would cost something real: two
# composition roots that each have to independently get the store policy, the auth
# envelope, the eager backends and the fail-loud ordering right. ONE composition
# root is one place to get it right and one place to review.
#
# Repo CRUD is owned by the GIT arm because the repo IS a prefix in that object
# store: the control surface lives with the custody of the thing it controls — as
# an ARM boundary rather than a SERVICE boundary.
# =============================================================================

comptime CODEWORKS_SERVICE: StaticString = "codeworks"
"""THE service id. ONE token, everywhere — app id, service id, deployed service,
image, bundle `ServiceSpec.name` and binary.

There is deliberately no second service id: the device-farm coordinator is an ARM
of the `codeworks` service, not a service or a managed app of its own. That keeps
the "no catalog app is another app's service" invariant satisfied trivially."""


# =============================================================================
# §3a — THE OWNER ARMS. Which sub-dispatcher of the ONE service owns a path.
#
# `codeworks_owner_for` answers this: which ARM, not which CONTAINER. The service's
# composite dispatcher (generic over its coordinator, review and git arms) fans on
# exactly this.
#
# ★ Each arm carries its OWN gate, and the composite adds none:
#   GIT         — `ResourceAuthzGate` over the git resource catalog (the arm IS the
#                 gate).
#   REVIEW      — `GrantVerifyingDispatcher` + a claim-based authz adapter.
#   COORDINATOR — the device-enrollment + control-plane secret gates.
# Three surfaces, three gates, nothing shared. See the ATTACH SEAM banner above for
# why the git gate must never be hoisted to wrap the composite.
# =============================================================================

comptime CODEWORKS_OWNER_NONE: Int = 0
"""No arm claims this path — it is UNDECLARED. The zero value, so a defaulted or
uninitialised owner is "nobody", never an arm. The composite still has to send an
undeclared request SOMEWHERE (the coordinator, its fail-safe default, which 404s it);
this constant says the DECLARATION claims nothing, which is what a gate must deny."""

comptime CODEWORKS_OWNER_GIT: Int = 1
"""The GIT arm: the git WIRE dataplane (`/<repo>.git/...`), the repo-CRUD control
routes (`/repos*`), and the `/healthz` | `/livez` probes. Served by the git router
behind `ResourceAuthzGate`, over the object-store ODB."""

comptime CODEWORKS_OWNER_REVIEW: Int = 2
"""The REVIEW arm: `/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`,
`/reviews/*`. Served by the review HTTP dispatcher behind `GrantVerifyingDispatcher`,
over the customer document store + the review blob CAS."""

comptime CODEWORKS_OWNER_COORDINATOR: Int = 3
"""The COORDINATOR arm: the device farm (`/v1/reservations*`, `/v1/devices*`,
`POST /internal/dispatch/tick`) and the `/health` probe. It is also the composite's
FAIL-SAFE DEFAULT arm — an undeclared path reaches it and gets a 404, which is why
`CODEWORKS_OWNER_NONE` and "routed to the coordinator" are different facts."""


# =============================================================================
# §4 — THE RESOURCE TYPE KEYS the future RBAC conformer declares (vocabulary
#      only — declared here so the gate and the router name the same things).
# =============================================================================

# =============================================================================
# §3b — ★ THE RESPONSE ATTRIBUTION MARKER. `did this response come from OUR
#       container?` — the question a STATUS CODE cannot answer.
# =============================================================================
#
# When CodeWorks serves behind a PRIVATE backend fronted by a gateway (for example a
# private Cloud Run service behind an API Gateway), two byte-identical outcomes have
# opposite meanings and no status tells them apart:
#
#   * `GET /livez -> 200` read at the EDGE is satisfied by a gateway default
#     backend, a cached response, or any healthy proxy standing in front of a
#     CodeWorks that is not running. A row asserting only the status passes
#     against an app that never received the request.
#   * A bearer-less request to the DIRECT `.run.app` backend is refused by Cloud
#     Run IAM BEFORE it resolves against the service, producing a 403 identical
#     to the one a DELETED service produces. A row asserting "not 2xx without a
#     credential" passes against an app that does not exist.
#
# ⛔ THE NAME LIVES HERE, IN THE DECLARATION LEAF, AND IS NOT MIRRORED. A
# stand-alone validator container must not link the app's serve tree to reach one
# string, which is the usual argument for re-spelling a marker inside the
# validator. CodeWorks does not need that argument: this package has no deps, so
# the SERVICE (which stamps) and the VALIDATOR (which reads) can both consume the
# identical constant at no closure cost. One producer beats a mirror plus a proof
# that the mirror is safe.
#
# PRESENCE, never VALUE. The value is a constant `1`; reading it would invite a
# row that asserts a constant. And it is a constant rather than a version, a
# build id or the deployment id because `/livez` is a DECLARED PUBLIC route —
# anything derived from configuration would leak it to an unauthenticated caller.
comptime CODEWORKS_MARKER_HEADER: StaticString = "x-komira-codeworks"
"""The header NAME. Lowercase: `HttpResponse.headers` is a case-INSENSITIVE map
with a lowercase canonical spelling, so a mixed-case key here would be a SECOND
entry rather than the same one. (An HTTP/1.1 origin may title-case it on the
wire; the client-side read is case-insensitive for the same reason.)"""

comptime CODEWORKS_MARKER_VALUE: StaticString = "1"
"""The header VALUE — a constant. See the block above for why it may not carry a
revision, a build id or the deployment id."""


comptime CODEWORKS_RESOURCE_TYPE_REPO: StaticString = "codeworks.repo"
"""The tier-1 governed resource type for a repository. The git WIRE's per-repo ref
is `ResourceRef.from_name(CODEWORKS_RESOURCE_TYPE_REPO, <repo name>)`."""

comptime CODEWORKS_RESOURCE_TYPE_REVIEW: StaticString = "codeworks.review"
"""The tier-1 governed resource type for a code review."""


# =============================================================================
# §5 — Route literals (the ONE spelling of every CodeWorks path prefix).
# =============================================================================

comptime CODEWORKS_GIT_SUFFIX: StaticString = ".git"
comptime CODEWORKS_REPOS_SEGMENT: StaticString = "repos"
comptime CODEWORKS_REVIEW_WORKSPACES_PREFIX: StaticString = "/workspaces/"
comptime CODEWORKS_REVIEW_PREFIX: StaticString = "/reviews/"
comptime CODEWORKS_REVIEW_SEGMENT: StaticString = "/reviews"
comptime CODEWORKS_REVIEW_POLICY_SEGMENT: StaticString = "/review-policy"
comptime CODEWORKS_COORD_RESERVATIONS_PATH: StaticString = "/v1/reservations"
comptime CODEWORKS_COORD_DEVICES_PATH: StaticString = "/v1/devices"
comptime CODEWORKS_COORD_TICK_PATH: StaticString = "/internal/dispatch/tick"
comptime CODEWORKS_INFRA_HEALTHZ: StaticString = "healthz"
comptime CODEWORKS_INFRA_LIVEZ: StaticString = "livez"
comptime CODEWORKS_INFRA_HEALTH: StaticString = "health"


# -----------------------------------------------------------------------------
# _first_segment — the first non-empty path segment, or "" for `/` and "".
# -----------------------------------------------------------------------------
def _first_segment(path: String) -> String:
    """The first non-empty `/`-delimited segment of `path` (leading slashes and a
    trailing `?query` are ignored). `/` and `""` yield `""`."""
    var out = String("")
    var seen = False
    for c in path.codepoints():
        if c == Codepoint(UInt8(ord("?"))):
            break
        if c == Codepoint(UInt8(ord("/"))):
            if seen:
                break
            continue
        seen = True
        out += String(c)
    return out^


# =============================================================================
# §6 — THE CLASSIFIERS.
# =============================================================================


def codeworks_path_is_git_wire(path: String) -> Bool:
    """True iff `path` targets the git WIRE dataplane — its first segment is a
    `<repo>.git` mount, which is how every git client addresses a repository. This
    is the ONE predicate separating the dataplane from the control plane; the wire
    gate (RBAC attach point 2) hangs off exactly this."""
    return _first_segment(path).endswith(String(CODEWORKS_GIT_SUFFIX))


def codeworks_git_wire_repo_name(path: String) -> String:
    """The REPO NAME a git-wire request targets (the `<repo>` of `/<repo>.git/...`,
    WITHOUT the `.git` suffix), or `""` if `path` is not a git-wire path.

    ★ THE ONE EXTRACTION. The wire gate needs the repo name to build the per-repo
    `ResourceRef.from_name(CODEWORKS_RESOURCE_TYPE_REPO, name)`, and the router
    needs it to pick the store prefix. Deriving it twice is how a gate ends up
    authorizing a different repo than the one served, so both read THIS."""
    var first = _first_segment(path)
    if not first.endswith(String(CODEWORKS_GIT_SUFFIX)):
        return String("")
    var suffix_len = len(String(CODEWORKS_GIT_SUFFIX).as_bytes())
    var keep = first.byte_length() - suffix_len
    return String(first[byte=0:keep])


def codeworks_path_is_repo_control(path: String) -> Bool:
    """True iff `path` is the REPO control surface (`/repos`, `/repos/...`). Repo
    CRUD is CONTROL plane even though the git SERVICE serves it — the service split
    follows store custody, not the API plane."""
    return _first_segment(path) == String(CODEWORKS_REPOS_SEGMENT)


def codeworks_repo_name_is_safe(name: String) -> Bool:
    """True iff `name` is a legal CodeWorks repository name: a non-empty run of
    `[A-Za-z0-9._-]`, with no `/`, no `..` run, and no leading `.`.

    ★ THE ONE NAME PREDICATE, and it lives here for the same reason
    `codeworks_git_wire_repo_name` does. A repo name becomes an OBJECT-STORE KEY
    PREFIX on the git host, so this is a namespace-escape guard, not a cosmetic
    validation, and the git router's repo-create path delegates here before
    materializing the prefix. It is the LAST LINE OF DEFENCE and must stay
    authoritative — an OSS host with no control plane in front of it has only this
    check, and a host WITH one in front of it has only this check too.

    ⛔ A CONTROL PLANE IN FRONT OF THE HOST MUST NOT CALL THIS. Calling it would
    link this package into the control plane's binary and give the control plane an
    opinion about an app's vocabulary. A control plane applies its own, strictly
    MORE permissive check, covering only the mechanical requirements it has of its
    own (a URL path segment it builds, and a derived-key preimage), and holds no
    opinion about what a repository may be called.

    So this function is the SOLE answer to "is this a legal repository name". A
    name a control plane forwards and this rejects is a 400 from the host, relayed
    by the dispatcher with the message below it. ⚠ Do not add a control-plane
    pre-check: a second copy of it is not a duplication of a predicate, it is the
    control plane holding an opinion about an app's vocabulary, which is the
    coupling this separation exists to prevent.

    ★ NO NORMALIZATION HAPPENS HERE — deliberately, and the reason is the whole
    resource-authorization mechanism. `ResourceRef.from_name` hashes the bytes it is
    given, so a name this predicate "helpfully fixed" would be STORED under one
    spelling and HASHED under another, producing a grant the gate can never match
    and a denial nobody can explain. This function ACCEPTS or REJECTS; it never
    rewrites. The `.git` suffix is likewise not stripped here — the caller
    canonicalizes before asking, where the stripping is visible and testable.

    A NEUTRAL LEAF FUNCTION: pure `String -> Bool`, no dependency. A git host and
    a control plane can therefore both reach it without either gaining an edge to
    the other."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    if b[0] == UInt8(46):  # a leading '.' hides the repo and courts `.git`-alikes
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(48) and c <= UInt8(57))  # 0-9
            or (c >= UInt8(97) and c <= UInt8(122))  # a-z
            or (c >= UInt8(65) and c <= UInt8(90))  # A-Z
            or c == UInt8(46)  # '.'
            or c == UInt8(95)  # '_'
            or c == UInt8(45)  # '-'
        )
        if not ok:
            return False
        # No `..` run — defence in depth beyond the char class, which already
        # excludes '/': a traversal needs both, but a store backend that treated
        # some other byte as a separator would need only this.
        if c == UInt8(46) and i + 1 < len(b) and b[i + 1] == UInt8(46):
            return False
    return True


def codeworks_path_owned_by_review(path: String) -> Bool:
    """True iff `path` belongs to the code-review control sub-surface. Under the
    `/workspaces/` prefix, review owns BOTH the `/reviews*` family (reviews CRUD,
    blobs, verdict, comments, file content) AND the per-workspace `/review-policy`
    route (the deploy-gate opt-in — note `/reviews` is NOT a substring of
    `/review-policy`, so it needs its own match). A bare `/workspaces/:wid`
    path is NOT review. The `/reviews/` family is also matched directly (a top-level
    blob/content read). Coordinator routes never match.

    ★ THE ONE REVIEW PREDICATE — the CodeWorks app-service composite fans requests to
    the review sub-dispatcher on exactly this, so the co-mount seam and this
    declaration cannot drift apart."""
    if path.startswith(String(CODEWORKS_REVIEW_PREFIX)):
        return True
    if path.startswith(String(CODEWORKS_REVIEW_WORKSPACES_PREFIX)) and (
        String(CODEWORKS_REVIEW_SEGMENT) in path
        or String(CODEWORKS_REVIEW_POLICY_SEGMENT) in path
    ):
        return True
    return False


def codeworks_path_owned_by_coordinator(path: String) -> Bool:
    """True iff `path` is a declared device-farm (coordinator) control route:
    `/v1/reservations*`, `/v1/devices*`, or `POST /internal/dispatch/tick`.

    NOTE this is the DECLARED set, which is deliberately NARROWER than what the
    app-service composite ROUTES to the coordinator: the composite sends every
    non-review path to the coordinator as its fail-safe default, and the coordinator
    then 404s an unknown one. Declaring only the real routes here means an
    undeclared path classifies UNKNOWN (which a gate denies) instead of inheriting
    the coordinator's default arm."""
    if path.startswith(String(CODEWORKS_COORD_RESERVATIONS_PATH)):
        return True
    if path.startswith(String(CODEWORKS_COORD_DEVICES_PATH)):
        return True
    if path == String(CODEWORKS_COORD_TICK_PATH):
        return True
    return False


def codeworks_path_is_infra(path: String) -> Bool:
    """True iff `path` is an infrastructure liveness probe (`/healthz` and `/livez`,
    owned by the GIT arm and served as `GitResourceCatalog` PUBLIC rows with the
    identity headers STRIPPED; `/health`, owned by the COORDINATOR arm). A DECLARED
    public row — a probe endpoint is public because it is stated to be, never because
    it was forgotten.

    NOTE the probes are NOT part of any arm's owner PREDICATE (`..._owned_by_git` /
    `_review` / `_coordinator`) — those name declared RESOURCE routes and stay
    pairwise disjoint. `codeworks_owner_for` attributes each probe to the arm that
    serves it, which is a routing fact, not a declaration."""
    var first = _first_segment(path)
    return (
        first == String(CODEWORKS_INFRA_HEALTHZ)
        or first == String(CODEWORKS_INFRA_LIVEZ)
        or first == String(CODEWORKS_INFRA_HEALTH)
    )


def codeworks_control_surface_for(path: String) -> Int:
    """The CONTROL sub-surface `path` belongs to (`CODEWORKS_SURFACE_*`), or
    `CODEWORKS_SURFACE_NONE` if it is not a control-plane path. Order matters: the
    git WIRE is excluded FIRST so a repo literally named `reviews.git` can never be
    mistaken for the review surface."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_SURFACE_NONE
    if codeworks_path_is_infra(path):
        return CODEWORKS_SURFACE_NONE
    if codeworks_path_is_repo_control(path):
        return CODEWORKS_SURFACE_REPO
    if codeworks_path_owned_by_review(path):
        return CODEWORKS_SURFACE_REVIEW
    if codeworks_path_owned_by_coordinator(path):
        return CODEWORKS_SURFACE_COORDINATOR
    return CODEWORKS_SURFACE_NONE


def codeworks_plane_for(path: String) -> Int:
    """THE classification: which CodeWorks plane `path` belongs to
    (`CODEWORKS_PLANE_*`). An undeclared path is `CODEWORKS_PLANE_UNKNOWN` — the
    dispatchers 404 it and a gate must deny it."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_PLANE_GIT_WIRE
    if codeworks_path_is_infra(path):
        return CODEWORKS_PLANE_INFRA
    if codeworks_control_surface_for(path) != CODEWORKS_SURFACE_NONE:
        return CODEWORKS_PLANE_CONTROL
    return CODEWORKS_PLANE_UNKNOWN


def codeworks_path_owned_by_git(path: String) -> Bool:
    """True iff `path` is a DECLARED git-arm route: the git WIRE (`/<repo>.git/...`)
    or the repo-CRUD control surface (`/repos*`).

    ★ THE THIRD OF THE THREE OWNER PREDICATES, and it is deliberately symmetric with
    `codeworks_path_owned_by_review` / `codeworks_path_owned_by_coordinator`: each
    names its arm's DECLARED routes and NOTHING else — no infra probes, no default
    arm. That symmetry is what makes the three PAIRWISE DISJOINT, which is the
    property the composite's fan depends on and the one a totality test can actually
    check. The probes are attributed to their arms by `codeworks_owner_for`, which is
    a routing question, not a declaration question."""
    return codeworks_path_is_git_wire(path) or codeworks_path_is_repo_control(path)


def codeworks_owner_for(path: String) -> Int:
    """Which ARM of the ONE `codeworks` service owns `path` — `CODEWORKS_OWNER_GIT`
    (the wire + repo CRUD + `/healthz`|`/livez`), `CODEWORKS_OWNER_REVIEW`,
    `CODEWORKS_OWNER_COORDINATOR` (the device farm + `/health`), or
    `CODEWORKS_OWNER_NONE` for an undeclared path (no arm claims it).

    ★ THIS IS A DISPATCH QUESTION, NOT A DEPLOY QUESTION. There is one container,
    so "which service" has exactly one answer (`CODEWORKS_SERVICE`) and asking it
    tells you nothing. The composite must still send each request to the arm that
    owns it, and this is the partition it fans on.

    ★ ORDER IS LOAD-BEARING: the git WIRE is excluded FIRST, so a repository literally
    named `reviews.git` (or `repos.git`, or `health.git`) reaches the GIT arm and can
    never be mistaken for the review surface, the repo-CRUD surface, or a probe. A
    mis-fan there would gate a push as (or instead of) a review.

    ★ EVERY MIS-FAN DIRECTION IS CLOSED, which is why a fan bug here is loud rather
    than dangerous: a path wrongly sent to GIT is 403'd by the catalog's
    deny-by-default; one wrongly sent to REVIEW is 404'd after authentication; one
    wrongly sent to the COORDINATOR — the fail-safe default — is 404'd. There is no
    arm on which a mis-fan OPENS something."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_OWNER_GIT
    if codeworks_path_is_repo_control(path):
        return CODEWORKS_OWNER_GIT
    var first = _first_segment(path)
    if first == String(CODEWORKS_INFRA_HEALTHZ) or first == String(
        CODEWORKS_INFRA_LIVEZ
    ):
        return CODEWORKS_OWNER_GIT
    if first == String(CODEWORKS_INFRA_HEALTH):
        return CODEWORKS_OWNER_COORDINATOR
    if codeworks_path_owned_by_review(path):
        return CODEWORKS_OWNER_REVIEW
    if codeworks_path_owned_by_coordinator(path):
        return CODEWORKS_OWNER_COORDINATOR
    return CODEWORKS_OWNER_NONE
