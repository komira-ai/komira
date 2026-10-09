# =============================================================================
# komira_github_fake/tests/test_client_routes.mojo -- the real GitHubAppClient
#   against the fake: the allowlist, pagination, rate limits, and the reads
#   and writes of the subset.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_outside_subset_sends_nothing: `PUT .../environments/prod`, a
#     workflow_dispatch POST, an installation route sent as the App and an
#     App route sent with an installation token, and a query with an
#     unescaped `/`, are refused NOT_ALLOWED with
#     ZERO requests reaching the fake (no token is even minted). Catches a
#     CALL OUTSIDE THE ALLOWLIST (a row added, or the check skipped).
#   * test_pagination_reads_last_page: five runs at two per page are read in
#     three requests to the asked-for path with page=2 and page=3 (never
#     the `/repositories/<id>/...` path the Link names), and the run only
#     the LAST page holds is in the result, in order. Four runs (an exactly
#     full last page) take two requests; none take one. Catches a walk that
#     stops before the last page, follows the Link's URL, or loops.
#   * test_link_that_does_not_advance: a page whose next link names the same
#     page raises BAD_RESPONSE after one request. Catches `<=` weakened to
#     `<` (the walk would read the first page again and again).
#   * test_page_bound: `max_pages` 2 over three pages raises rather than
#     returning a partial list.
#   * test_secondary_limit_not_hot_looped: after a secondary-limit 403 with
#     no retry-after the call raises RATE_LIMITED; calling again at once,
#     at +59 s, and on another installation sends NOTHING (the fake's
#     request count does not move); at +60 s it sends. A second consecutive
#     limit waits 120 s; a retry-after of 5 waits 5 s. Catches a retry loop
#     and a latch that lets the next call out early.
#   * test_primary_limit_per_installation: a primary limit holds its own
#     installation until x-ratelimit-reset and not another one.
#   * test_reads_and_writes: runs by head_sha, a run attempt, jobs of the
#     latest attempt and of attempt 1, a job, artifacts, collaborator
#     permissions (admin, write, none), a file at a ref under an escaped
#     path, a missing file (HTTP_STATUS 404), a check run created and
#     completed. Proves each builder, the fake and the client agree.
#   * test_webhook_delivery_from_fake: the fake's signed delivery verifies,
#     and the same headers over a body with its last byte changed do not.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_github import (
    AppCredentials,
    CheckRunFields,
    GitHubAppClient,
    GitHubRequest,
    GitHubResponse,
    ManualUnixClock,
    create_check_run,
    get_artifact,
    get_authenticated_app,
    get_collaborator_permission,
    get_job,
    get_repository,
    get_workflow_run_attempt,
    github_error_kind,
    list_jobs_for_workflow_run,
    list_jobs_for_workflow_run_attempt,
    list_workflow_run_artifacts,
    list_workflow_runs,
    update_check_run,
    verify_webhook_delivery,
)

from komira_github_fake import FakeGitHub, app_public_key_from_pkcs8, signed_delivery_headers


