# =============================================================================
# komira_github/request.mojo -- a request of the REST subset, and one builder
#   per route.
# =============================================================================
#
# A `GitHubRequest` is a method, an escaped path relative to the API root,
# a query and a body. The builders below are the way to make one: each
# checks its names and ids against route.mojo's segment rules and escapes
# what it puts in the path or the query, so the request it returns matches
# its route. A request made by hand is still checked by the client
# (`match_route`) before it is sent; a builder is a convenience, never the
# gate.
#
# The one-repository token. `create_repo_contents_read_token(installation,
# repository_id)` asks for an installation token limited to ONE repository
# and to `contents: read`, the body GitHub documents for
# `POST /app/installations/{installation_id}/access_tokens`:
#   {"repository_ids":[<id>],"permissions":{"contents":"read"}}
# Without `repository_ids` GitHub returns a token for every repository of
# the installation, so the builder refuses an id below 1 rather than send
# a body without one.
#
# Check runs. `CheckRunCreate` and `CheckRunUpdate` are written as the JSON
# GitHub's `checks/create` and `checks/update` take (`name`, `head_sha`,
# `status`, `conclusion`, `details_url`, `external_id`, `output.title`,
# `output.summary`), with GitHub's own rules checked first: `status` is one
# of queued / in_progress / completed, a `conclusion` is given exactly when
# the status is completed and is one of GitHub's eight, `head_sha` is 40
# lowercase hex digits, `details_url` is https, and an output has both a
# title and a summary or neither.
# =============================================================================

from komira_json import write_i64_dec, write_json_string

from .error import KIND_BAD_INPUT, github_error
from .route import is_id_segment, is_name_segment, is_unreserved


comptime DEFAULT_PER_PAGE: Int = 100
"""GitHub's largest page; list builders ask for it unless told otherwise."""


struct GitHubRequest(Copyable, Movable, Deinitable):
    """One request: `method`, the escaped `path` (relative to the API root,
    starting `/`), the `query` without its `?`, and the body bytes."""

    var method: String
    var path: String
    var query: String
    var body: List[UInt8]

    def __init__(out self, var method: String, var path: String, var query: String = String("")):
        self.method = method^
        self.path = path^
        self.query = query^
        self.body = List[UInt8]()

    def target(self) -> String:
        """`path` and, when there is one, `?query`."""
        if self.query.byte_length() == 0:
            return self.path
        return self.path + String("?") + self.query


def _name(what: String, s: String) raises -> String:
    if not is_name_segment(s):
        raise github_error(
            KIND_BAD_INPUT, what + String(" is not 1-100 bytes of [A-Za-z0-9._-] (or is . or ..)")
        )
    return s


def _id(what: String, v: Int64) raises -> String:
    var s = String(v)
    if not is_id_segment(s):
        raise github_error(KIND_BAD_INPUT, what + String(" is not a positive id"))
    return s^


def _per_page(per_page: Int) raises -> String:
    if per_page < 1 or per_page > 100:
        raise github_error(KIND_BAD_INPUT, "per_page is outside 1-100")
    return String("per_page=") + String(per_page)


def _hex_digit_upper(v: Int) -> UInt8:
    if v < 10:
        return UInt8(ord("0") + v)
    return UInt8(ord("A") + v - 10)


