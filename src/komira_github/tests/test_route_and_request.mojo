# =============================================================================
# komira_github/tests/test_route_and_request.mojo -- the REST subset as data,
#   the matcher every request passes, and the builders.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_subset_is_exactly: the whole route table, method and template per
#     row, against a written list. Catches a row added (a write to Actions,
#     `PUT .../environments/...`, a `dispatches` route) or one changed.
#   * test_outside_subset_refused: requests outside the table match no row:
#     `PUT /repos/o/r/environments/prod`, workflow_dispatch, a re-run, a
#     DELETE, a lower-case method, a GET to a write-only path, trailing and
#     extra segments. Catches a matcher that ignores the method, matches a
#     prefix, or accepts extra segments.
#   * test_segment_rules: ids (0, leading zero, 20 digits, a sign), names
#     (`.`, `..`, `%2e`, 101 bytes, a space), contents paths (`%2F`, `%2f`,
#     `%2E`, `%5C`, `.`/`..` segments, empty segments, a short escape) are
#     refused in the LAST position of their template as well as earlier.
#   * test_builders_match_their_routes: every builder's request matches the
#     row of the operation it names, with the exact path, query and body.
#   * test_one_repo_token_body: the scoped token body is exactly
#     {"repository_ids":[<id>],"permissions":{"contents":"read"}} and an id
#     below 1 is refused rather than sent without repository_ids.
#   * test_check_run_rules: GitHub's check-run rules (status, conclusion
#     only with completed, sha, https details_url, output pairs), the body
#     members in order, and an update that sets nothing.
#   * test_query_shape: `check_query` accepts key=value pairs and refuses an
#     empty key, a trailing `&`, a bare key, an unescaped byte, a short escape.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_github import (
    CheckRunFields,
    GitHubRequest,
    check_query,
    check_run_body,
    create_check_run,
    create_installation_token,
    create_repo_contents_read_token,
    get_artifact,
    get_authenticated_app,
    get_collaborator_permission,
    get_contents,
    get_installation,
    get_job,
    get_repo_installation,
    get_repository,
    get_workflow_run,
    get_workflow_run_attempt,
    github_error_kind,
    github_routes,
    list_installation_repositories,
    list_jobs_for_workflow_run,
    list_jobs_for_workflow_run_attempt,
    list_workflow_run_artifacts,
    list_workflow_runs,
    match_route,
    route_index,
    update_check_run,
)


comptime SHA = "0123456789abcdef0123456789abcdef01234567"


def test_subset_is_exactly() raises:
    var want = List[String]()
    want.append("GET /app")
    want.append("GET /app/installations/{installation_id}")
    want.append("GET /repos/{owner}/{repo}/installation")
    want.append("POST /app/installations/{installation_id}/access_tokens")
    want.append("GET /installation/repositories")
    want.append("GET /repos/{owner}/{repo}")
    want.append("GET /repos/{owner}/{repo}/actions/runs")
    want.append("GET /repos/{owner}/{repo}/actions/runs/{run_id}")
    want.append("GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}")
    want.append("GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs")
    want.append("GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}/jobs")
    want.append("GET /repos/{owner}/{repo}/actions/jobs/{job_id}")
    want.append("GET /repos/{owner}/{repo}/actions/runs/{run_id}/artifacts")
    want.append("GET /repos/{owner}/{repo}/actions/artifacts/{artifact_id}")
    want.append("GET /repos/{owner}/{repo}/collaborators/{username}/permission")
    want.append("POST /repos/{owner}/{repo}/check-runs")
    want.append("PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}")
    want.append("GET /repos/{owner}/{repo}/contents/{path}")
    var routes = github_routes()
    var got = String("")
    for i in range(len(routes)):
        got += routes[i].method + String(" ") + routes[i].template + String("\n")
    var expect = String("")
    for i in range(len(want)):
        expect += want[i] + String("\n")
    assert_equal(got, expect, "the subset, row by row")
    print("  test_subset_is_exactly PASS")


