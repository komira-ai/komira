# =============================================================================
# gcp_fake.mojo -- a stateful GCP Secret Manager v1 over REST/JSON
# =============================================================================
#
# `FakeSecretManager` is a komira_http_server `RequestDispatcher` answering
# the six methods the generated client sends, at their REST paths
# (google/cloud/secretmanager/v1/service.proto, global and regional
# bindings), against the state in gcp_store.mojo:
#
#   POST   /v1/{parent}/secrets?secretId=...       CreateSecret
#   POST   /v1/{name}:addVersion                   AddSecretVersion
#   GET    /v1/{name}/versions                     ListSecretVersions
#   GET    /v1/{name}/versions/{v}:access          AccessSecretVersion
#   GET    /v1/{parent}/secrets                    ListSecrets
#   DELETE /v1/{name}                              DeleteSecret
#
# where `{parent}` is `projects/{p}` or `projects/{p}/locations/{l}`.
#
# Checked on every request, in this order:
#   1. `Authorization: Bearer <token>`: none or an empty token is 401
#      UNAUTHENTICATED (the service's "missing required authentication
#      credential"), another token than the fake's is 401 too ("invalid
#      authentication credentials").
#   2. The path: an unknown one is 404 NOT_FOUND, as the front end
#      answers, whichever host it arrived at.
#   3. The endpoint: a global resource must arrive at the global host and a
#      regional one at its location's host (`Host`, port dropped). A
#      resource sent to the other endpoint is refused 400 INVALID_ARGUMENT
#      (the code is this fake's choice; it serves neither there).
#   4. The method: 404 NOT_FOUND for a missing secret or version, 409
#      ALREADY_EXISTS for a secret id taken in that location, 400
#      INVALID_ARGUMENT for a global create without `replication`, a
#      regional one with it, a payload that is not base64, or a
#      `dataCrc32c` that is not the payload's CRC32C. Lists page by
#      `pageSize` and an opaque `pageToken`; ListSecretVersions answers the
#      newest version first.
#
# Errors are the google.rpc.Status envelope
# `{"error":{"code","message","status"}}`. As a worst-case service, a 4xx
# answered to a request that carried a payload repeats that payload, as
# text, in `error.message`: a client that put the body into its error text
# would leak it, and the custody checks look for exactly that.
# `error_bodies` keeps every error body sent, so a test can see the payload
# was on the wire.
#
# What the fake records: `log`, one line per request (`<verb> <path>[?query]
# @<host> <status>[ <STATUS>]`: no field a payload could be in, the query
# holding only ids and page tokens), and `authorizations`, the
# Authorization header of each request ("" when it had none).
#
# Threading: only the duet's server thread touches the fake while the duet
# runs; the test reads it after the join.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_encoding import base64_decode
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_json import JsonValue, parse_json_bytes

from .gcp_store import (
    GCP_PROJECT_ID,
    GCP_PROJECT_NUMBER,
    GcpSecret,
    GcpStore,
    GcpVersion,
    access_json,
    collection_name,
    crc32c,
    secret_json,
    secret_name,
    version_json,
)

comptime MISSING_CREDENTIAL_MESSAGE = (
    "Request is missing required authentication credential. Expected OAuth 2"
    " access token, login cookie or other valid authentication credential."
)
comptime INVALID_CREDENTIAL_MESSAGE = (
    "Request had invalid authentication credentials. Expected OAuth 2 access"
    " token, login cookie or other valid authentication credential."
)


struct _Answer(Movable):
    var status: Int
    var code: String
    var body: String
    # `error.message`, "" for a 200.
    var message: String

    def __init__(out self, status: Int, var code: String, var body: String, var message: String):
        self.status = status
        self.code = code^
        self.body = body^
        self.message = message^


def _ok(v: JsonValue) -> _Answer:
    return _Answer(200, String(""), v.serialize(), String(""))


def _error(status: Int, code: String, message: String) raises -> _Answer:
    var e = JsonValue.empty_object()
    e.set_member(String("code"), JsonValue.from_i64(Int64(status)))
    e.set_member(String("message"), JsonValue.from_string(message.copy()))
    e.set_member(String("status"), JsonValue.from_string(code.copy()))
    var o = JsonValue.empty_object()
    o.set_member(String("error"), e^)
    return _Answer(status, code.copy(), o.serialize(), message.copy())