def percent_encode(s: String) -> String:
    """`s` with every byte outside RFC 3986 unreserved written `%XX`
    (upper-case hex). `/` is escaped too."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if is_unreserved(c):
            out.append(c)
        else:
            out.append(UInt8(ord("%")))
            out.append(_hex_digit_upper(Int(c >> 4)))
            out.append(_hex_digit_upper(Int(c & 0xF)))
    return String(unsafe_from_utf8=Span(out))


def encode_contents_path(path: String) raises -> String:
    """A repository file path as `{path}` segments: split at `/`, each
    segment escaped. Refused: an empty path, an empty segment (a leading,
    trailing or doubled `/`), a `.` or `..` segment, and a NUL byte."""
    var b = path.as_bytes()
    if len(b) == 0:
        raise github_error(KIND_BAD_INPUT, "the contents path is empty")
    var out = String("")
    var start = 0
    for i in range(len(b) + 1):
        if i < len(b) and b[i] == UInt8(0):
            raise github_error(KIND_BAD_INPUT, "the contents path holds a NUL byte")
        if i == len(b) or b[i] == UInt8(ord("/")):
            var seg = String(path[byte=start:i])
            if seg.byte_length() == 0 or seg == "." or seg == "..":
                raise github_error(
                    KIND_BAD_INPUT, "the contents path has an empty, . or .. segment"
                )
            if out.byte_length() > 0:
                out += "/"
            out += percent_encode(seg)
            start = i + 1
    return out^


def _repo_path(owner: String, repo: String) raises -> String:
    return String("/repos/") + _name("owner", owner) + String("/") + _name("repo", repo)


# --- The App's own routes (App JWT) ------------------------------------------


def get_authenticated_app() -> GitHubRequest:
    """`GET /app`."""
    return GitHubRequest(String("GET"), String("/app"))


def get_installation(installation_id: Int64) raises -> GitHubRequest:
    """`GET /app/installations/{installation_id}`."""
    return GitHubRequest(
        String("GET"), String("/app/installations/") + _id("installation_id", installation_id)
    )


def get_repo_installation(owner: String, repo: String) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/installation`."""
    return GitHubRequest(String("GET"), _repo_path(owner, repo) + String("/installation"))


def create_installation_token(installation_id: Int64) raises -> GitHubRequest:
    """`POST /app/installations/{installation_id}/access_tokens` with no
    body: a token for every repository and permission of the installation."""
    return GitHubRequest(
        String("POST"),
        String("/app/installations/")
        + _id("installation_id", installation_id)
        + String("/access_tokens"),
    )


def repo_contents_read_token_body(repository_id: Int64) raises -> List[UInt8]:
    """`{"repository_ids":[<id>],"permissions":{"contents":"read"}}`."""
    _ = _id("repository_id", repository_id)
    var buf = List[UInt8]()
    buf.extend(Span(String('{"repository_ids":[').as_bytes()))
    write_i64_dec(buf, repository_id)
    buf.extend(Span(String('],"permissions":{"contents":"read"}}').as_bytes()))
    return buf^


def create_repo_contents_read_token(
    installation_id: Int64, repository_id: Int64
) raises -> GitHubRequest:
    """The installation token request limited to one repository and
    `contents: read` (module header)."""
    var req = create_installation_token(installation_id)
    req.body = repo_contents_read_token_body(repository_id)
    return req^


# --- Installation routes (installation token) --------------------------------


def list_installation_repositories(per_page: Int = DEFAULT_PER_PAGE) raises -> GitHubRequest:
    """`GET /installation/repositories` (a list route)."""
    return GitHubRequest(String("GET"), String("/installation/repositories"), _per_page(per_page))


def get_repository(owner: String, repo: String) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}`."""
    return GitHubRequest(String("GET"), _repo_path(owner, repo))


def _check_sha(sha: String) raises:
    var b = sha.as_bytes()
    if len(b) != 40:
        raise github_error(KIND_BAD_INPUT, "a commit sha is not 40 lowercase hex digits")
    for i in range(40):
        var c = b[i]
        var ok = (c >= UInt8(ord("0")) and c <= UInt8(ord("9"))) or (
            c >= UInt8(ord("a")) and c <= UInt8(ord("f"))
        )
        if not ok:
            raise github_error(KIND_BAD_INPUT, "a commit sha is not 40 lowercase hex digits")


def list_workflow_runs(
    owner: String, repo: String, head_sha: String = String(""), per_page: Int = DEFAULT_PER_PAGE
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/runs`, optionally only the runs
    of one commit (`head_sha`, 40 lowercase hex digits). A list route."""
    var query = _per_page(per_page)
    if head_sha.byte_length() > 0:
        _check_sha(head_sha)
        query = String("head_sha=") + head_sha + String("&") + query
    return GitHubRequest(String("GET"), _repo_path(owner, repo) + String("/actions/runs"), query^)


def get_workflow_run(owner: String, repo: String, run_id: Int64) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/runs/{run_id}`."""
    return GitHubRequest(
        String("GET"), _repo_path(owner, repo) + String("/actions/runs/") + _id("run_id", run_id)
    )