def test_outside_subset_refused() raises:
    var cases = List[String]()
    cases.append("PUT /repos/o/r/environments/prod")
    cases.append("POST /repos/o/r/actions/workflows/7/dispatches")
    cases.append("POST /repos/o/r/actions/runs/7/rerun")
    cases.append("DELETE /repos/o/r")
    cases.append("PATCH /repos/o/r")
    cases.append("get /repos/o/r")
    cases.append("GET /repos/o/r/check-runs")
    cases.append("PUT /repos/o/r/contents/a.txt")
    cases.append("GET /repos/o/r/")
    cases.append("GET /repos/o")
    cases.append("GET /repos/o/r/actions/runs/7/extra")
    cases.append("GET /app/installations/7/access_tokens")
    cases.append("GET repos/o/r")
    cases.append("GET /repos/o/r/actions/runs?x=1")
    var matched = String("")
    for i in range(len(cases)):
        var sp = cases[i].find(" ")
        var method = String(cases[i][byte=0:sp])
        var path = String(cases[i][byte = sp + 1 : cases[i].byte_length()])
        if match_route(method, path) >= 0:
            matched += cases[i] + String("; ")
    assert_equal(matched, String(""), "requests outside the subset match no row")
    print("  test_outside_subset_refused PASS")


def test_segment_rules() raises:
    var bad = List[String]()
    bad.append("/repos/o/r/actions/runs/0")
    bad.append("/repos/o/r/actions/runs/07")
    bad.append("/repos/o/r/actions/runs/12345678901234567890")
    bad.append("/repos/o/r/actions/runs/-7")
    bad.append("/repos/o/r/actions/runs/7a")
    bad.append("/repos/o/r/actions/runs/7/attempts/0")
    bad.append("/repos/o/r/actions/runs/7/attempts/x")
    bad.append("/repos/./r")
    bad.append("/repos/o/..")
    bad.append("/repos/o/%2e")
    bad.append("/repos/o/r%20x")
    bad.append("/repos/o/r/collaborators/a%20b/permission")
    bad.append("/repos/o/r/contents/a/%2F/b")
    bad.append("/repos/o/r/contents/a/b%2f")
    bad.append("/repos/o/r/contents/a/%2E%2E")
    bad.append("/repos/o/r/contents/a/x%5c")
    bad.append("/repos/o/r/contents/a/..")
    bad.append("/repos/o/r/contents/./a")
    bad.append("/repos/o/r/contents/a//b")
    bad.append("/repos/o/r/contents/a/")
    bad.append("/repos/o/r/contents/a%2")
    bad.append("/repos/o/r/contents/a%zz")
    bad.append("/repos/o/r/contents/a b")
    var long = String("")
    for _ in range(101):
        long += "a"
    bad.append(String("/repos/o/") + long)
    var matched = String("")
    for i in range(len(bad)):
        if match_route(String("GET"), bad[i]) >= 0:
            matched += bad[i] + String("; ")
    assert_equal(matched, String(""), "malformed segments match no row")
    var good = List[String]()
    good.append("/repos/o/r/actions/runs/9223372036854775807")
    good.append("/repos/o-1/r.git_x/actions/runs/1")
    good.append(String("/repos/o/") + String(long[byte=0:100]))
    good.append("/repos/o/r/contents/.github/workflows/ci.yml")
    good.append("/repos/o/r/contents/a%20b/%C3%A9")
    var missed = String("")
    for i in range(len(good)):
        if match_route(String("GET"), good[i]) < 0:
            missed += good[i] + String("; ")
    assert_equal(missed, String(""), "well-formed segments match")
    print("  test_segment_rules PASS")


def _check(req: GitHubRequest, name: String, method: String, target: String) raises:
    assert_equal(req.method, method, name)
    assert_equal(req.target(), target, name)
    var idx = match_route(req.method, req.path)
    assert_true(idx >= 0, name + String(": matches a row"))
    assert_equal(github_routes()[idx].name, name)
    assert_equal(idx, route_index(name))