def _query_param(query: String, key: String) -> String:
    """The value of `key` in `query` ("" when absent). The fake's page
    tokens and the tests' ids need no percent-decoding."""
    var parts = query.split("&")
    for i in range(len(parts)):
        var kv = String(parts[i])
        var eq = kv.find("=")
        if eq > 0 and String(kv[byte=0:eq]) == key:
            return String(kv[byte = eq + 1 : kv.byte_length()])
    return String("")


def _host_only(host: String) -> String:
    var colon = host.find(":")
    if colon < 0:
        return host.copy()
    return String(host[byte=0:colon])


struct _Route(Copyable, Movable):
    """A request path, parsed: the location ("" global), the secret id
    ("" for the secrets collection), its `:verb`, and the version
    segments."""

    var ok: Bool
    var location: String
    var secret_id: String
    var verb: String
    # "versions" for the versions collection or a version, "" otherwise.
    var versions: String
    var version: String

    def __init__(out self):
        self.ok = False
        self.location = String("")
        self.secret_id = String("")
        self.verb = String("")
        self.versions = String("")
        self.version = String("")


def _split_verb(seg: String, mut verb: String) -> String:
    var colon = seg.find(":")
    if colon < 0:
        return seg.copy()
    verb = String(seg[byte = colon + 1 : seg.byte_length()])
    return String(seg[byte=0:colon])


def parse_route(path: String) -> _Route:
    """`/v1/projects/{p}[/locations/{l}]/secrets[/{s}[:verb][/versions[/{v}[:verb]]]]`."""
    var r = _Route()
    if not path.startswith("/v1/"):
        return r^
    var rest = String(path[byte=4 : path.byte_length()])
    var parts = rest.split("/")
    var segs = List[String]()
    for k in range(len(parts)):
        segs.append(String(parts[k]))
    var n = len(segs)
    if n < 3 or segs[0] != "projects":
        return r^
    if segs[1] != GCP_PROJECT_ID and segs[1] != GCP_PROJECT_NUMBER:
        return r^
    var i = 2
    if segs[i] == "locations":
        if n < 5:
            return r^
        r.location = String(segs[3])
        i = 4
    if segs[i] != "secrets":
        return r^
    i += 1
    if i == n:
        r.ok = True
        return r^
    r.secret_id = _split_verb(String(segs[i]), r.verb)
    i += 1
    if i == n:
        r.ok = r.secret_id.byte_length() > 0
        return r^
    if r.verb.byte_length() > 0 or segs[i] != "versions":
        return r^
    r.versions = String("versions")
    i += 1
    if i == n:
        r.ok = True
        return r^
    r.version = _split_verb(String(segs[i]), r.verb)
    r.ok = i + 1 == n and r.version.byte_length() > 0
    return r^


def _page(total: Int, query: String) raises -> Tuple[Int, Int]:
    """The `[start, end)` of the page `query` asks for, out of `total`."""
    var start = 0
    var token = _query_param(query, String("pageToken"))
    if token.byte_length() > 0:
        if not token.startswith("page-"):
            raise Error("bad page token")
        start = Int(atol(String(token[byte=5 : token.byte_length()])))
    var size_text = _query_param(query, String("pageSize"))
    var end = total
    if size_text.byte_length() > 0:
        var size = Int(atol(size_text))
        if size > 0 and start + size < total:
            end = start + size
    return (start, end)