def get_workflow_run_attempt(
    owner: String, repo: String, run_id: Int64, attempt_number: Int64
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}`."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo)
        + String("/actions/runs/")
        + _id("run_id", run_id)
        + String("/attempts/")
        + _id("attempt_number", attempt_number),
    )


def list_jobs_for_workflow_run(
    owner: String, repo: String, run_id: Int64, per_page: Int = DEFAULT_PER_PAGE
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs` (a list
    route; GitHub's default `filter=latest`)."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo) + String("/actions/runs/") + _id("run_id", run_id) + String("/jobs"),
        _per_page(per_page),
    )


def list_jobs_for_workflow_run_attempt(
    owner: String,
    repo: String,
    run_id: Int64,
    attempt_number: Int64,
    per_page: Int = DEFAULT_PER_PAGE,
) raises -> GitHubRequest:
    """`GET .../actions/runs/{run_id}/attempts/{attempt_number}/jobs` (a
    list route)."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo)
        + String("/actions/runs/")
        + _id("run_id", run_id)
        + String("/attempts/")
        + _id("attempt_number", attempt_number)
        + String("/jobs"),
        _per_page(per_page),
    )


def get_job(owner: String, repo: String, job_id: Int64) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/jobs/{job_id}`."""
    return GitHubRequest(
        String("GET"), _repo_path(owner, repo) + String("/actions/jobs/") + _id("job_id", job_id)
    )


def list_workflow_run_artifacts(
    owner: String, repo: String, run_id: Int64, per_page: Int = DEFAULT_PER_PAGE
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/runs/{run_id}/artifacts` (a list
    route)."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo)
        + String("/actions/runs/")
        + _id("run_id", run_id)
        + String("/artifacts"),
        _per_page(per_page),
    )


def get_artifact(owner: String, repo: String, artifact_id: Int64) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/actions/artifacts/{artifact_id}`."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo) + String("/actions/artifacts/") + _id("artifact_id", artifact_id),
    )


