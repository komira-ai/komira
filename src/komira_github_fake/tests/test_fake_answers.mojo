# =============================================================================
# komira_github_fake/tests/test_fake_answers.mojo -- the fake's own answers
#   to requests a correct client never makes: GitHub's error statuses.
# =============================================================================
#
# Requests go straight to `FakeGitHub.send` with a real App JWT or a real
# installation token, so each answer is the fake's handling of a bad body,
# an unknown object or a set-up mistake.
#
# What each test proves, and the defect it catches:
#   * test_token_request_bodies: the access-token body rules: malformed JSON
#     and a non-object (400); `repository_ids` not an array, a non-integer
#     id, an id outside the installation (LAST in the list), `repositories`
#     not an array, a non-string or unknown name (LAST), `permissions` not
#     an object, a non-string level, a permission the installation lacks,
#     and an unknown member (422); an unknown installation (404). A body
#     naming `repositories` scopes the token to them. Catches a fake that
#     grants what GitHub would refuse, so a client bug would pass against it.
#   * test_app_lookups: an installation and a repository's installation by
#     id and name (200), unknown ones (404), a suspended installation's
#     `suspended_at`, and a request outside the subset (404, counted).
#   * test_check_run_rules: the fake refuses a check run GitHub refuses
#     (bad JSON, missing name, bad sha, unknown status or conclusion,
#     completed without a conclusion, a member of the wrong type, an output
#     that is not an object) and 404s an update of an unknown check run.
#   * test_unknown_objects: unknown runs, jobs and artifacts answer 404.
#   * test_other_repository_objects: app1 and app2 share one installation;
#     app2's run, job, artifact and check run all exist (each answers 200
#     through app2's path), yet asked by id through app1's path every route
#     that looks one up answers 404, with a token for app1 only and with one
#     for both: get run, get run attempt, list jobs, list jobs of an
#     attempt, list artifacts, get job, get artifact and update check run
#     (which leaves app2's check run unchanged). Listing app1's runs leaves
#     app2's run out, and `add_job`/`add_artifact` refuse app2's run under
#     app1. Catches any of those lookups matching on the id alone, which
#     would hand a token another repository's object.
#   * test_setup_refusals: each set-up verb refuses an unknown or invalid
#     object; `advance` moves the fake's clock.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_github import AppCredentials, GitHubHttpRequest, GitHubResponse, mint_app_jwt

from komira_github_fake import FakeGitHub, app_public_key_from_pkcs8, default_app_permissions