def test_builders_match_their_routes() raises:
    _check(get_authenticated_app(), "apps/get-authenticated", "GET", "/app")
    _check(get_installation(42), "apps/get-installation", "GET", "/app/installations/42")
    _check(get_repo_installation("o", "r"), "apps/get-repo-installation", "GET", "/repos/o/r/installation")
    _check(
        create_installation_token(42),
        "apps/create-installation-access-token",
        "POST",
        "/app/installations/42/access_tokens",
    )
    assert_equal(len(create_installation_token(42).body), 0, "the whole grant: no body")
    _check(
        list_installation_repositories(),
        "apps/list-repos-accessible-to-installation",
        "GET",
        "/installation/repositories?per_page=100",
    )
    _check(get_repository("o", "r"), "repos/get", "GET", "/repos/o/r")
    _check(
        list_workflow_runs("o", "r", String(SHA), 7),
        "actions/list-workflow-runs-for-repo",
        "GET",
        String("/repos/o/r/actions/runs?head_sha=") + SHA + String("&per_page=7"),
    )
    _check(get_workflow_run("o", "r", 5), "actions/get-workflow-run", "GET", "/repos/o/r/actions/runs/5")
    _check(
        get_workflow_run_attempt("o", "r", 5, 2),
        "actions/get-workflow-run-attempt",
        "GET",
        "/repos/o/r/actions/runs/5/attempts/2",
    )
    _check(
        list_jobs_for_workflow_run("o", "r", 5),
        "actions/list-jobs-for-workflow-run",
        "GET",
        "/repos/o/r/actions/runs/5/jobs?per_page=100",
    )
    _check(
        list_jobs_for_workflow_run_attempt("o", "r", 5, 3),
        "actions/list-jobs-for-workflow-run-attempt",
        "GET",
        "/repos/o/r/actions/runs/5/attempts/3/jobs?per_page=100",
    )
    _check(get_job("o", "r", 8), "actions/get-job-for-workflow-run", "GET", "/repos/o/r/actions/jobs/8")
    _check(
        list_workflow_run_artifacts("o", "r", 5),
        "actions/list-workflow-run-artifacts",
        "GET",
        "/repos/o/r/actions/runs/5/artifacts?per_page=100",
    )
    _check(get_artifact("o", "r", 9), "actions/get-artifact", "GET", "/repos/o/r/actions/artifacts/9")
    _check(
        get_collaborator_permission("o", "r", "octo-cat"),
        "repos/get-collaborator-permission-level",
        "GET",
        "/repos/o/r/collaborators/octo-cat/permission",
    )
    _check(
        get_contents("o", "r", ".github/a b/é.yml", "feature/x"),
        "repos/get-content",
        "GET",
        "/repos/o/r/contents/.github/a%20b/%C3%A9.yml?ref=feature%2Fx",
    )
    var refused = String("")
    try:
        _ = get_repository("o", "..")
        refused += "dotdot "
    except:
        pass
    try:
        _ = get_workflow_run("o", "r", 0)
        refused += "zero-id "
    except:
        pass
    try:
        _ = get_contents("o", "r", "a//b")
        refused += "empty-seg "
    except:
        pass
    try:
        _ = get_contents("o", "r", "a/../b")
        refused += "dotdot-seg "
    except:
        pass
    try:
        _ = list_workflow_runs("o", "r", String(SHA), 101)
        refused += "per_page "
    except:
        pass
    try:
        _ = list_workflow_runs("o", "r", String(SHA).upper())
        refused += "upper-sha "
    except:
        pass
    assert_equal(refused, String(""), "builders refuse what no row would match")
    print("  test_builders_match_their_routes PASS")