comptime NOW: Int64 = 1_790_856_000
comptime ISSUER = "12345"
comptime SHA_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
comptime SHA_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
comptime Client = GitHubAppClient[FakeGitHub, ManualUnixClock]


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _ids1(a: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    return out^


def _perms() -> List[String]:
    var p = List[String]()
    p.append(String("metadata:read"))
    p.append(String("contents:read"))
    p.append(String("actions:read"))
    p.append(String("checks:write"))
    return p^


def _bytes(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    return b^


struct Setup(Movable):
    var client: Client
    var inst: Int64
    var inst2: Int64
    var repo: Int64

    def __init__(out self, var client: Client, inst: Int64, inst2: Int64, repo: Int64):
        self.client = client^
        self.inst = inst
        self.inst2 = inst2
        self.repo = repo


def _setup(runs: Int) raises -> Setup:
    var fake = FakeGitHub(String(ISSUER), app_public_key_from_pkcs8(_key()), NOW)
    var r = fake.state.add_repo("alice", "app", _one("alice"))
    var r2 = fake.state.add_repo("bob", "tool", _one("bob"))
    for i in range(runs):
        _ = fake.state.add_run(r, String(SHA_A), "completed", "success")
    var inst = fake.state.install("alice", "alice", _ids1(r), _perms())
    var inst2 = fake.state.install("bob", "bob", _ids1(r2), _perms())
    var client = Client(fake^, AppCredentials(String(ISSUER), _key()), ManualUnixClock(NOW))
    return Setup(client^, inst, inst2, r)


def _at(mut c: Client, t: Int64):
    c.clock().set(t)
    c.transport().set_now(t)


def _kind_of_send(mut c: Client, inst: Int64, req: GitHubRequest) -> String:
    try:
        _ = c.send(inst, req)
    except e:
        return github_error_kind(String(e))
    return String("SENT")


def test_outside_subset_sends_nothing() raises:
    var s = _setup(0)
    var kinds = String("")
    kinds += _kind_of_send(s.client, s.inst, GitHubRequest(String("PUT"), String("/repos/alice/app/environments/prod"))) + " "
    kinds += _kind_of_send(
        s.client, s.inst, GitHubRequest(String("POST"), String("/repos/alice/app/actions/workflows/7/dispatches"))
    ) + " "
    kinds += _kind_of_send(s.client, s.inst, get_authenticated_app()) + " "
    kinds += _kind_of_send(
        s.client, s.inst, GitHubRequest(String("GET"), String("/repos/alice/app"), String("per_page=1&ref=a/b"))
    ) + " "
    try:
        _ = s.client.app_send(get_repository("alice", "app"))
        kinds += "SENT"
    except e:
        kinds += github_error_kind(String(e))
    assert_equal(kinds, String("NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED"))
    assert_equal(s.client.transport().request_count(), 0, "nothing reached GitHub")
    print("  test_outside_subset_sends_nothing PASS")


def test_pagination_reads_last_page() raises:
    var s = _setup(5)
    var items = s.client.list_all(s.inst, list_workflow_runs("alice", "app", String(""), 2))
    assert_equal(len(items), 5, "every run, the last page's included")
    var ids = List[Int64]()
    for i in range(len(items)):
        ids.append(items[i].get(String("id")).as_int64())
    for i in range(1, len(ids)):
        assert_true(ids[i] > ids[i - 1], "in order")
    ref fake = s.client.transport()
    assert_equal(fake.count_route(String("actions/list-workflow-runs-for-repo")), 3)
    var targets = String("")
    for i in range(len(fake.requests)):
        if fake.requests[i].method == "GET":
            targets += fake.requests[i].target + String("\n")
    assert_equal(
        targets,
        String("/repos/alice/app/actions/runs?per_page=2\n")
        + String("/repos/alice/app/actions/runs?per_page=2&page=2\n")
        + String("/repos/alice/app/actions/runs?per_page=2&page=3\n"),
    )
    var s4 = _setup(4)
    assert_equal(len(s4.client.list_all(s4.inst, list_workflow_runs("alice", "app", String(""), 2))), 4)
    assert_equal(s4.client.transport().count_route(String("actions/list-workflow-runs-for-repo")), 2, "a full last page")
    var s0 = _setup(0)
    assert_equal(len(s0.client.list_all(s0.inst, list_workflow_runs("alice", "app"))), 0)
    assert_equal(s0.client.transport().count_route(String("actions/list-workflow-runs-for-repo")), 1)
    print("  test_pagination_reads_last_page PASS")


def test_page_bound() raises:
    var s = _setup(5)
    s.client.max_pages = 2
    var why = String("")
    try:
        _ = s.client.list_all(s.inst, list_workflow_runs("alice", "app", String(""), 2))
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("BAD_RESPONSE"), why)
    assert_equal(s.client.transport().count_route(String("actions/list-workflow-runs-for-repo")), 2)
    print("  test_page_bound PASS")


def test_link_that_does_not_advance() raises:
    var s = _setup(5)
    assert_equal(s.client.send(s.inst, get_repository("alice", "app")).status, 200)
    var body = String('{"total_count":5,"workflow_runs":[{"id":1}]}')
    var page = GitHubResponse(200, _bytes(body))
    page.add_header(String("Link"), String('<https://api.github.com/repositories/1/actions/runs?per_page=2&page=1>; rel="next"'))
    s.client.transport().arm(page^)
    var before = s.client.transport().request_count()
    var why = String("")
    try:
        _ = s.client.list_all(s.inst, list_workflow_runs("alice", "app", String(""), 2))
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("BAD_RESPONSE"), why)
    assert_true(why.find("does not come after") >= 0, why)
    assert_equal(s.client.transport().request_count(), before + 1, "one page read, no loop")
    print("  test_link_that_does_not_advance PASS")


