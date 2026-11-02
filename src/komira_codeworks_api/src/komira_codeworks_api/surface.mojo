# The CodeWorks HTTP surface: which request paths are the git wire, which are the
# repository and review control routes, which are liveness probes, and which arm
# of the one CodeWorks service owns each.
#
# CodeWorks has two protocol surfaces, and mixing them up is how a route ends up
# on the wrong plane or behind no gate:
#
#   1. The control plane: a JSON/HTTP API over CodeWorks' resources, in two
#      sub-surfaces. REPO is repository create and list (`POST /repos`,
#      `GET /repos`). REVIEW is code review
#      (`/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`,
#      `/reviews/*`).
#   2. The git wire dataplane: `/<repo>.git/...`, the git smart and dumb HTTP
#      protocol (`info/refs`, `git-upload-pack`, `git-receive-pack`, loose object
#      reads). It is not a JSON API: the client is `git`, the framing is pkt-line,
#      the payload is a packfile.
#
# One service serves both, in two arms. The GIT arm owns the wire and the
# repository routes (the repository is a prefix in the object store the arm
# holds); the REVIEW arm owns the review routes. The plane and the arm are
# different questions, and this module answers both.
#
# Classification is not authorization. Every function here answers "which plane,
# which arm, which repository", never "is this request allowed". A path nobody
# declared is `CODEWORKS_PLANE_UNKNOWN` and `CODEWORKS_OWNER_NONE`, and a gate
# built on this module must deny it, as it denies any path it has no row for.
#
# Pure `String` to `Int`, `Bool` or `String` functions: no pointers, no I/O.


# The planes. A request belongs to exactly one.

comptime CODEWORKS_PLANE_UNKNOWN: Int = 0
"""Not a declared CodeWorks route. Serve a 404; a gate must deny it."""

comptime CODEWORKS_PLANE_INFRA: Int = 1
"""A liveness probe (`/healthz`, `/livez`). It carries no resource and returns no
customer data, so it is a declared public route rather than an omission."""

comptime CODEWORKS_PLANE_CONTROL: Int = 2
"""The control plane: repository routes and review routes. See
`codeworks_control_surface_for` for which sub-surface."""

comptime CODEWORKS_PLANE_GIT_WIRE: Int = 3
"""The git wire dataplane (`/<repo>.git/...`)."""


# The control sub-surfaces.

comptime CODEWORKS_SURFACE_NONE: Int = 0
"""Not a control-plane path (a probe, a wire path or an undeclared path)."""

comptime CODEWORKS_SURFACE_REPO: Int = 1
"""Repository create and list: `POST /repos`, `GET /repos`, `/repos/...`."""

comptime CODEWORKS_SURFACE_REVIEW: Int = 2
"""Code review: `/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`,
`/reviews/*`."""


# The service and its owner arms.

comptime CODEWORKS_SERVICE: StaticString = "codeworks"
"""The one service id: the app and the service carry this same token."""

comptime CODEWORKS_OWNER_NONE: Int = 0
"""No arm claims the path. This is the zero value, so an uninitialised owner
means nobody, never an arm."""

comptime CODEWORKS_OWNER_GIT: Int = 1
"""The GIT arm: the wire (`/<repo>.git/...`), the repository routes (`/repos*`)
and the `/healthz` and `/livez` probes."""

comptime CODEWORKS_OWNER_REVIEW: Int = 2
"""The REVIEW arm: `/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`
and `/reviews/*`."""


# The response attribution marker. A status code cannot say whether a response
# came from a CodeWorks process: `GET /livez -> 200` read at an edge can be
# answered by a proxy default, and a refusal before the request reaches the
# service looks the same as one from a service that does not exist. A service
# stamps this header on its own responses and a validator checks it is present.
# Presence is what counts: the value is a constant, so it can carry no
# configuration to an unauthenticated caller of a public probe.

