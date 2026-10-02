# =============================================================================
# src/kci_publish/scripted_channel.mojo -- `ScriptedChannel`: a prefix.dev
#   conda channel held in memory, as a `PkgTransport`. THE TEST DOUBLE.
# =============================================================================
#
# A queue of scripted answers cannot express a publish run: which file is read
# when depends on the plan, and an upload must be VISIBLE to the reads after
# it. So the double is a small channel server, speaking exactly the requests
# kci_pkg_upload's `PrefixDevRegistry` makes:
#
#   GET  /<channel>/<subdir>/repodata.json   every stored file of the subdir,
#                                            with its sha256 (plus any entry
#                                            `list_without_file` added)
#   GET  /<channel>/<subdir>/<file>          the stored bytes, or 404
#   POST /api/v1/upload/<channel>            the one-part form: stores the
#                                            part's bytes under its
#                                            X-File-Name in the upload subdir
#
# It NEVER OVERWRITES: an upload of a stored file name answers 409, whatever
# the bytes. A request whose path or headers (or the form part's headers)
# say `force` answers 400 and is counted (`force_requests`).
#
# Faults are scripted per file name (`plan_upload`, consumed FIFO; with none
# planned an upload stores and answers 201), per fetch (`fail_fetch_once`;
# `other_bytes_on_fetch`, the n-th fetch of a file serves other bytes), and
# per subdir listing (`fail_listing`, every time). Every request is
# recorded verbatim, in order.
#
# Layout: owned lists. No pointer field.
# =============================================================================

from komira_http.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST

from kci_pkg_upload import PkgRequest, PkgResponse, PkgTransport, content_identity_of


comptime UPLOAD_STORE: Int = 0
"""Store the bytes and answer 201 (the default)."""
comptime UPLOAD_STORE_LOSE_ANSWER: Int = 1
"""Store the bytes, then fail the exchange: the answer is lost."""
comptime UPLOAD_LOSE_NOT_STORED: Int = 2
"""Fail the exchange without storing anything."""
comptime UPLOAD_ANSWER_500: Int = 3
"""Answer 500 without storing anything."""
comptime UPLOAD_ANSWER_400: Int = 4
"""Answer 400 (a definitive rejection) without storing anything."""
comptime UPLOAD_ANSWER_403: Int = 5
"""Answer 403 without storing anything."""
comptime UPLOAD_STORE_OTHER_BYTES: Int = 6
"""Store OTHER bytes under the name (a racing writer), answer 409."""
comptime UPLOAD_STORE_ANSWER_409: Int = 7
"""Store the request's bytes, answer 409 (a racing writer of the SAME
bytes)."""


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _find(hay: List[UInt8], needle: String, start: Int) -> Int:
    var n = needle.as_bytes()
    var m = len(n)
    if m == 0:
        return start
    var i = start
    while i + m <= len(hay):
        var ok = True
        for k in range(m):
            if hay[i + k] != n[k]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _slice_text(b: List[UInt8], start: Int, end: Int) -> String:
    var s = String("")
    for i in range(start, end):
        s += chr(Int(b[i]))
    return s^


