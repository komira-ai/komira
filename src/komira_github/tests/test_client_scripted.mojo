# =============================================================================
# komira_github/tests/test_client_scripted.mojo -- GitHubAppClient over a
#   scripted transport written here: the client's own paths, measured in this
#   package (komira_github_fake's tests run the same client against a full
#   fake GitHub).
# =============================================================================
#
# `Scripted` answers each request with the next queued response and records
# what it was sent; nothing is matched or checked on its side, so every
# refusal seen here is the client's.
#
# What each test proves, and the defect it catches:
#   * test_list_all_pages: three scripted pages (next 2, next 3, none) give
#     every item in order from three requests whose targets add `page=2` and
#     `page=3` to the asked-for query; a page without the items member, an
#     items member that is not an array, a non-2xx page, a non-list route
#     and a request that names its own page are refused. Catches a walk that
#     stops before the last page and one that reads a malformed page.
#   * test_read_file: a wrapped base64 file decodes; a directory, a non-base64
#     encoding (a file over 1 MB), bad base64 and a 404 are refused.
#   * test_send_with_token: a fresh caller-held token is sent as its Bearer;
#     one with 300 s left is refused (AUTH) and not sent; an App route with
#     it is NOT_ALLOWED.
#   * test_app_401_drops_jwt: a 401 to an App route raises AUTH and the next
#     App call, one second later, carries a NEW JWT (a kept one would still
#     be fresh and be sent again).
#   * test_token_answer_status: a token mint answered 200 (not 201) or 404
#     raises HTTP_STATUS naming the status; a 401 raises AUTH.
#   * test_seams: `from_pem` reads the PEM test key; the system clock reads a
#     time after 2026-10-01; the manual clock's set and advance; a
#     response's `ok` at 199/200/299/300 and `json` refusing a non-JSON body.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_github import (
    AppCredentials,
    GitHubAppClient,
    GitHubHttpRequest,
    GitHubResponse,
    GitHubTransport,
    InstallationToken,
    ManualUnixClock,
    SystemUnixClock,
    UnixClock,
    get_authenticated_app,
    get_contents,
    get_repository,
    github_error_kind,
    list_workflow_runs,
)


comptime NOW: Int64 = 1_790_856_000
comptime TOKEN_ANSWER = '{"token":"ghs_scripted","expires_at":"2026-10-01T13:00:00Z"}'


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _resp(status: Int, body: String, link: String = String("")) -> GitHubResponse:
    var r = GitHubResponse(status, _b(body))
    if link.byte_length() > 0:
        r.add_header(String("Link"), link)
    return r^


struct Scripted(GitHubTransport, Movable, Deinitable):
    var answers: List[GitHubResponse]
    var sent: List[GitHubHttpRequest]

    def __init__(out self):
        self.answers = List[GitHubResponse]()
        self.sent = List[GitHubHttpRequest]()

    def send(mut self, req: GitHubHttpRequest) raises -> GitHubResponse:
        self.sent.append(req.copy())
        if len(self.answers) == 0:
            raise Error("Scripted: no answer queued")
        return self.answers.pop(0)


comptime Client = GitHubAppClient[Scripted, ManualUnixClock]


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _client() raises -> Client:
    return Client(Scripted(), AppCredentials(String("12345"), _key()), ManualUnixClock(NOW))


def _queue(mut c: Client, var r: GitHubResponse):
    c.transport().answers.append(r^)


def _kind(text: String) -> String:
    return github_error_kind(text)


def test_list_all_pages() raises:
    var c = _client()
    _queue(c, _resp(201, TOKEN_ANSWER))
    _queue(c, _resp(200, '{"workflow_runs":[{"id":1},{"id":2}]}', '<https://api.github.com/r/1/actions/runs?page=2>; rel="next"'))
    _queue(c, _resp(200, '{"workflow_runs":[{"id":3},{"id":4}]}', '<https://api.github.com/r/1/actions/runs?page=3>; rel="next", <https://api.github.com/r/1/actions/runs?page=3>; rel="last"'))
    _queue(c, _resp(200, '{"workflow_runs":[{"id":5}]}', '<https://api.github.com/r/1/actions/runs?page=1>; rel="first"'))
    var items = c.list_all(9, list_workflow_runs("o", "r", String(""), 2))
    var ids = String("")
    for i in range(len(items)):
        ids += String(items[i].get(String("id")).as_int64()) + String(" ")
    assert_equal(ids, String("1 2 3 4 5 "), "every page, the last included")
    var targets = String("")
    for i in range(1, len(c.transport().sent)):
        targets += c.transport().sent[i].target + String("\n")
    assert_equal(
        targets,
        String("/repos/o/r/actions/runs?per_page=2\n/repos/o/r/actions/runs?per_page=2&page=2\n/repos/o/r/actions/runs?per_page=2&page=3\n"),
    )
    var refusals = String("")
    _queue(c, _resp(200, '{"jobs":[]}'))
    try:
        _ = c.list_all(9, list_workflow_runs("o", "r"))
        refusals += "no-member "
    except e:
        refusals += _kind(String(e)) + " "
    _queue(c, _resp(200, '{"workflow_runs":{}}'))
    try:
        _ = c.list_all(9, list_workflow_runs("o", "r"))
        refusals += "not-array "
    except e:
        refusals += _kind(String(e)) + " "
    _queue(c, _resp(404, '{"message":"Not Found"}'))
    try:
        _ = c.list_all(9, list_workflow_runs("o", "r"))
        refusals += "404 "
    except e:
        refusals += _kind(String(e)) + " "
    try:
        _ = c.list_all(9, get_repository("o", "r"))
        refusals += "not-a-list "
    except e:
        refusals += _kind(String(e)) + " "
    var paged = list_workflow_runs("o", "r")
    paged.query += "&page=2"
    try:
        _ = c.list_all(9, paged)
        refusals += "own-page "
    except e:
        refusals += _kind(String(e)) + " "
    assert_equal(refusals, String("BAD_RESPONSE BAD_RESPONSE HTTP_STATUS NOT_ALLOWED BAD_INPUT "))
    print("  test_list_all_pages PASS")