comptime CODEWORKS_MARKER_HEADER: StaticString = "x-komira-codeworks"
"""The marker header name, lowercase: a response header map keyed by lowercase
name would otherwise hold a second entry for a mixed-case spelling."""

comptime CODEWORKS_MARKER_VALUE: StaticString = "1"
"""The marker header value: a constant, never a revision or a build id."""


# The resource type keys a gate uses for per-resource authorization.

comptime CODEWORKS_RESOURCE_TYPE_REPO: StaticString = "codeworks.repo"
"""The governed resource type of a repository; the wire's per-repo resource is
named by this type and `codeworks_git_wire_repo_name`."""

comptime CODEWORKS_RESOURCE_TYPE_REVIEW: StaticString = "codeworks.review"
"""The governed resource type of a code review."""


# Route literals: the one spelling of every path prefix.

comptime CODEWORKS_GIT_SUFFIX: StaticString = ".git"
comptime CODEWORKS_REPOS_SEGMENT: StaticString = "repos"
comptime CODEWORKS_REVIEW_WORKSPACES_PREFIX: StaticString = "/workspaces/"
comptime CODEWORKS_REVIEW_PREFIX: StaticString = "/reviews/"
comptime CODEWORKS_REVIEW_SEGMENT: StaticString = "/reviews"
comptime CODEWORKS_REVIEW_POLICY_SEGMENT: StaticString = "/review-policy"
comptime CODEWORKS_INFRA_HEALTHZ: StaticString = "healthz"
comptime CODEWORKS_INFRA_LIVEZ: StaticString = "livez"


def _first_segment(path: String) -> String:
    """The first non-empty `/`-delimited segment of `path`. Leading slashes are
    skipped and everything from a `?` on is ignored. `/` and `""` give `""`."""
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


def codeworks_path_is_git_wire(path: String) -> Bool:
    """True when the first segment of `path` is a `<repo>.git` mount, which is how
    every git client addresses a repository. This is the one predicate that
    separates the dataplane from the control plane."""
    return _first_segment(path).endswith(String(CODEWORKS_GIT_SUFFIX))


def codeworks_git_wire_repo_name(path: String) -> String:
    """The repository a git-wire request targets: the `<repo>` of
    `/<repo>.git/...`, without the `.git` suffix. It is `""` when `path` is not a
    git-wire path (and for the degenerate mount `/.git`, which names no
    repository).

    This is the one extraction. A gate that authorizes the repository and a
    router that serves it must both read this, so they cannot disagree about
    which repository a request touches."""
    var first = _first_segment(path)
    if not first.endswith(String(CODEWORKS_GIT_SUFFIX)):
        return String("")
    var suffix_len = len(String(CODEWORKS_GIT_SUFFIX).as_bytes())
    var keep = first.byte_length() - suffix_len
    return String(first[byte=0:keep])


def codeworks_path_is_repo_control(path: String) -> Bool:
    """True when `path` is the repository control surface (`/repos` or
    `/repos/...`). Repository create and list are control-plane routes even
    though the git arm serves them."""
    return _first_segment(path) == String(CODEWORKS_REPOS_SEGMENT)