def get_collaborator_permission(
    owner: String, repo: String, username: String
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/collaborators/{username}/permission`."""
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo)
        + String("/collaborators/")
        + _name("username", username)
        + String("/permission"),
    )


def get_contents(
    owner: String, repo: String, path: String, git_ref: String = String("")
) raises -> GitHubRequest:
    """`GET /repos/{owner}/{repo}/contents/{path}`, at `git_ref` (a branch,
    tag or sha) when one is given; `path` is escaped by
    `encode_contents_path`."""
    var query = String("")
    if git_ref.byte_length() > 0:
        query = String("ref=") + percent_encode(git_ref)
    return GitHubRequest(
        String("GET"),
        _repo_path(owner, repo) + String("/contents/") + encode_contents_path(path),
        query^,
    )


# --- Check runs ----------------------------------------------------------------


def is_check_status(s: String) -> Bool:
    return s == "queued" or s == "in_progress" or s == "completed"


def is_check_conclusion(s: String) -> Bool:
    return (
        s == "action_required"
        or s == "cancelled"
        or s == "failure"
        or s == "neutral"
        or s == "success"
        or s == "skipped"
        or s == "stale"
        or s == "timed_out"
    )


@fieldwise_init
struct CheckRunFields(Copyable, Movable, Deinitable):
    """The fields of a check run this package writes. An empty string is
    "not given"; `name` and `head_sha` are required on create."""

    var name: String
    var head_sha: String
    var status: String
    var conclusion: String
    var details_url: String
    var external_id: String
    var output_title: String
    var output_summary: String


def _check_run_rules(f: CheckRunFields, creating: Bool) raises:
    if creating:
        if f.name.byte_length() == 0:
            raise github_error(KIND_BAD_INPUT, "a check run needs a name")
        _check_sha(f.head_sha)
    elif f.head_sha.byte_length() > 0:
        raise github_error(KIND_BAD_INPUT, "head_sha cannot be changed by an update")
    if f.status.byte_length() > 0 and not is_check_status(f.status):
        raise github_error(KIND_BAD_INPUT, "status is not queued, in_progress or completed")
    if f.conclusion.byte_length() > 0:
        if not is_check_conclusion(f.conclusion):
            raise github_error(KIND_BAD_INPUT, "conclusion is not one of GitHub's eight")
        if f.status.byte_length() > 0 and f.status != "completed":
            raise github_error(KIND_BAD_INPUT, "a conclusion is given with a status other than completed")
    elif f.status == "completed":
        raise github_error(KIND_BAD_INPUT, "status completed needs a conclusion")
    if f.details_url.byte_length() > 0 and not f.details_url.startswith("https://"):
        raise github_error(KIND_BAD_INPUT, "details_url is not an https URL")
    if (f.output_title.byte_length() == 0) != (f.output_summary.byte_length() == 0):
        raise github_error(KIND_BAD_INPUT, "an output needs both a title and a summary")


def _member(mut buf: List[UInt8], mut first: Bool, key: String, value: String):
    if value.byte_length() == 0:
        return
    if not first:
        buf.append(UInt8(ord(",")))
    first = False
    write_json_string(buf, key)
    buf.append(UInt8(ord(":")))
    write_json_string(buf, value)


def check_run_body(f: CheckRunFields, creating: Bool) raises -> List[UInt8]:
    """The JSON body of a create (`creating`) or an update, members in the
    order of `CheckRunFields`, given ones only."""
    _check_run_rules(f, creating)
    var buf = List[UInt8]()
    buf.append(UInt8(ord("{")))
    var first = True
    _member(buf, first, String("name"), f.name)
    _member(buf, first, String("head_sha"), f.head_sha)
    _member(buf, first, String("status"), f.status)
    _member(buf, first, String("conclusion"), f.conclusion)
    _member(buf, first, String("details_url"), f.details_url)
    _member(buf, first, String("external_id"), f.external_id)
    if f.output_title.byte_length() > 0:
        if not first:
            buf.append(UInt8(ord(",")))
        first = False
        buf.extend(Span(String('"output":{"title":').as_bytes()))
        write_json_string(buf, f.output_title)
        buf.extend(Span(String(',"summary":').as_bytes()))
        write_json_string(buf, f.output_summary)
        buf.append(UInt8(ord("}")))
    if first:
        raise github_error(KIND_BAD_INPUT, "a check run update sets nothing")
    buf.append(UInt8(ord("}")))
    return buf^


def create_check_run(owner: String, repo: String, fields: CheckRunFields) raises -> GitHubRequest:
    """`POST /repos/{owner}/{repo}/check-runs` (`checks: write`)."""
    var req = GitHubRequest(String("POST"), _repo_path(owner, repo) + String("/check-runs"))
    req.body = check_run_body(fields, True)
    return req^


def update_check_run(
    owner: String, repo: String, check_run_id: Int64, fields: CheckRunFields
) raises -> GitHubRequest:
    """`PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}`."""
    var req = GitHubRequest(
        String("PATCH"),
        _repo_path(owner, repo) + String("/check-runs/") + _id("check_run_id", check_run_id),
    )
    req.body = check_run_body(fields, False)
    return req^
