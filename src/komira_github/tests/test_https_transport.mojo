# =============================================================================
# komira_github/tests/test_https_transport.mojo -- the komira_http_client
#   transport on the wire, over komira_http_core's ScriptedConnector (no
#   socket; the URL is 127.0.0.1, so no DNS).
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_app_request_on_the_wire: `GitHubAppClient.app_send(GET /app)`
#     through `HttpsGitHubTransport` writes the request line `GET /app
#     HTTP/1.1` and EXACTLY the header set accept, authorization,
#     content-length (komira_http_client writes 0 for a GET), host,
#     user-agent, x-github-api-version (no second user-agent from
#     komira_http_client), with GitHub's media type, API version and a
#     three-segment Bearer JWT; the answer's status, headers and body come
#     back as received. Catches a header dropped or duplicated, the JWT
#     sent without `Bearer `, a lost header on the way back.
#   * test_post_body_on_the_wire: an installation-token request carries the
#     one-repository body byte for byte and `content-type:
#     application/json`; a refused route (`PUT .../environments/...`) writes
#     nothing to the connector at all.
#   * test_endpoint_urls: the public endpoint, an Enterprise Server's
#     `/api/v3` root and the query split; refused: an Enterprise host with
#     `/`, `@`, `:` or upper case, port 0, and a plaintext endpoint for any
#     host but 127.0.0.1 however it was built.
# =============================================================================

from std.memory import ArcPointer
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_github import (
    AppCredentials,
    GitHubAppClient,
    GitHubEndpoint,
    GitHubRequest,
    HttpsGitHubTransport,
    ManualUnixClock,
    create_repo_contents_read_token,
    get_authenticated_app,
    github_error_kind,
)


comptime TIMEOUT_US: Int = 5_000_000
comptime NOW: Int64 = 1_790_856_000
comptime Client = GitHubAppClient[HttpsGitHubTransport[ScriptedConnector], ManualUnixClock]


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _http(status_line: String, extra_headers: String, body: String) -> List[UInt8]:
    var http = String("HTTP/1.1 ") + status_line + String("\r\nContent-Length: ")
    http += String(len(body.as_bytes()))
    http += String("\r\n") + extra_headers + String("Connection: close\r\n\r\n")
    http += body
    var out = List[UInt8]()
    out.extend(Span(http.as_bytes()))
    return out^


def _client(var script: List[UInt8], shared: ArcPointer[List[UInt8]]) raises -> Client:
    var conn = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script_with_capture(script^, shared)
    )
    var http = HttpClient[ScriptedConnector].with_request_timeout_us(conn^, TIMEOUT_US)
    var transport = HttpsGitHubTransport[ScriptedConnector](http^, GitHubEndpoint.loopback_plaintext(8080))
    return Client(transport^, AppCredentials(String("12345"), _key()), ManualUnixClock(NOW))


def _head_lines(req: String) -> List[String]:
    var out = List[String]()
    var b = req.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            var end = i
            if end > start and b[end - 1] == UInt8(ord("\r")):
                end -= 1
            if end == start:
                break
            out.append(String(unsafe_from_utf8=b[start:end]))
            start = i + 1
    return out^


def _header_names(req: String) raises -> String:
    var lines = _head_lines(req)
    var names = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon <= 0:
            raise Error("a head line with no name")
        names.append(String(lines[i][byte=0:colon]).lower())
    sort(names)
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += names[i]
    return out^


def _header(req: String, name: String) raises -> String:
    var lines = _head_lines(req)
    var found = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon > 0 and String(lines[i][byte=0:colon]).lower() == name:
            found.append(String(String(lines[i][byte = colon + 1 :]).strip()))
    if len(found) != 1:
        raise Error("header " + name + " appears " + String(len(found)) + " times")
    return found[0].copy()


def _body_of(req: String) -> String:
    var at = req.find("\r\n\r\n")
    if at < 0:
        return String("")
    return String(req[byte = at + 4 :])