def codeworks_repo_name_is_safe(name: String) -> Bool:
    """True when `name` is a legal repository name: a non-empty run of
    `[A-Za-z0-9._-]` with no `..` run and no leading `.`.

    A repository name becomes a key prefix in an object store, so this is a
    namespace-escape guard rather than cosmetic validation. It accepts or
    rejects and never rewrites: a grant is matched on the bytes of the name, so a
    name quietly fixed here would be stored under one spelling and authorized
    under another. The `.git` suffix is likewise not stripped; a caller that
    wants it removed does so before asking."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    if b[0] == UInt8(46):  # a leading '.' hides the repository
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
        # No `..` run: '/' is already outside the class, but a store that treated
        # some other byte as a separator would need only this.
        if c == UInt8(46) and i + 1 < len(b) and b[i + 1] == UInt8(46):
            return False
    return True


def codeworks_path_owned_by_review(path: String) -> Bool:
    """True when `path` belongs to the review sub-surface: anything under
    `/reviews/`, and a path under `/workspaces/` that holds `/reviews` (the
    reviews family) or `/review-policy` (which does not contain `/reviews` and so
    needs its own match). A bare `/workspaces/:wid` is not review."""
    if path.startswith(String(CODEWORKS_REVIEW_PREFIX)):
        return True
    if path.startswith(String(CODEWORKS_REVIEW_WORKSPACES_PREFIX)) and (
        String(CODEWORKS_REVIEW_SEGMENT) in path
        or String(CODEWORKS_REVIEW_POLICY_SEGMENT) in path
    ):
        return True
    return False


def codeworks_path_is_infra(path: String) -> Bool:
    """True when `path` is a liveness probe (`/healthz` or `/livez`). A probe is
    public because it is declared to be, never because it was forgotten. A
    repository cannot name itself a probe: `/healthz.git/...` is the wire."""
    var first = _first_segment(path)
    return first == String(CODEWORKS_INFRA_HEALTHZ) or first == String(
        CODEWORKS_INFRA_LIVEZ
    )


def codeworks_control_surface_for(path: String) -> Int:
    """The control sub-surface of `path` (`CODEWORKS_SURFACE_*`), or
    `CODEWORKS_SURFACE_NONE` when it is not a control-plane path. The control
    routes match whole segments, so a repository named `reviews.git` is not
    taken for the review surface; the wire is still excluded first so that does
    not rest on the spelling of a prefix."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_SURFACE_NONE
    if codeworks_path_is_infra(path):
        return CODEWORKS_SURFACE_NONE
    if codeworks_path_is_repo_control(path):
        return CODEWORKS_SURFACE_REPO
    if codeworks_path_owned_by_review(path):
        return CODEWORKS_SURFACE_REVIEW
    return CODEWORKS_SURFACE_NONE


def codeworks_plane_for(path: String) -> Int:
    """The plane `path` belongs to (`CODEWORKS_PLANE_*`). An undeclared path is
    `CODEWORKS_PLANE_UNKNOWN`."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_PLANE_GIT_WIRE
    if codeworks_path_is_infra(path):
        return CODEWORKS_PLANE_INFRA
    if codeworks_control_surface_for(path) != CODEWORKS_SURFACE_NONE:
        return CODEWORKS_PLANE_CONTROL
    return CODEWORKS_PLANE_UNKNOWN


def codeworks_path_owned_by_git(path: String) -> Bool:
    """True when `path` is a declared route of the git arm: the wire or the
    repository routes. Like `codeworks_path_owned_by_review` it names declared
    resource routes only (no probes), which keeps the two predicates disjoint;
    `codeworks_owner_for` attributes the probes."""
    return codeworks_path_is_git_wire(path) or codeworks_path_is_repo_control(path)


def codeworks_owner_for(path: String) -> Int:
    """The arm that owns `path`: `CODEWORKS_OWNER_GIT` (the wire, the repository
    routes, `/healthz`, `/livez`), `CODEWORKS_OWNER_REVIEW`, or
    `CODEWORKS_OWNER_NONE` for an undeclared path.

    A repository named `reviews.git`, `repos.git` or `healthz.git` reaches the
    git arm and is never taken for a review route, a repository route or a probe:
    the route and probe matches are on whole segments, and the wire is tested
    first as well."""
    if codeworks_path_is_git_wire(path):
        return CODEWORKS_OWNER_GIT
    if codeworks_path_is_repo_control(path):
        return CODEWORKS_OWNER_GIT
    if codeworks_path_is_infra(path):
        return CODEWORKS_OWNER_GIT
    if codeworks_path_owned_by_review(path):
        return CODEWORKS_OWNER_REVIEW
    return CODEWORKS_OWNER_NONE