def test_secondary_limit_not_hot_looped() raises:
    var s = _setup(1)
    var req = get_repository("alice", "app")
    assert_equal(s.client.send(s.inst, req).status, 200)
    var before = s.client.transport().request_count()
    s.client.transport().arm_secondary_limit()
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"))
    assert_equal(s.client.transport().request_count(), before + 1, "the limited call was sent once")
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"), "at once: refused")
    assert_equal(_kind_of_send(s.client, s.inst2, req), String("RATE_LIMITED"), "another installation too")
    _at(s.client, NOW + 59)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"), "+59 s: refused")
    assert_equal(s.client.transport().request_count(), before + 1, "nothing more was sent")
    _at(s.client, NOW + 60)
    s.client.transport().arm_secondary_limit()
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"), "+60 s: sent, limited again")
    assert_equal(s.client.transport().request_count(), before + 2)
    _at(s.client, NOW + 60 + 119)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"), "the second wait is 120 s")
    assert_equal(s.client.transport().request_count(), before + 2)
    _at(s.client, NOW + 60 + 120)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("SENT"))
    assert_equal(s.client.latch().secondary_streak, 0, "an answer that is not a limit resets the streak")
    s.client.transport().arm_secondary_limit(5)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"))
    _at(s.client, NOW + 60 + 124)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("RATE_LIMITED"), "retry-after 5: +4 s refused")
    _at(s.client, NOW + 60 + 125)
    assert_equal(_kind_of_send(s.client, s.inst, req), String("SENT"), "+5 s sent")
    print("  test_secondary_limit_not_hot_looped PASS")


def test_primary_limit_per_installation() raises:
    var s = _setup(1)
    var mine = get_repository("alice", "app")
    var theirs = get_repository("bob", "tool")
    assert_equal(s.client.send(s.inst, mine).status, 200)
    assert_equal(s.client.send(s.inst2, theirs).status, 200)
    s.client.transport().arm_primary_limit(NOW + 100)
    assert_equal(_kind_of_send(s.client, s.inst, mine), String("RATE_LIMITED"))
    var before = s.client.transport().request_count()
    assert_equal(_kind_of_send(s.client, s.inst, mine), String("RATE_LIMITED"), "held")
    assert_equal(s.client.transport().request_count(), before, "nothing sent")
    assert_equal(_kind_of_send(s.client, s.inst2, theirs), String("SENT"), "another quota")
    _at(s.client, NOW + 100)
    assert_equal(_kind_of_send(s.client, s.inst, mine), String("SENT"), "after the reset")
    print("  test_primary_limit_per_installation PASS")