def test_app_request_on_the_wire() raises:
    var cap = ArcPointer[List[UInt8]](List[UInt8]())
    var script = _http(
        String("200 OK"),
        String("Content-Type: application/json\r\nX-RateLimit-Remaining: 4999\r\n"),
        String('{"id":1,"slug":"fake-app"}'),
    )
    var client = _client(script^, cap)
    var resp = client.app_send(get_authenticated_app())
    var req = String(unsafe_from_utf8=Span(cap[]))
    var lines = _head_lines(req)
    assert_equal(lines[0], String("GET /app HTTP/1.1"))
    assert_equal(
        _header_names(req), String("accept,authorization,content-length,host,user-agent,x-github-api-version"), req
    )
    assert_equal(_header(req, "accept"), String("application/vnd.github+json"))
    assert_equal(_header(req, "x-github-api-version"), String("2022-11-28"))
    assert_equal(_header(req, "user-agent"), String("komira-github"))
    var auth = _header(req, "authorization")
    assert_true(auth.startswith("Bearer "), "Bearer")
    var dots = 0
    var ab = auth.as_bytes()
    for i in range(len(ab)):
        if ab[i] == UInt8(ord(".")):
            dots += 1
    assert_equal(dots, 2, "a JWT")
    assert_equal(resp.status, 200)
    assert_equal(resp.header(String("x-ratelimit-remaining")).value(), String("4999"))
    assert_equal(String(unsafe_from_utf8=Span(resp.body)), String('{"id":1,"slug":"fake-app"}'))
    print("  test_app_request_on_the_wire PASS")


def test_post_body_on_the_wire() raises:
    var cap = ArcPointer[List[UInt8]](List[UInt8]())
    var script = _http(
        String("201 Created"),
        String("Content-Type: application/json\r\n"),
        String('{"token":"ghs_x","expires_at":"2026-10-01T13:00:00Z"}'),
    )
    var client = _client(script^, cap)
    var tok = client.repo_contents_read_token(42, 7)
    assert_equal(tok.token, String("ghs_x"))
    assert_equal(tok.expires_at, NOW + 3600)
    var req = String(unsafe_from_utf8=Span(cap[]))
    assert_equal(_head_lines(req)[0], String("POST /app/installations/42/access_tokens HTTP/1.1"))
    assert_equal(_header(req, "content-type"), String("application/json"))
    assert_equal(
        _body_of(req), String('{"repository_ids":[7],"permissions":{"contents":"read"}}')
    )

    var cap2 = ArcPointer[List[UInt8]](List[UInt8]())
    var client2 = _client(_http(String("200 OK"), String(""), String("{}")), cap2)
    var why = String("")
    try:
        _ = client2.send(42, GitHubRequest(String("PUT"), String("/repos/o/r/environments/prod")))
    except e:
        why = String(e)
    assert_equal(github_error_kind(why), String("NOT_ALLOWED"))
    assert_equal(len(cap2[]), 0, "nothing was written")
    print("  test_post_body_on_the_wire PASS")


def _url(e: GitHubEndpoint, target: String) -> String:
    try:
        var u = e.url(target)
        return u.scheme + String("://") + u.host + String(":") + String(Int(u.port)) + u.path + String("?") + u.query
    except err:
        return String("REFUSED ") + String(err)


def _endpoint_refused(host: String, port: UInt16) -> Bool:
    try:
        _ = GitHubEndpoint.enterprise(host, port)
    except:
        return True
    return False


def test_endpoint_urls() raises:
    assert_equal(_url(GitHubEndpoint.public(), "/repos/o/r"), String("https://api.github.com:443/repos/o/r?"))
    assert_equal(
        _url(GitHubEndpoint.enterprise(String("ghe.example.com"), 8443), "/repos/o/r/actions/runs?per_page=1&page=2"),
        String("https://ghe.example.com:8443/api/v3/repos/o/r/actions/runs?per_page=1&page=2"),
    )
    assert_equal(_url(GitHubEndpoint.loopback_plaintext(9), "/app"), String("http://127.0.0.1:9/app?"))
    var forged = GitHubEndpoint(False, String("api.github.com"), 80, String(""))
    assert_true(_url(forged, "/app").find("only for 127.0.0.1") >= 0, "plaintext elsewhere refused")
    var refused = String("")
    if not _endpoint_refused(String("ghe.example.com/x"), 443):
        refused += "slash "
    if not _endpoint_refused(String("user@ghe.example.com"), 443):
        refused += "at "
    if not _endpoint_refused(String("ghe.example.com:1"), 443):
        refused += "colon "
    if not _endpoint_refused(String("GHE.example.com"), 443):
        refused += "upper "
    if not _endpoint_refused(String(""), 443):
        refused += "empty "
    if not _endpoint_refused(String("ghe.example.com"), 0):
        refused += "port0 "
    assert_equal(refused, String(""), "bad Enterprise endpoints are refused")
    print("  test_endpoint_urls PASS")


def main() raises:
    test_app_request_on_the_wire()
    test_post_body_on_the_wire()
    test_endpoint_urls()
    print("PASS komira_github https transport")
