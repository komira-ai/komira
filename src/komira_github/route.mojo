# =============================================================================
# komira_github/route.mojo -- the REST subset, as data, and the one matcher
#   every request passes before anything is sent.
# =============================================================================
#
# `github_routes()` is the whole of the GitHub REST API this package will
# send: each row is a method, a path template, the credential the route
# takes (the App JWT or an installation token), the installation permission
# GitHub requires for it, and, for a list route, the member that holds the
# page's items. `match_route(method, path)` returns the row a request
# matches, or -1; the client refuses a -1 with `GitHubError[NOT_ALLOWED]`
# before a credential is minted or a byte is sent, so a request built by
# hand for any other route (`PUT .../environments/...`, a
# `workflow_dispatch` `POST .../actions/workflows/{id}/dispatches`) never
# leaves the process. The table holds no write to Actions, no write to
# contents and no administration call: the only writes are creating an
# installation token and creating or updating a check run.
#
# Template parameters:
#   {owner} {repo} {username}  one segment of 1-100 bytes from
#                              `[A-Za-z0-9._-]`, never `.` or `..`;
#   {..._id} {attempt_number}  one segment of decimal digits, 1-19 of them,
#                              no leading zero (GitHub's ids start at 1);
#   {path}                     one or more segments (the last template
#                              item), each non-empty, not `.` or `..`, of
#                              RFC 3986 unreserved bytes and `%XX` escapes,
#                              with `%2F`, `%2E` and `%5C` (either case)
#                              refused so no segment can name a separator
#                              or a dot segment once decoded.
# The path is matched as it will be sent (escaped), so what is checked is
# what goes on the wire. `query` is checked separately (`check_query`).
# =============================================================================


comptime AUTH_APP: Int = 1
"""The route takes the App JWT."""
comptime AUTH_INSTALLATION: Int = 2
"""The route takes an installation access token."""


@fieldwise_init
struct GitHubRoute(Copyable, Movable, Deinitable, ImplicitlyCopyable):
    """One row of the REST subset (module header)."""

    var name: String
    """GitHub's operation id, e.g. `repos/get`."""
    var method: String
    var template: String
    var auth: Int
    var permission: String
    """`<permission>:<read|write>` an installation token needs; "" for an
    App route."""
    var items_key: String
    """The page member holding a list route's items; "" when not a list."""


def github_routes() -> List[GitHubRoute]:
    """The REST subset (module header). The order is the index
    `match_route` returns."""
    var r = List[GitHubRoute]()
    # The App's own routes (App JWT).
    r.append(GitHubRoute("apps/get-authenticated", "GET", "/app", AUTH_APP, "", ""))
    r.append(GitHubRoute(
        "apps/get-installation", "GET", "/app/installations/{installation_id}", AUTH_APP, "", ""
    ))
    r.append(GitHubRoute(
        "apps/get-repo-installation", "GET", "/repos/{owner}/{repo}/installation", AUTH_APP, "", ""
    ))
    r.append(GitHubRoute(
        "apps/create-installation-access-token",
        "POST",
        "/app/installations/{installation_id}/access_tokens",
        AUTH_APP,
        "",
        "",
    ))
    # Installation routes (installation token).
    r.append(GitHubRoute(
        "apps/list-repos-accessible-to-installation",
        "GET",
        "/installation/repositories",
        AUTH_INSTALLATION,
        "metadata:read",
        "repositories",
    ))
    r.append(GitHubRoute(
        "repos/get", "GET", "/repos/{owner}/{repo}", AUTH_INSTALLATION, "metadata:read", ""
    ))
    r.append(GitHubRoute(
        "actions/list-workflow-runs-for-repo",
        "GET",
        "/repos/{owner}/{repo}/actions/runs",
        AUTH_INSTALLATION,
        "actions:read",
        "workflow_runs",
    ))
    r.append(GitHubRoute(
        "actions/get-workflow-run",
        "GET",
        "/repos/{owner}/{repo}/actions/runs/{run_id}",
        AUTH_INSTALLATION,
        "actions:read",
        "",
    ))
    r.append(GitHubRoute(
        "actions/get-workflow-run-attempt",
        "GET",
        "/repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}",
        AUTH_INSTALLATION,
        "actions:read",
        "",
    ))
    r.append(GitHubRoute(
        "actions/list-jobs-for-workflow-run",
        "GET",
        "/repos/{owner}/{repo}/actions/runs/{run_id}/jobs",
        AUTH_INSTALLATION,
        "actions:read",
        "jobs",
    ))
    r.append(GitHubRoute(
        "actions/list-jobs-for-workflow-run-attempt",
        "GET",
        "/repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}/jobs",
        AUTH_INSTALLATION,
        "actions:read",
        "jobs",
    ))
    r.append(GitHubRoute(
        "actions/get-job-for-workflow-run",
        "GET",
        "/repos/{owner}/{repo}/actions/jobs/{job_id}",
        AUTH_INSTALLATION,
        "actions:read",
        "",
    ))
    r.append(GitHubRoute(
        "actions/list-workflow-run-artifacts",
        "GET",
        "/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts",
        AUTH_INSTALLATION,
        "actions:read",
        "artifacts",
    ))
    r.append(GitHubRoute(
        "actions/get-artifact",
        "GET",
        "/repos/{owner}/{repo}/actions/artifacts/{artifact_id}",
        AUTH_INSTALLATION,
        "actions:read",
        "",
    ))
    r.append(GitHubRoute(
        "repos/get-collaborator-permission-level",
        "GET",
        "/repos/{owner}/{repo}/collaborators/{username}/permission",
        AUTH_INSTALLATION,
        "metadata:read",
        "",
    ))
    r.append(GitHubRoute(
        "checks/create",
        "POST",
        "/repos/{owner}/{repo}/check-runs",
        AUTH_INSTALLATION,
        "checks:write",
        "",
    ))
    r.append(GitHubRoute(
        "checks/update",
        "PATCH",
        "/repos/{owner}/{repo}/check-runs/{check_run_id}",
        AUTH_INSTALLATION,
        "checks:write",
        "",
    ))
    r.append(GitHubRoute(
        "repos/get-content",
        "GET",
        "/repos/{owner}/{repo}/contents/{path}",
        AUTH_INSTALLATION,
        "contents:read",
        "",
    ))
    return r^


