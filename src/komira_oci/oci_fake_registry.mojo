# =============================================================================
# oci_fake_registry.mojo — an IN-PROCESS registry, for tests.
# =============================================================================
#
# `ScriptedOciTransport` replays a fixed script; this is the other kind of double:
# a small STATEFUL registry implementing `OciTransport` with real HEAD / POST /
# PUT / GET semantics. A test seeds it, pushes through it, and asserts on what
# it ended up holding — which catches the wrong-ORDER and wrong-STATE bugs a
# script cannot (a manifest accepted before its blobs, a tag that moved).
#
# WHAT IT ENFORCES (as a conformant registry does):
#   * blobs are per REPOSITORY: a blob in another repository is not visible;
#   * an upload is a session; a PUT with `?digest=` verifies the body's sha256
#     against it and answers 201, an unknown/expired session answers 404;
#   * a manifest PUT verifies the reference when it is a digest, and refuses a
#     manifest whose config or layers are not in the repository;
#   * TAGS ARE IMMUTABLE (configurable): re-pointing a tag at other content is
#     refused with a CONFIGURABLE status (`tag_conflict_status`: real
#     registries answer 400, 403 or 409, and the client must not depend on
#     which); re-putting the SAME digest is accepted unless told otherwise;
#   * an `Authorization` that does not match `required_authorization` is a 401.
#
# FAULT INJECTION (to drive the retry and classification paths): `add_fault`
# answers the next N matching calls with a given status (or a transport fault),
# `expire_next_sessions` makes freshly opened sessions already dead, `race_tag`
# plants a tag the moment a PUT to it arrives (a racing publisher), and
# `location_mode` chooses what the upload `Location` looks like.
#
# Everything is owned Strings / Lists. No pointer, no wildcard origin.
# =============================================================================

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from .oci_copy import image_blob_digests
from .oci_digest import digest_of_bytes
from .oci_transport import OciRequest, OciResponse, OciTransport


# What the upload-session `Location` looks like.
comptime LOCATION_RELATIVE: Int = 0
comptime LOCATION_ABSOLUTE_SAME_HOST: Int = 1
comptime LOCATION_ABSOLUTE_OTHER_HOST: Int = 2
comptime LOCATION_PLAINTEXT: Int = 3
comptime LOCATION_RELATIVE_WITH_QUERY: Int = 4
comptime LOCATION_EMPTY: Int = 5