comptime NOW: Int64 = 1_790_856_000
comptime SHA = "0123456789abcdef0123456789abcdef01234567"


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _ids(a: Int64, b: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    out.append(b)
    return out^


struct World(Movable):
    var fake: FakeGitHub
    var jwt: String
    var inst: Int64
    var a: Int64
    var b: Int64
    var c: Int64

    def __init__(out self, var fake: FakeGitHub, var jwt: String, inst: Int64, a: Int64, b: Int64, c: Int64):
        self.fake = fake^
        self.jwt = jwt^
        self.inst = inst
        self.a = a
        self.b = b
        self.c = c


def _world() raises -> World:
    var key = _key()
    var fake = FakeGitHub(String("12345"), app_public_key_from_pkcs8(key), NOW, default_app_permissions())
    var a = fake.state.add_repo("alice", "app1", _one("alice"))
    var b = fake.state.add_repo("alice", "app2", _one("alice"))
    var c = fake.state.add_repo("alice", "other", _one("alice"))
    var perms = List[String]()
    perms.append(String("metadata:read"))
    perms.append(String("contents:read"))
    perms.append(String("actions:read"))
    perms.append(String("checks:write"))
    var inst = fake.state.install("alice", "alice", _ids(a, b), perms^)
    var jwt = mint_app_jwt(AppCredentials(String("12345"), key^), NOW).token
    return World(fake^, jwt^, inst, a, b, c)


def _send(mut w: World, method: String, target: String, bearer: String, body: String) raises -> GitHubResponse:
    var req = GitHubHttpRequest(method, target)
    req.add_header(String("Authorization"), String("Bearer ") + bearer)
    req.body = _b(body)
    return w.fake.send(req)


def _app(mut w: World, method: String, target: String, body: String) raises -> GitHubResponse:
    var jwt = w.jwt.copy()
    return _send(w, method, target, jwt, body)


def _mint(mut w: World, body: String) raises -> GitHubResponse:
    return _app(w, "POST", String("/app/installations/") + String(w.inst) + String("/access_tokens"), body)


def _token(mut w: World) raises -> String:
    var r = _mint(w, "")
    return r.json().get(String("token")).as_string()


def test_token_request_bodies() raises:
    var w = _world()
    var cases = List[String]()
    var want = List[Int]()
    cases.append("{")
    want.append(400)
    cases.append("[1]")
    want.append(400)
    cases.append('{"repository_ids":5}')
    want.append(422)
    cases.append('{"repository_ids":["5"]}')
    want.append(422)
    cases.append(String('{"repository_ids":[') + String(w.a) + String(",") + String(w.c) + String("]}"))
    want.append(422)
    cases.append('{"repositories":"app1"}')
    want.append(422)
    cases.append('{"repositories":[7]}')
    want.append(422)
    cases.append('{"repositories":["app1","other"]}')
    want.append(422)
    cases.append('{"permissions":["contents"]}')
    want.append(422)
    cases.append('{"permissions":{"contents":1}}')
    want.append(422)
    cases.append('{"permissions":{"contents":"read","actions":"write"}}')
    want.append(422)
    cases.append('{"repository_ids":[],"extra":true}')
    want.append(422)
    var wrong = String("")
    for i in range(len(cases)):
        var got = _mint(w, cases[i]).status
        if got != want[i]:
            wrong += String("[") + String(i) + String("]=") + String(got) + String(" ")
    assert_equal(wrong, String(""), "each body gets GitHub's status")
    var unknown = _app(w, "POST", "/app/installations/77/access_tokens", "")
    assert_equal(unknown.status, 404)
    var named = _mint(w, '{"repositories":["app2"]}')
    assert_equal(named.status, 201)
    var tok = named.json().get(String("token")).as_string()
    assert_equal(_send(w, "GET", "/repos/alice/app2", tok, "").status, 200)
    assert_equal(_send(w, "GET", "/repos/alice/app1", tok, "").status, 404, "scoped to the named repository")
    print("  test_token_request_bodies PASS")


def test_app_lookups() raises:
    var w = _world()
    var inst = _app(w, "GET", String("/app/installations/") + String(w.inst), "")
    assert_equal(inst.status, 200)
    assert_equal(inst.json().get(String("account")).get(String("login")).as_string(), String("alice"))
    assert_true(inst.json().get(String("suspended_at")).is_null())
    assert_equal(_app(w, "GET", "/app/installations/77", "").status, 404)
    assert_equal(_app(w, "GET", "/repos/alice/app2/installation", "").status, 200)
    assert_equal(_app(w, "GET", "/repos/alice/other/installation", "").status, 404, "not installed")
    assert_equal(_app(w, "GET", "/repos/alice/nope/installation", "").status, 404)
    assert_equal(_app(w, "GET", "/app", "").json().get(String("client_id")).as_string(), String("12345"))
    w.fake.state.suspend(w.inst)
    assert_true(_app(w, "GET", String("/app/installations/") + String(w.inst), "").json().get(String("suspended_at")).is_string())
    assert_equal(_app(w, "PUT", "/repos/alice/app1/environments/prod", "").status, 404)
    assert_equal(w.fake.unrouted_requests, 1)
    print("  test_app_lookups PASS")


def test_check_run_rules() raises:
    var w = _world()
    var tok = _token(w)
    var bodies = List[String]()
    var want = List[Int]()
    bodies.append("{")
    want.append(400)
    bodies.append("[]")
    want.append(400)
    bodies.append(String('{"head_sha":"') + SHA + String('"}'))
    want.append(422)
    bodies.append('{"name":"b","head_sha":"abc"}')
    want.append(422)
    bodies.append(String('{"name":"b","head_sha":"') + SHA + String('","status":"done"}'))
    want.append(422)
    bodies.append(String('{"name":"b","head_sha":"') + SHA + String('","conclusion":"passed"}'))
    want.append(422)
    bodies.append(String('{"name":"b","head_sha":"') + SHA + String('","status":"completed"}'))
    want.append(422)
    bodies.append(String('{"name":7,"head_sha":"') + SHA + String('"}'))
    want.append(422)
    bodies.append(String('{"name":"b","head_sha":"') + SHA + String('","output":[]}'))
    want.append(422)
    bodies.append(String('{"name":"b","head_sha":"') + SHA + String('","conclusion":"success","details_url":null}'))
    want.append(201)
    var wrong = String("")
    for i in range(len(bodies)):
        var got = _send(w, "POST", "/repos/alice/app1/check-runs", tok, bodies[i]).status
        if got != want[i]:
            wrong += String("[") + String(i) + String("]=") + String(got) + String(" ")
    assert_equal(wrong, String(""), "each body gets GitHub's status")
    assert_equal(_send(w, "PATCH", "/repos/alice/app1/check-runs/999999", tok, '{"status":"in_progress"}').status, 404)
    print("  test_check_run_rules PASS")


def test_unknown_objects() raises:
    var w = _world()
    var tok = _token(w)
    var targets = List[String]()
    targets.append("/repos/alice/app1/actions/runs/999999")
    targets.append("/repos/alice/app1/actions/runs/999999/attempts/1")
    targets.append("/repos/alice/app1/actions/runs/999999/jobs")
    targets.append("/repos/alice/app1/actions/runs/999999/attempts/1/jobs")
    targets.append("/repos/alice/app1/actions/runs/999999/artifacts")
    targets.append("/repos/alice/app1/actions/jobs/999999")
    targets.append("/repos/alice/app1/actions/artifacts/999999")
    targets.append("/repos/alice/app1/contents/missing.txt")
    targets.append("/repos/alice/nope")
    var wrong = String("")
    for i in range(len(targets)):
        var got = _send(w, "GET", targets[i], tok, "").status
        if got != 404:
            wrong += targets[i] + String("=") + String(got) + String(" ")
    assert_equal(wrong, String(""), "unknown objects are 404")
    assert_equal(_send(w, "GET", "/installation/repositories", "ghs_unknown", "").status, 401)
    print("  test_unknown_objects PASS")


def test_other_repository_objects() raises:
    var w = _world()
    var run_a = w.fake.state.add_run(w.a, String(SHA), "completed", "success")
    var run_b = w.fake.state.add_run(w.b, String(SHA), "completed", "success")
    var job_b = w.fake.state.add_job(w.b, run_b, 1, "build", "completed", "success")
    var art_b = w.fake.state.add_artifact(w.b, run_b, "out", 10)
    var both = _token(w)
    var scoped = _mint(w, String('{"repository_ids":[') + String(w.a) + String("]}"))
    assert_equal(scoped.status, 201)
    var one = scoped.json().get(String("token")).as_string()
    var created = _send(w, "POST", "/repos/alice/app2/check-runs", both, String('{"name":"b","head_sha":"') + SHA + String('"}'))
    assert_equal(created.status, 201)
    var check_b = created.json().get(String("id")).as_int64()
    assert_equal(_send(w, "GET", "/repos/alice/app2", one, "").status, 404, "the scoped token cannot see app2")
    var tails = List[String]()
    tails.append(String("/actions/runs/") + String(run_b))
    tails.append(String("/actions/runs/") + String(run_b) + String("/attempts/1"))
    tails.append(String("/actions/runs/") + String(run_b) + String("/jobs"))
    tails.append(String("/actions/runs/") + String(run_b) + String("/attempts/1/jobs"))
    tails.append(String("/actions/runs/") + String(run_b) + String("/artifacts"))
    tails.append(String("/actions/jobs/") + String(job_b))
    tails.append(String("/actions/artifacts/") + String(art_b))
    var patch = String('{"status":"in_progress"}')
    var check_tail = String("/check-runs/") + String(check_b)
    var tokens = List[String]()
    tokens.append(one.copy())
    tokens.append(both.copy())
    var wrong = String("")
    for t in range(len(tokens)):
        for i in range(len(tails)):
            var got = _send(w, "GET", String("/repos/alice/app1") + tails[i], tokens[t], "").status
            if got != 404:
                wrong += String("[") + String(t) + String("]") + tails[i] + String("=") + String(got) + String(" ")
        var upd = _send(w, "PATCH", String("/repos/alice/app1") + check_tail, tokens[t], patch).status
        if upd != 404:
            wrong += String("[") + String(t) + String("]") + check_tail + String("=") + String(upd) + String(" ")
    assert_equal(wrong, String(""), "app2's objects are 404 through app1's path")
    ref cr = w.fake.state.check_runs[len(w.fake.state.check_runs) - 1]
    assert_equal(cr.id, check_b)
    assert_equal(cr.status, String("queued"), "a refused update changes nothing")
    var listed = _send(w, "GET", "/repos/alice/app1/actions/runs", both, "").json()
    assert_equal(listed.get(String("total_count")).as_int64(), 1, "app1's runs only")
    assert_equal(listed.get(String("workflow_runs")).element_at(0).get(String("id")).as_int64(), run_a)
    var control = String("")
    for i in range(len(tails)):
        var got = _send(w, "GET", String("/repos/alice/app2") + tails[i], both, "").status
        if got != 200:
            control += tails[i] + String("=") + String(got) + String(" ")
    var upd = _send(w, "PATCH", String("/repos/alice/app2") + check_tail, both, patch).status
    if upd != 200:
        control += check_tail + String("=") + String(upd)
    assert_equal(control, String(""), "each object exists through app2's path")
    var refused = String("")
    try:
        _ = w.fake.state.add_job(w.a, run_b, 1, "j", "queued", "")
        refused += "job "
    except:
        pass
    try:
        _ = w.fake.state.add_artifact(w.a, run_b, "x", 1)
        refused += "artifact "
    except:
        pass
    assert_equal(refused, String(""), "set-up refuses app2's run under app1")
    print("  test_other_repository_objects PASS")


def test_setup_refusals() raises:
    var w = _world()
    var refused = String("")
    try:
        _ = w.fake.state.add_repo("alice", "app1", _one("alice"))
        refused += "duplicate "
    except:
        pass
    try:
        _ = w.fake.state.add_repo("alice", "..", _one("alice"))
        refused += "bad-name "
    except:
        pass
    try:
        w.fake.state.set_collaborator(999999, "bob", "read")
        refused += "collaborator "
    except:
        pass
    try:
        w.fake.state.put_file(999999, "main", "a", _b("x"))
        refused += "file "
    except:
        pass
    try:
        w.fake.state.suspend(999999)
        refused += "suspend "
    except:
        pass
    try:
        _ = w.fake.state.add_run(999999, String(SHA), "queued", "")
        refused += "run "
    except:
        pass
    try:
        _ = w.fake.state.add_job(w.a, 999999, 1, "j", "queued", "")
        refused += "job "
    except:
        pass
    try:
        _ = w.fake.state.add_artifact(w.a, 999999, "x", 1)
        refused += "artifact "
    except:
        pass
    assert_equal(refused, String(""), "every set-up verb refuses an unknown object")
    w.fake.advance(30)
    assert_equal(w.fake.state.now, NOW + 30)
    print("  test_setup_refusals PASS")


def main() raises:
    test_token_request_bodies()
    test_app_lookups()
    test_check_run_rules()
    test_unknown_objects()
    test_other_repository_objects()
    test_setup_refusals()
    print("PASS komira_github_fake answers")