def test_one_repo_token_body() raises:
    var req = create_repo_contents_read_token(42, 7)
    _check(req, "apps/create-installation-access-token", "POST", "/app/installations/42/access_tokens")
    assert_equal(
        String(unsafe_from_utf8=Span(req.body)),
        String('{"repository_ids":[7],"permissions":{"contents":"read"}}'),
    )
    var why = String("")
    try:
        _ = create_repo_contents_read_token(42, 0)
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("BAD_INPUT"), "repository id 0 is refused")
    print("  test_one_repo_token_body PASS")


def _fields(
    name: String, sha: String, status: String, conclusion: String, url: String, title: String, summary: String
) -> CheckRunFields:
    return CheckRunFields(name, sha, status, conclusion, url, String("ext-1"), title, summary)


def _body_or_refusal(f: CheckRunFields, creating: Bool) -> String:
    try:
        var b = check_run_body(f, creating)
        return String(unsafe_from_utf8=Span(b))
    except e:
        return String("REFUSED ") + String(e)


def test_check_run_rules() raises:
    assert_equal(
        _body_or_refusal(_fields("build", SHA, "completed", "success", "https://ci.example/1", "T", "S"), True),
        String('{"name":"build","head_sha":"') + SHA
        + String('","status":"completed","conclusion":"success","details_url":"https://ci.example/1","external_id":"ext-1","output":{"title":"T","summary":"S"}}'),
    )
    var refused = List[String]()
    refused.append(_body_or_refusal(_fields("", SHA, "queued", "", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", String(SHA[byte=0:39]), "queued", "", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "done", "", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "completed", "", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "in_progress", "success", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "completed", "passed", "", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "queued", "", "http://ci.example/1", "", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "queued", "", "", "T", ""), True))
    refused.append(_body_or_refusal(_fields("b", SHA, "queued", "", "", "", "S"), True))
    refused.append(_body_or_refusal(_fields("", SHA, "", "", "", "", ""), False))
    var accepted = String("")
    for i in range(len(refused)):
        if not refused[i].startswith("REFUSED "):
            accepted += String("[") + String(i) + String("] ")
    assert_equal(accepted, String(""), "each rule refuses")
    var nothing = CheckRunFields(String(""), String(""), String(""), String(""), String(""), String(""), String(""), String(""))
    assert_true(_body_or_refusal(nothing, False).find("sets nothing") >= 0, "an empty update")
    var upd = update_check_run("o", "r", 77, CheckRunFields(String(""), String(""), String("completed"), String("failure"), String(""), String(""), String(""), String("")))
    _check(upd, "checks/update", "PATCH", "/repos/o/r/check-runs/77")
    assert_equal(String(unsafe_from_utf8=Span(upd.body)), String('{"status":"completed","conclusion":"failure"}'))
    _check(
        create_check_run("o", "r", _fields("b", SHA, "queued", "", "", "", "")),
        "checks/create",
        "POST",
        "/repos/o/r/check-runs",
    )
    print("  test_check_run_rules PASS")


def test_query_shape() raises:
    assert_true(check_query(String("")))
    assert_true(check_query(String("per_page=100&page=2")))
    assert_true(check_query(String("ref=feature%2Fx")))
    assert_true(check_query(String("ref=")))
    var bad = List[String]()
    bad.append("=1")
    bad.append("per_page=1&")
    bad.append("per_page")
    bad.append("ref=a/b")
    bad.append("ref=a%2")
    bad.append("Ref=a")
    bad.append("per_page=1&&page=2")
    var ok = String("")
    for i in range(len(bad)):
        if check_query(bad[i]):
            ok += bad[i] + String("; ")
    assert_equal(ok, String(""), "malformed queries are refused")
    print("  test_query_shape PASS")


def main() raises:
    test_subset_is_exactly()
    test_outside_subset_refused()
    test_segment_rules()
    test_builders_match_their_routes()
    test_one_repo_token_body()
    test_check_run_rules()
    test_query_shape()
    print("PASS komira_github route and request")