def test_reads_and_writes() raises:
    var fake = FakeGitHub(String(ISSUER), app_public_key_from_pkcs8(_key()), NOW)
    var r = fake.state.add_repo("alice", "app", _one("alice"))
    fake.state.set_collaborator(r, "bob", "write")
    var run_a = fake.state.add_run(r, String(SHA_A), "completed", "failure", 2)
    _ = fake.state.add_run(r, String(SHA_B), "in_progress", "")
    var j1 = fake.state.add_job(r, run_a, 1, "build", "completed", "failure")
    var j2 = fake.state.add_job(r, run_a, 2, "build", "completed", "success")
    var art = fake.state.add_artifact(r, run_a, "release-set", 1234)
    fake.state.put_file(r, "v1.2", "ci/release machine.yml", _bytes("stages:\n  - build\n"))
    var inst = fake.state.install("alice", "alice", _ids1(r), _perms())
    var c = Client(fake^, AppCredentials(String(ISSUER), _key()), ManualUnixClock(NOW))

    var runs = c.list_all(inst, list_workflow_runs("alice", "app", String(SHA_B)))
    assert_equal(len(runs), 1)
    assert_equal(runs[0].get(String("head_sha")).as_string(), String(SHA_B))
    var attempt = c.send(inst, get_workflow_run_attempt("alice", "app", run_a, 1)).json()
    assert_equal(attempt.get(String("run_attempt")).as_int64(), 1)
    assert_equal(c.send(inst, get_workflow_run_attempt("alice", "app", run_a, 3)).status, 404)
    var latest = c.list_all(inst, list_jobs_for_workflow_run("alice", "app", run_a))
    assert_equal(len(latest), 1)
    assert_equal(latest[0].get(String("id")).as_int64(), j2, "jobs of the latest attempt")
    var first = c.list_all(inst, list_jobs_for_workflow_run_attempt("alice", "app", run_a, 1))
    assert_equal(first[0].get(String("id")).as_int64(), j1, "jobs of attempt 1")
    assert_equal(c.send(inst, get_job("alice", "app", j1)).json().get(String("conclusion")).as_string(), String("failure"))
    var arts = c.list_all(inst, list_workflow_run_artifacts("alice", "app", run_a))
    assert_equal(arts[0].get(String("name")).as_string(), String("release-set"))
    assert_equal(c.send(inst, get_artifact("alice", "app", art)).json().get(String("size_in_bytes")).as_int64(), 1234)
    var perms = String("")
    for login in [String("alice"), String("bob"), String("carol")]:
        perms += c.send(inst, get_collaborator_permission("alice", "app", login)).json().get(String("permission")).as_string() + " "
    assert_equal(perms, String("admin write none "))
    var file = c.read_file(inst, "alice", "app", "ci/release machine.yml", "v1.2")
    assert_equal(String(unsafe_from_utf8=Span(file)), String("stages:\n  - build\n"))
    var why = String("")
    try:
        _ = c.read_file(inst, "alice", "app", "ci/release machine.yml")
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("HTTP_STATUS"), "not on the default ref")
    assert_true(why.find("404") >= 0, why)
    var created = c.send(
        inst,
        create_check_run(
            "alice",
            "app",
            CheckRunFields(String("release"), String(SHA_A), String("in_progress"), String(""), String("https://ci.example/r/1"), String("run-1"), String(""), String("")),
        ),
    )
    assert_equal(created.status, 201)
    var check_id = created.json().get(String("id")).as_int64()
    var done = c.send(
        inst,
        update_check_run(
            "alice",
            "app",
            check_id,
            CheckRunFields(String(""), String(""), String("completed"), String("failure"), String(""), String(""), String("Release"), String("stage build failed")),
        ),
    ).json()
    assert_equal(done.get(String("status")).as_string(), String("completed"))
    assert_equal(done.get(String("conclusion")).as_string(), String("failure"))
    assert_equal(done.get(String("output")).get(String("summary")).as_string(), String("stage build failed"))
    print("  test_reads_and_writes PASS")


def test_webhook_delivery_from_fake() raises:
    var secret = String("whsec-test-only")
    var body = String('{"action":"completed","workflow_run":{"id":7}}')
    var headers = signed_delivery_headers(secret.as_bytes(), body.as_bytes(), "workflow_run", "d-1")
    verify_webhook_delivery(secret.as_bytes(), body.as_bytes(), headers)
    var tampered = String('{"action":"completed","workflow_run":{"id":7}]')
    var why = String("")
    try:
        verify_webhook_delivery(secret.as_bytes(), tampered.as_bytes(), headers)
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("WEBHOOK"))
    print("  test_webhook_delivery_from_fake PASS")


def main() raises:
    test_outside_subset_sends_nothing()
    test_pagination_reads_last_page()
    test_page_bound()
    test_link_that_does_not_advance()
    test_secondary_limit_not_hot_looped()
    test_primary_limit_per_installation()
    test_reads_and_writes()
    test_webhook_delivery_from_fake()
    print("PASS komira_github_fake client routes")