struct FakeOciRegistry(OciTransport, Movable, Deinitable):
    """A stateful in-process registry. See the file header."""

    # ---- configuration ----
    var host: String
    var other_host: String
    var immutable_tags: Bool
    var tag_conflict_status: Int
    var reject_same_digest_tag_put: Bool
    var location_mode: Int
    var omit_digest_header_on_head: Bool
    var required_authorization: String
    # What a 401 for a wrong credential carries in `WWW-Authenticate`.
    var www_authenticate: String
    # The `Docker-Content-Digest` a blob PUT answers with: "" = the right one,
    # "omit" = no header, anything else = that value verbatim.
    var blob_put_digest_header: String
    var _expire_new_sessions: Int

    # ---- storage ----
    var _blob_repo: List[String]
    var _blob_digest: List[String]
    var _blob_data: List[List[UInt8]]
    var _man_repo: List[String]
    var _man_digest: List[String]
    var _man_type: List[String]
    var _man_data: List[List[UInt8]]
    var _tag_repo: List[String]
    var _tag_name: List[String]
    var _tag_digest: List[String]
    var _sess_id: List[String]
    var _sess_repo: List[String]
    var _sess_live: List[Bool]
    var _next_session: Int

    # ---- fault injection ----
    var _fault_method: List[UInt8]
    var _fault_path: List[String]
    var _fault_status: List[Int]
    var _fault_left: List[Int]
    var _fault_skip: List[Int]
    var _race_repo_tag: List[String]
    var _race_digest: List[String]

    # ---- the call log ----
    var _call_method: List[UInt8]
    var _call_host: List[String]
    var _call_path: List[String]
    var _call_auth: List[String]
    var _call_body_len: List[Int]

    def __init__(out self, var host: String):
        self.host = host^
        self.other_host = String("evil.example.net")
        self.immutable_tags = True
        self.tag_conflict_status = 409
        self.reject_same_digest_tag_put = False
        self.location_mode = LOCATION_RELATIVE
        self.omit_digest_header_on_head = False
        self.required_authorization = String("")
        self.www_authenticate = String("")
        self.blob_put_digest_header = String("")
        self._expire_new_sessions = 0
        self._blob_repo = List[String]()
        self._blob_digest = List[String]()
        self._blob_data = List[List[UInt8]]()
        self._man_repo = List[String]()
        self._man_digest = List[String]()
        self._man_type = List[String]()
        self._man_data = List[List[UInt8]]()
        self._tag_repo = List[String]()
        self._tag_name = List[String]()
        self._tag_digest = List[String]()
        self._sess_id = List[String]()
        self._sess_repo = List[String]()
        self._sess_live = List[Bool]()
        self._next_session = 1
        self._fault_method = List[UInt8]()
        self._fault_path = List[String]()
        self._fault_status = List[Int]()
        self._fault_left = List[Int]()
        self._fault_skip = List[Int]()
        self._race_repo_tag = List[String]()
        self._race_digest = List[String]()
        self._call_method = List[UInt8]()
        self._call_host = List[String]()
        self._call_path = List[String]()
        self._call_auth = List[String]()
        self._call_body_len = List[Int]()

    # =========================================================================
    # test-side API: seed, fault, inspect
    # =========================================================================
    def seed_blob(mut self, repo: String, data: List[UInt8]) -> String:
        """Store `data` as a blob of `repo`; return its digest."""
        var d = digest_of_bytes(Span(data))
        if not self.has_blob(repo, d):
            self._blob_repo.append(repo.copy())
            self._blob_digest.append(d.copy())
            self._blob_data.append(data.copy())
        return d^

    def seed_manifest(
        mut self, repo: String, media_type: String, data: List[UInt8]
    ) -> String:
        """Store `data` as a manifest of `repo` (no blob check); return its
        digest."""
        var d = digest_of_bytes(Span(data))
        if not self.has_manifest(repo, d):
            self._man_repo.append(repo.copy())
            self._man_digest.append(d.copy())
            self._man_type.append(media_type.copy())
            self._man_data.append(data.copy())
        return d^

    def seed_tag(mut self, repo: String, tag: String, digest: String):
        self._set_tag(repo, tag, digest)

    def add_fault(
        mut self,
        method: UInt8,
        path_contains: String,
        status: Int,
        count: Int,
        skip: Int = 0,
    ):
        """Answer the next `count` calls of `method` whose path contains
        `path_contains` with `status` (-1 = a transport fault), after letting the
        first `skip` matching calls through untouched."""
        self._fault_skip.append(skip)
        self._fault_method.append(method)
        self._fault_path.append(path_contains.copy())
        self._fault_status.append(status)
        self._fault_left.append(count)

    def expire_next_sessions(mut self, count: Int):
        """The next `count` upload sessions are born dead: their PUT is 404."""
        self._expire_new_sessions = count

    def race_tag(mut self, repo: String, tag: String, digest: String):
        """When a PUT to `tag` in `repo` ARRIVES, first plant `tag -> digest`
        (another publisher got there first), then evaluate the PUT."""
        self._race_repo_tag.append(repo + String(":") + tag)
        self._race_digest.append(digest.copy())

    def has_blob(self, repo: String, digest: String) -> Bool:
        for i in range(len(self._blob_repo)):
            if self._blob_repo[i] == repo and self._blob_digest[i] == digest:
                return True
        return False

    def has_manifest(self, repo: String, digest: String) -> Bool:
        for i in range(len(self._man_repo)):
            if self._man_repo[i] == repo and self._man_digest[i] == digest:
                return True
        return False

    def tag_digest(self, repo: String, tag: String) -> String:
        """The digest `tag` names in `repo`, or EMPTY."""
        for i in range(len(self._tag_repo)):
            if self._tag_repo[i] == repo and self._tag_name[i] == tag:
                return self._tag_digest[i].copy()
        return String("")

    def blob_count(self, repo: String) -> Int:
        var n = 0
        for i in range(len(self._blob_repo)):
            if self._blob_repo[i] == repo:
                n += 1
        return n

    def call_count(self) -> Int:
        return len(self._call_path)

    def call_method(self, i: Int) -> UInt8:
        return self._call_method[i]

    def call_host(self, i: Int) -> String:
        return self._call_host[i].copy()

    def call_path(self, i: Int) -> String:
        return self._call_path[i].copy()

    def call_auth(self, i: Int) -> String:
        return self._call_auth[i].copy()

    def count_calls(self, method: UInt8, path_contains: String) -> Int:
        var n = 0
        for i in range(len(self._call_path)):
            if self._call_method[i] == method and self._call_path[i].find(path_contains) >= 0:
                n += 1
        return n

    def calls_to_other_hosts(self) -> Int:
        var n = 0
        for i in range(len(self._call_host)):
            if self._call_host[i] != self.host:
                n += 1
        return n

    # =========================================================================
    # the registry
    # =========================================================================
    def send(mut self, var request: OciRequest) raises -> OciResponse:
        self._call_method.append(request.method)
        self._call_host.append(request.registry.copy())
        self._call_path.append(request.path.copy())
        self._call_auth.append(request.header_value(String("authorization")))
        self._call_body_len.append(len(request.body))

        # Injected faults first.
        for i in range(len(self._fault_left)):
            if (
                self._fault_left[i] > 0
                and self._fault_method[i] == request.method
                and request.path.find(self._fault_path[i]) >= 0
            ):
                if self._fault_skip[i] > 0:
                    self._fault_skip[i] -= 1
                    continue
                self._fault_left[i] -= 1
                if self._fault_status[i] < 0:
                    raise Error(String("FakeOciRegistry: injected transport fault"))
                return OciResponse(self._fault_status[i])

        if request.registry != self.host:
            return _plain(404)
        if (
            self.required_authorization.byte_length() > 0
            and request.header_value(String("authorization")) != self.required_authorization
        ):
            var denied = OciResponse(401)
            if self.www_authenticate.byte_length() > 0:
                denied.with_header(
                    String("www-authenticate"), self.www_authenticate.copy()
                )
            return denied^
        if not request.path.startswith(String("/v2/")):
            return _plain(404)
        var rest = String(request.path[byte=4:])

        var up = rest.find(String("/blobs/uploads/"))
        if up >= 0:
            var repo = String(rest[byte=:up])
            var tail = String(rest[byte = up + 15 :])
            if request.method == HTTP_METHOD_POST:
                return self._open_session(repo)
            if request.method == HTTP_METHOD_PUT:
                return self._finish_upload(repo, tail, request)
            return _plain(405)
        var bl = rest.find(String("/blobs/"))
        if bl >= 0:
            var repo = String(rest[byte=:bl])
            var digest = String(rest[byte = bl + 7 :])
            if request.method == HTTP_METHOD_HEAD or request.method == HTTP_METHOD_GET:
                for bi in range(len(self._blob_repo)):
                    if self._blob_repo[bi] == repo and self._blob_digest[bi] == digest:
                        var r = OciResponse(200)
                        r.with_header(String("docker-content-digest"), digest.copy())
                        if request.method == HTTP_METHOD_GET:
                            r.with_body(self._blob_data[bi].copy())
                        return r^
                return _plain(404)
            return _plain(405)
        var mf = rest.find(String("/manifests/"))
        if mf >= 0:
            var repo = String(rest[byte=:mf])
            var reference = String(rest[byte = mf + 11 :])
            if request.method == HTTP_METHOD_PUT:
                return self._put_manifest(repo, reference, request)
            if request.method == HTTP_METHOD_HEAD or request.method == HTTP_METHOD_GET:
                return self._get_manifest(repo, reference, request.method == HTTP_METHOD_GET)
            return _plain(405)
        return _plain(404)

    def _open_session(mut self, repo: String) -> OciResponse:
        var id = String("sess-") + String(self._next_session)
        self._next_session += 1
        self._sess_id.append(id.copy())
        self._sess_repo.append(repo.copy())
        if self._expire_new_sessions > 0:
            self._expire_new_sessions -= 1
            self._sess_live.append(False)
        else:
            self._sess_live.append(True)
        var rel = String("/v2/") + repo + String("/blobs/uploads/") + id
        var r = OciResponse(202)
        if self.location_mode == LOCATION_RELATIVE:
            r.with_header(String("location"), rel^)
        elif self.location_mode == LOCATION_RELATIVE_WITH_QUERY:
            r.with_header(String("location"), rel + String("?_state=abc"))
        elif self.location_mode == LOCATION_ABSOLUTE_SAME_HOST:
            r.with_header(String("location"), String("https://") + self.host + rel)
        elif self.location_mode == LOCATION_ABSOLUTE_OTHER_HOST:
            r.with_header(String("location"), String("https://") + self.other_host + rel)
        elif self.location_mode == LOCATION_PLAINTEXT:
            r.with_header(String("location"), String("http://") + self.host + rel)
        # LOCATION_EMPTY: no header at all.
        return r^

    def _finish_upload(
        mut self, repo: String, tail: String, mut request: OciRequest
    ) -> OciResponse:
        var q = tail.find(String("?"))
        if q < 0:
            return _plain(400)
        var id = String(tail[byte=:q])
        var query = String(tail[byte = q + 1 :])
        var idx = -1
        for i in range(len(self._sess_id)):
            if self._sess_id[i] == id and self._sess_repo[i] == repo:
                idx = i
        if idx < 0 or not self._sess_live[idx]:
            return _plain(404)
        var d = query.find(String("digest="))
        if d < 0:
            return _plain(400)
        var digest = String(query[byte = d + 7 :])
        var amp = digest.find(String("&"))
        if amp >= 0:
            var trimmed = String(digest[byte=:amp])
            digest = trimmed^
        var body = request.take_body()
        if digest_of_bytes(Span(body)) != digest:
            return _plain(400)
        self._sess_live[idx] = False
        _ = self.seed_blob(repo, body)
        var r = OciResponse(201)
        if self.blob_put_digest_header.byte_length() == 0:
            r.with_header(String("docker-content-digest"), digest^)
        elif self.blob_put_digest_header != String("omit"):
            r.with_header(
                String("docker-content-digest"),
                self.blob_put_digest_header.copy(),
            )
        return r^

    def _put_manifest(
        mut self, repo: String, reference: String, mut request: OciRequest
    ) -> OciResponse:
        var body = request.take_body()
        var digest = digest_of_bytes(Span(body))
        var by_digest = reference.startswith(String("sha256:"))
        if by_digest and reference != digest:
            return _plain(400)
        # Every blob a manifest names must already be in the repository.
        try:
            var needed = image_blob_digests(body)
            for i in range(len(needed)):
                if not self.has_blob(repo, needed[i]):
                    return _plain(400)
        except:
            pass
        if not by_digest:
            # A tag. Plant any racing publisher first.
            var key = repo + String(":") + reference
            for i in range(len(self._race_repo_tag)):
                if self._race_repo_tag[i] == key:
                    var racer = self._race_digest[i].copy()
                    self._set_tag(repo, reference, racer)
            var existing = self.tag_digest(repo, reference)
            if existing.byte_length() > 0:
                if existing != digest and self.immutable_tags:
                    return _plain(self.tag_conflict_status)
                if existing == digest and self.reject_same_digest_tag_put:
                    return _plain(self.tag_conflict_status)
        var ctype = request.header_value(String("content-type"))
        _ = self.seed_manifest(repo, ctype, body)
        if not by_digest:
            self._set_tag(repo, reference, digest)
        var r = OciResponse(201)
        r.with_header(String("docker-content-digest"), digest^)
        return r^

    def _get_manifest(self, repo: String, reference: String, with_body: Bool) -> OciResponse:
        var digest = reference.copy()
        if not reference.startswith(String("sha256:")):
            digest = self.tag_digest(repo, reference)
            if digest.byte_length() == 0:
                return _plain(404)
        for i in range(len(self._man_repo)):
            if self._man_repo[i] == repo and self._man_digest[i] == digest:
                var r = OciResponse(200)
                if with_body or not self.omit_digest_header_on_head:
                    r.with_header(String("docker-content-digest"), digest.copy())
                r.with_header(String("content-type"), self._man_type[i].copy())
                if with_body:
                    r.with_body(self._man_data[i].copy())
                return r^
        return _plain(404)

    def _set_tag(mut self, repo: String, tag: String, digest: String):
        for i in range(len(self._tag_repo)):
            if self._tag_repo[i] == repo and self._tag_name[i] == tag:
                self._tag_digest[i] = digest.copy()
                return
        self._tag_repo.append(repo.copy())
        self._tag_name.append(tag.copy())
        self._tag_digest.append(digest.copy())


def _plain(status: Int) -> OciResponse:
    return OciResponse(status)