def _file_answer(kind: String, encoding: String, content: String) -> String:
    return String('{"type":"') + kind + String('","encoding":"') + encoding + String('","content":"') + content + String('"}')


def test_read_file() raises:
    var c = _client()
    _queue(c, _resp(201, TOKEN_ANSWER))
    _queue(c, _resp(200, _file_answer("file", "base64", "aGVsbG8g\\nd29ybGQ=\\n")))
    var got = c.read_file(9, "o", "r", "a/b.txt", "main")
    assert_equal(String(unsafe_from_utf8=Span(got)), String("hello world"))
    assert_equal(c.transport().sent[1].target, String("/repos/o/r/contents/a/b.txt?ref=main"))
    var kinds = String("")
    _queue(c, _resp(200, _file_answer("dir", "base64", "")))
    _queue(c, _resp(200, _file_answer("file", "none", "")))
    _queue(c, _resp(200, _file_answer("file", "base64", "!!!!")))
    _queue(c, _resp(404, '{"message":"Not Found"}'))
    _queue(c, _resp(200, '{"type":"file"}'))
    for _ in range(5):
        try:
            _ = c.read_file(9, "o", "r", "a/b.txt")
            kinds += "READ "
        except e:
            kinds += _kind(String(e)) + " "
    assert_equal(kinds, String("BAD_RESPONSE BAD_RESPONSE BAD_RESPONSE HTTP_STATUS BAD_RESPONSE "))
    print("  test_read_file PASS")


def test_send_with_token() raises:
    var c = _client()
    var tok = InstallationToken(String("ghs_held"), 9, String(""), NOW + 3600)
    _queue(c, _resp(200, "{}"))
    assert_equal(c.send_with_token(tok, get_repository("o", "r")).status, 200)
    assert_equal(c.transport().sent[0].header(String("Authorization")).value(), String("Bearer ghs_held"))
    c.clock().set(NOW + 3300)
    var why = String("")
    try:
        _ = c.send_with_token(tok, get_repository("o", "r"))
    except e:
        why = String(e)
    assert_equal(_kind(why), String("AUTH"))
    try:
        _ = c.send_with_token(tok, get_authenticated_app())
    except e:
        why = String(e)
    assert_equal(_kind(why), String("NOT_ALLOWED"))
    assert_equal(len(c.transport().sent), 1, "nothing more was sent")
    print("  test_send_with_token PASS")


def test_app_401_drops_jwt() raises:
    var c = _client()
    _queue(c, _resp(200, "{}"))
    _queue(c, _resp(401, '{"message":"Bad credentials"}'))
    _queue(c, _resp(200, "{}"))
    _ = c.app_send(get_authenticated_app())
    var why = String("")
    try:
        _ = c.app_send(get_authenticated_app())
    except e:
        why = String(e)
    assert_equal(_kind(why), String("AUTH"))
    # One second on: a kept JWT would still be fresh and sent again; a
    # dropped one is minted anew with new times (the same instant would
    # mint the same bytes: PKCS#1 v1.5 signing is deterministic).
    c.clock().set(NOW + 1)
    _ = c.app_send(get_authenticated_app())
    ref sent = c.transport().sent
    var a0 = sent[0].header(String("Authorization")).value()
    var a1 = sent[1].header(String("Authorization")).value()
    var a2 = sent[2].header(String("Authorization")).value()
    assert_equal(a0, a1, "the cached JWT until it is refused")
    assert_true(a1 != a2, "a new JWT after a 401")
    print("  test_app_401_drops_jwt PASS")


def test_token_answer_status() raises:
    var kinds = String("")
    for status in [200, 404, 401]:
        var c = _client()
        _queue(c, _resp(status, TOKEN_ANSWER))
        try:
            _ = c.installation_token(9)
            kinds += "MINTED "
        except e:
            kinds += _kind(String(e)) + String(":") + String(String(e).find(String(status)) >= 0) + " "
    assert_equal(kinds, String("HTTP_STATUS:True HTTP_STATUS:True AUTH:True "))
    print("  test_token_answer_status PASS")


def test_seams() raises:
    var pem = Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    var creds = AppCredentials.from_pem(String("12345"), pem)
    assert_equal(creds.issuer, String("12345"))
    var sys = SystemUnixClock()
    assert_true(sys.now_unix_seconds() > NOW, "the system clock is after 2026-10-01")
    var m = ManualUnixClock(10)
    m.advance(5)
    assert_equal(m.now_unix_seconds(), 15)
    m.set(3)
    assert_equal(m.now_unix_seconds(), 3)
    var oks = String("")
    for status in [199, 200, 299, 300]:
        oks += String(_resp(status, "{}").ok()) + " "
    assert_equal(oks, String("False True True False "))
    var why = String("")
    try:
        _ = _resp(200, "not json").json()
    except e:
        why = String(e)
    assert_equal(_kind(why), String("BAD_RESPONSE"))
    var c = _client()
    assert_equal(c.latch().secondary_streak, 0)
    print("  test_seams PASS")


def main() raises:
    test_list_all_pages()
    test_read_file()
    test_send_with_token()
    test_app_401_drops_jwt()
    test_token_answer_status()
    test_seams()
    print("PASS komira_github scripted client")