struct FakeSecretManager(RequestDispatcher):
    var store: GcpStore
    var token: String
    var global_host: String
    var region: String
    var regional_host: String
    var log: List[String]
    var authorizations: List[String]
    var error_bodies: List[String]
    # Each error answer's `error.message` byte count, in order.
    var error_message_bytes: List[Int]

    def __init__(
        out self,
        var token: String,
        var global_host: String,
        var region: String,
        var regional_host: String,
    ):
        self.store = GcpStore()
        self.token = token^
        self.global_host = global_host^
        self.region = region^
        self.regional_host = regional_host^
        self.log = List[String]()
        self.authorizations = List[String]()
        self.error_bodies = List[String]()
        self.error_message_bytes = List[Int]()

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        return self.handle(req^)

    def handle(mut self, var req: HttpRequest) raises -> HttpResponse:
        """The answer to one request, recorded in `log`."""
        var auth = req.headers.get(String("authorization")).or_else(String(""))
        self.authorizations.append(auth.copy())
        var host = _host_only(req.headers.get(String("host")).or_else(String("")))
        # The payload a request carried, as text, for the worst-case echo.
        var payload_text = String("")
        var body_json = JsonValue()
        var parsed = False
        if len(req.body) > 0:
            try:
                body_json = parse_json_bytes(req.body)
                parsed = body_json.is_object()
                if parsed and body_json.has(String("payload")):
                    var p = body_json.get(String("payload"))
                    if p.has(String("data")):
                        var raw = base64_decode(p.get(String("data")).as_string())
                        payload_text = String(unsafe_from_utf8=Span(raw))
            except:
                pass
        var answer = self._answer(req, auth, host, parsed, body_json)
        var target = String(req.path)
        if req.query_string.byte_length() > 0:
            target += String("?") + req.query_string
        var line = (
            req.method.name() + " " + target + " @" + host + " " + String(answer.status)
        )
        if answer.code.byte_length() > 0:
            line += String(" ") + answer.code
        self.log.append(line^)
        var body = answer.body.copy()
        if answer.status != 200:
            var message = answer.message.copy()
            if payload_text.byte_length() > 0 and answer.status < 500:
                message += String(" payload: ") + payload_text
                body = _error(answer.status, answer.code, message).body.copy()
            self.error_bodies.append(body.copy())
            self.error_message_bytes.append(message.byte_length())
        var resp = HttpResponse(Int32(answer.status))
        resp.headers[String("content-type")] = String("application/json; charset=UTF-8")
        resp.headers[String("content-length")] = String(body.byte_length())
        var bytes = List[UInt8]()
        bytes.extend(Span(body.as_bytes()))
        resp.body = bytes^
        return resp^

    def _answer(
        mut self,
        req: HttpRequest,
        auth: String,
        host: String,
        parsed: Bool,
        body: JsonValue,
    ) raises -> _Answer:
        if not auth.startswith("Bearer ") or auth.byte_length() == 7:
            return _error(401, String("UNAUTHENTICATED"), String(MISSING_CREDENTIAL_MESSAGE))
        if String(auth[byte=7 : auth.byte_length()]) != self.token:
            return _error(401, String("UNAUTHENTICATED"), String(INVALID_CREDENTIAL_MESSAGE))
        var r = parse_route(req.path)
        if not r.ok:
            return _error(
                404, String("NOT_FOUND"), String("The requested URL was not found on this server.")
            )
        var want_host = self.global_host.copy()
        if r.location.byte_length() > 0:
            want_host = self.regional_host.copy() if r.location == self.region else String("")
        if host != want_host:
            return _error(
                400,
                String("INVALID_ARGUMENT"),
                String("The resource ") + collection_name(r.location)
                + " is not served at this endpoint.",
            )
        var m = req.method
        try:
            if r.secret_id.byte_length() == 0:
                if m == HttpMethod.post():
                    return self._create_secret(r, req.query_string, parsed, body)
                if m == HttpMethod.get():
                    return self._list_secrets(r, req.query_string)
            elif r.versions.byte_length() == 0:
                if r.verb == "addVersion" and m == HttpMethod.post():
                    return self._add_version(r, parsed, body)
                if r.verb.byte_length() == 0 and m == HttpMethod.delete():
                    return self._delete_secret(r)
            elif r.version.byte_length() == 0:
                if m == HttpMethod.get():
                    return self._list_versions(r, req.query_string)
            elif r.verb == "access" and m == HttpMethod.get():
                return self._access(r)
        except:
            return _error(400, String("INVALID_ARGUMENT"), String("Invalid JSON payload received."))
        return _error(
            404, String("NOT_FOUND"), String("The requested URL was not found on this server.")
        )

    def _secret_missing(self, r: _Route) raises -> _Answer:
        return _error(
            404,
            String("NOT_FOUND"),
            String("Secret [") + secret_name(r.location, r.secret_id) + "] not found.",
        )

    def _create_secret(
        mut self, r: _Route, query: String, parsed: Bool, body: JsonValue
    ) raises -> _Answer:
        var secret_id = _query_param(query, String("secretId"))
        if secret_id.byte_length() == 0 or not parsed:
            return _error(400, String("INVALID_ARGUMENT"), String("secretId and a Secret are required."))
        var has_rep = body.has(String("replication"))
        if r.location.byte_length() == 0 and not has_rep:
            return _error(400, String("INVALID_ARGUMENT"), String("Secret.replication is required."))
        if r.location.byte_length() > 0 and has_rep:
            return _error(
                400, String("INVALID_ARGUMENT"), String("A regional secret takes no replication policy.")
            )
        if self.store.find(r.location, secret_id) >= 0:
            return _error(
                409,
                String("ALREADY_EXISTS"),
                String("Secret [") + secret_name(r.location, secret_id) + "] already exists.",
            )
        var s = GcpSecret(secret_id^, r.location.copy(), self.store.now())
        var answer = _ok(secret_json(s))
        self.store.secrets.append(s^)
        return answer^

    def _add_version(mut self, r: _Route, parsed: Bool, body: JsonValue) raises -> _Answer:
        var at = self.store.find(r.location, r.secret_id)
        if at < 0:
            return self._secret_missing(r)
        if not parsed or not body.has(String("payload")):
            return _error(400, String("INVALID_ARGUMENT"), String("A payload is required."))
        var p = body.get(String("payload"))
        var data = List[UInt8]()
        if p.has(String("data")):
            try:
                data = base64_decode(p.get(String("data")).as_string())
            except:
                return _error(400, String("INVALID_ARGUMENT"), String("payload.data is not base64."))
        var given = p.has(String("dataCrc32c"))
        if given:
            var want = Int(atol(p.get(String("dataCrc32c")).as_string()))
            if want != Int(crc32c(Span(data))):
                return _error(
                    400, String("INVALID_ARGUMENT"), String("Checksum mismatch: payload.dataCrc32c.")
                )
        var number = len(self.store.secrets[at].versions) + 1
        var tick = self.store.now()
        var v = GcpVersion(number, data^, given, tick)
        var answer = _ok(version_json(self.store.secrets[at], v))
        self.store.secrets[at].versions.append(v^)
        return answer^

    def _list_versions(self, r: _Route, query: String) raises -> _Answer:
        var at = self.store.find(r.location, r.secret_id)
        if at < 0:
            return self._secret_missing(r)
        ref s = self.store.secrets[at]
        var total = len(s.versions)
        var page = _page(total, query)
        var arr = JsonValue.empty_array()
        for k in range(page[0], page[1]):
            # Newest first.
            arr.push(version_json(s, s.versions[total - 1 - k]))
        var o = JsonValue.empty_object()
        o.set_member(String("versions"), arr^)
        if page[1] < total:
            o.set_member(String("nextPageToken"), JsonValue.from_string(String("page-") + String(page[1])))
        o.set_member(String("totalSize"), JsonValue.from_i64(Int64(total)))
        return _ok(o)

    def _access(self, r: _Route) raises -> _Answer:
        var at = self.store.find(r.location, r.secret_id)
        var v = -1
        if at >= 0:
            v = self.store.secrets[at].version_index(r.version)
        if v < 0:
            return _error(
                404,
                String("NOT_FOUND"),
                String("Secret Version [") + secret_name(r.location, r.secret_id)
                + "/versions/" + r.version + "] not found.",
            )
        return _ok(access_json(self.store.secrets[at], self.store.secrets[at].versions[v]))

    def _list_secrets(self, r: _Route, query: String) raises -> _Answer:
        var mine = List[Int]()
        for i in range(len(self.store.secrets)):
            if self.store.secrets[i].location == r.location:
                mine.append(i)
        var page = _page(len(mine), query)
        var arr = JsonValue.empty_array()
        for k in range(page[0], page[1]):
            arr.push(secret_json(self.store.secrets[mine[k]]))
        var o = JsonValue.empty_object()
        o.set_member(String("secrets"), arr^)
        if page[1] < len(mine):
            o.set_member(String("nextPageToken"), JsonValue.from_string(String("page-") + String(page[1])))
        o.set_member(String("totalSize"), JsonValue.from_i64(Int64(len(mine))))
        return _ok(o)

    def _delete_secret(mut self, r: _Route) raises -> _Answer:
        var at = self.store.find(r.location, r.secret_id)
        if at < 0:
            return self._secret_missing(r)
        self.store.remove(at)
        return _ok(JsonValue.empty_object())