struct ScriptedChannel(PkgTransport, Movable):
    """See the file header."""

    var _host: String
    var _channel: String
    var _upload_subdir: String
    var _paths: List[String]
    var _blobs: List[List[UInt8]]
    var _listed_paths: List[String]
    var _listed_sha: List[String]
    var _plan_files: List[String]
    var _plan_kinds: List[Int]
    var _fetch_faults: List[String]
    var _listing_faults: List[String]
    var _swap_paths: List[String]
    var _swap_nth: List[Int]
    var _calls: List[PkgRequest]
    var force_requests: Int

    def __init__(out self, var host: String, var channel: String, var upload_subdir: String):
        self._host = host^
        self._channel = channel^
        self._upload_subdir = upload_subdir^
        self._paths = List[String]()
        self._blobs = List[List[UInt8]]()
        self._listed_paths = List[String]()
        self._listed_sha = List[String]()
        self._plan_files = List[String]()
        self._plan_kinds = List[Int]()
        self._fetch_faults = List[String]()
        self._listing_faults = List[String]()
        self._swap_paths = List[String]()
        self._swap_nth = List[Int]()
        self._calls = List[PkgRequest]()
        self.force_requests = 0

    # ── setup ────────────────────────────────────────────────────────────────
    def put(mut self, subdir: String, file: String, var data: List[UInt8]):
        """Store `data` as `<subdir>/<file>` (replacing: setup, not upload)."""
        var p = subdir + String("/") + file
        for i in range(len(self._paths)):
            if self._paths[i] == p:
                self._blobs[i] = data^
                return
        self._paths.append(p^)
        self._blobs.append(data^)

    def list_without_file(mut self, subdir: String, file: String, var sha256_hex: String):
        """List `<subdir>/<file>` in the repodata with no file behind it."""
        self._listed_paths.append(subdir + String("/") + file)
        self._listed_sha.append(sha256_hex^)

    def plan_upload(mut self, var file: String, kind: Int):
        """The next upload of `file` behaves as `kind` (FIFO per file)."""
        self._plan_files.append(file^)
        self._plan_kinds.append(kind)

    def fail_fetch_once(mut self, subdir: String, file: String):
        self._fetch_faults.append(subdir + String("/") + file)

    def other_bytes_on_fetch(mut self, subdir: String, file: String, nth: Int):
        """The `nth` (1-based) GET of `<subdir>/<file>` serves other bytes."""
        self._swap_paths.append(subdir + String("/") + file)
        self._swap_nth.append(nth)

    def fail_listing(mut self, var subdir: String):
        self._listing_faults.append(subdir^)

    # ── inspection ───────────────────────────────────────────────────────────
    def holds(self, subdir: String, file: String) -> Bool:
        return self._index(subdir + String("/") + file) >= 0

    def call_count(self) -> Int:
        return len(self._calls)

    def call(self, i: Int) -> PkgRequest:
        return self._calls[i].copy()

    def upload_count(self, file: String) -> Int:
        """How many upload requests named `file`."""
        var n = 0
        for i in range(len(self._calls)):
            if self._calls[i].method == HTTP_METHOD_POST and _find(
                self._calls[i].body, String("X-File-Name: ") + file + String("\r\n"), 0
            ) >= 0:
                n += 1
        return n

    def last_upload_call(self, file: String) -> Int:
        """The index of the last upload request naming `file`, or -1."""
        var at = -1
        for i in range(len(self._calls)):
            if self._calls[i].method == HTTP_METHOD_POST and _find(
                self._calls[i].body, String("X-File-Name: ") + file + String("\r\n"), 0
            ) >= 0:
                at = i
        return at

    def first_upload_call(self, file: String) -> Int:
        for i in range(len(self._calls)):
            if self._calls[i].method == HTTP_METHOD_POST and _find(
                self._calls[i].body, String("X-File-Name: ") + file + String("\r\n"), 0
            ) >= 0:
                return i
        return -1

    def last_fetch_call(self, subdir: String, file: String) -> Int:
        var p = String("/") + self._channel + String("/") + subdir + String("/") + file
        var at = -1
        for i in range(len(self._calls)):
            if self._calls[i].method == HTTP_METHOD_GET and self._calls[i].path == p:
                at = i
        return at

    def write_count(self) -> Int:
        var n = 0
        for i in range(len(self._calls)):
            if self._calls[i].method != HTTP_METHOD_GET:
                n += 1
        return n

    # ── the server ───────────────────────────────────────────────────────────
    def _index(self, p: String) -> Int:
        for i in range(len(self._paths)):
            if self._paths[i] == p:
                return i
        return -1

    def _next_plan(mut self, file: String) -> Int:
        for i in range(len(self._plan_files)):
            if self._plan_files[i] == file:
                var k = self._plan_kinds[i]
                _ = self._plan_files.pop(i)
                _ = self._plan_kinds.pop(i)
                return k
        return UPLOAD_STORE

    def _repodata(self, subdir: String) -> PkgResponse:
        var prefix = subdir + String("/")
        var conda = String("")
        for i in range(len(self._paths)):
            if self._paths[i].startswith(prefix):
                if conda.byte_length() > 0:
                    conda += String(",")
                var file = String(self._paths[i][byte = prefix.byte_length() :])
                conda += (
                    String('"')
                    + file
                    + String('":{"sha256":"')
                    + content_identity_of(Span(self._blobs[i])).sha256_hex
                    + String('","size":')
                    + String(len(self._blobs[i]))
                    + String("}")
                )
        for i in range(len(self._listed_paths)):
            if self._listed_paths[i].startswith(prefix):
                if conda.byte_length() > 0:
                    conda += String(",")
                conda += (
                    String('"')
                    + String(self._listed_paths[i][byte = prefix.byte_length() :])
                    + String('":{"sha256":"')
                    + self._listed_sha[i]
                    + String('"}')
                )
        var r = PkgResponse(200)
        r.with_header(String("content-type"), String("application/json"))
        r.with_body(
            _bytes(
                String('{"info":{"subdir":"')
                + subdir
                + String('"},"packages":{},"packages.conda":{')
                + conda
                + String("}}")
            )
        )
        return r^

    def _says_force(self, req: PkgRequest) -> Bool:
        if req.path.find(String("force")) >= 0:
            return True
        for i in range(len(req.header_names)):
            if req.header_names[i].find(String("force")) >= 0 or req.header_values[i].find(String("force")) >= 0:
                return True
        var head_end = _find(req.body, String("\r\n\r\n"), 0)
        if head_end >= 0 and _find(req.body, String("force"), 0) >= 0:
            var f = _find(req.body, String("force"), 0)
            if f < head_end:
                return True
        return False

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        self._calls.append(req.copy())
        if req.host != self._host:
            raise Error(String("ScriptedChannel: a request to an unexpected host '") + req.host + String("'"))
        if self._says_force(req):
            self.force_requests += 1
            return PkgResponse(400)
        if req.method == HTTP_METHOD_GET:
            var root = String("/") + self._channel + String("/")
            if not req.path.startswith(root):
                return PkgResponse(404)
            var rest = String(req.path[byte = root.byte_length() :])
            var slash = rest.find(String("/"))
            if slash <= 0:
                return PkgResponse(404)
            var subdir = String(rest[byte=:slash])
            var file = String(rest[byte = slash + 1 :])
            if file == String("repodata.json"):
                for i in range(len(self._listing_faults)):
                    if self._listing_faults[i] == subdir:
                        return PkgResponse(503)
                return self._repodata(subdir)
            for i in range(len(self._fetch_faults)):
                if self._fetch_faults[i] == rest:
                    _ = self._fetch_faults.pop(i)
                    return PkgResponse(503)
            var at = self._index(rest)
            if at < 0:
                return PkgResponse(404)
            var nth = 0
            for i in range(len(self._calls)):
                if self._calls[i].method == HTTP_METHOD_GET and self._calls[i].path == req.path:
                    nth += 1
            for i in range(len(self._swap_paths)):
                if self._swap_paths[i] == rest and self._swap_nth[i] == nth:
                    var o = PkgResponse(200)
                    o.with_body(_bytes(String("bytes that changed under the channel")))
                    return o^
            var r = PkgResponse(200)
            r.with_body(self._blobs[at].copy())
            return r^
        if req.method != HTTP_METHOD_POST or req.path != String("/api/v1/upload/") + self._channel:
            return PkgResponse(404)
        var name_at = _find(req.body, String("X-File-Name: "), 0)
        var head_end = _find(req.body, String("\r\n\r\n"), 0)
        var ct = req.header_value(String("Content-Type"))
        var b_at = ct.find(String("boundary="))
        if name_at < 0 or head_end < 0 or b_at < 0:
            return PkgResponse(400)
        var name_end = _find(req.body, String("\r\n"), name_at)
        var file = _slice_text(req.body, name_at + 13, name_end)
        var boundary = String(ct[byte = b_at + 9 :])
        var tail = String("\r\n--") + boundary + String("--\r\n")
        var end = len(req.body) - tail.byte_length()
        if end < head_end + 4:
            return PkgResponse(400)
        var data = List[UInt8]()
        for i in range(head_end + 4, end):
            data.append(req.body[i])
        var p = self._upload_subdir + String("/") + file
        var kind = self._next_plan(file)
        if kind == UPLOAD_LOSE_NOT_STORED:
            raise Error("ScriptedChannel: connection reset (nothing stored)")
        if kind == UPLOAD_ANSWER_500:
            return PkgResponse(500)
        if kind == UPLOAD_ANSWER_400:
            return PkgResponse(400)
        if kind == UPLOAD_ANSWER_403:
            return PkgResponse(403)
        if kind == UPLOAD_STORE_OTHER_BYTES:
            if self._index(p) < 0:
                self._paths.append(p^)
                self._blobs.append(_bytes(String("someone else's bytes")))
            return PkgResponse(409)
        if kind == UPLOAD_STORE_ANSWER_409:
            if self._index(p) < 0:
                self._paths.append(p^)
                self._blobs.append(data^)
            return PkgResponse(409)
        if self._index(p) >= 0:
            return PkgResponse(409)
        self._paths.append(p^)
        self._blobs.append(data^)
        if kind == UPLOAD_STORE_LOSE_ANSWER:
            raise Error("ScriptedChannel: connection reset after the bytes were stored")
        return PkgResponse(201)