def route_index(name: String) -> Int:
    """The index of the row named `name`, -1 when there is none."""
    var routes = github_routes()
    for i in range(len(routes)):
        if routes[i].name == name:
            return i
    return -1


def path_segments(path: String) -> List[String]:
    """The segments of `path` after its leading `/` (`/a/b` -> `a`, `b`;
    `/` -> one empty segment). The caller checks the leading `/`."""
    var out = List[String]()
    var b = path.as_bytes()
    var start = 1
    for i in range(1, len(b) + 1):
        if i == len(b) or b[i] == UInt8(ord("/")):
            out.append(String(path[byte=start:i]))
            start = i + 1
    return out^


def _is_name_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("."))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("-"))
    )


def is_name_segment(s: String) -> Bool:
    """An owner, repository or user name: 1-100 bytes of `[A-Za-z0-9._-]`,
    not `.` and not `..`."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 100:
        return False
    if s == "." or s == "..":
        return False
    for i in range(len(b)):
        if not _is_name_byte(b[i]):
            return False
    return True


def is_id_segment(s: String) -> Bool:
    """1-19 decimal digits, the first not `0`."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 19:
        return False
    if b[0] == UInt8(ord("0")):
        return False
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return False
    return True


def is_unreserved(c: UInt8) -> Bool:
    """RFC 3986 unreserved: `[A-Za-z0-9-._~]`."""
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("-"))
        or c == UInt8(ord("."))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("~"))
    )


def _hex_value(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c - UInt8(ord("0")))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c - UInt8(ord("a"))) + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c - UInt8(ord("A"))) + 10
    return -1


def is_path_segment(s: String) -> Bool:
    """One escaped segment of a `{path}` (module header)."""
    var b = s.as_bytes()
    if len(b) == 0 or s == "." or s == "..":
        return False
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord("%")):
            if i + 2 >= len(b):
                return False
            var hi = _hex_value(b[i + 1])
            var lo = _hex_value(b[i + 2])
            if hi < 0 or lo < 0:
                return False
            var v = hi * 16 + lo
            if v == 0x2F or v == 0x2E or v == 0x5C:
                return False
            i += 3
            continue
        if not is_unreserved(c):
            return False
        i += 1
    return True


def _template_param_ok(param: String, seg: String) -> Bool:
    """Whether `seg` fills the template parameter `{param}` (not `{path}`)."""
    if param.endswith("_id") or param == "attempt_number":
        return is_id_segment(seg)
    return is_name_segment(seg)


def match_template(template: String, path: String) -> Bool:
    """Whether the escaped `path` fills `template` (module header)."""
    if not path.startswith("/"):
        return False
    var t = path_segments(template)
    var p = path_segments(path)
    var ti = 0
    var pi = 0
    while ti < len(t):
        var ts = t[ti]
        if ts == "{path}":
            # The last template item: every remaining segment, at least one.
            if ti != len(t) - 1 or pi >= len(p):
                return False
            while pi < len(p):
                if not is_path_segment(p[pi]):
                    return False
                pi += 1
            return True
        if pi >= len(p):
            return False
        var ps = p[pi]
        if ts.startswith("{") and ts.endswith("}"):
            var param = String(ts[byte = 1 : ts.byte_length() - 1])
            if not _template_param_ok(param, ps):
                return False
        elif ts != ps:
            return False
        ti += 1
        pi += 1
    return pi == len(p)


def match_route(method: String, path: String) -> Int:
    """The index in `github_routes()` of the row `method` and the escaped
    `path` match, -1 when none does. The method is compared exactly
    (upper case)."""
    var routes = github_routes()
    for i in range(len(routes)):
        if routes[i].method == method and match_template(routes[i].template, path):
            return i
    return -1


def check_query(query: String) -> Bool:
    """A query is empty or `&`-joined `key=value` pairs: keys 1-32 bytes of
    `[a-z_]`, values of unreserved bytes and `%XX` escapes (possibly
    empty)."""
    if query.byte_length() == 0:
        return True
    var b = query.as_bytes()
    var i = 0
    while i <= len(b):
        # One pair from i to the next '&' or the end.
        var key_len = 0
        while i < len(b) and b[i] != UInt8(ord("=")) and b[i] != UInt8(ord("&")):
            var c = b[i]
            if not ((c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or c == UInt8(ord("_"))):
                return False
            key_len += 1
            i += 1
        if key_len == 0 or key_len > 32:
            return False
        if i >= len(b) or b[i] != UInt8(ord("=")):
            return False
        i += 1
        while i < len(b) and b[i] != UInt8(ord("&")):
            var c = b[i]
            if c == UInt8(ord("%")):
                if i + 2 >= len(b) or _hex_value(b[i + 1]) < 0 or _hex_value(b[i + 2]) < 0:
                    return False
                i += 3
                continue
            if not is_unreserved(c):
                return False
            i += 1
        if i == len(b):
            return True
        i += 1  # past '&'; a trailing '&' leaves an empty key, refused above
    return True
