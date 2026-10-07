# A fake S3 that keeps objects in memory, for tests of S3 clients:
# `FakeS3Connector`, a komira_http_core Connector whose streams parse each
# HTTP/1.1 request written to them and answer it as S3 does, path-style
# (`/<bucket>/<key>`): GET (a `bytes=a-b` range, or the suffix form
# `bytes=-n`), HEAD, ListObjectsV2 (a prefix, a delimiter, max-keys and
# continuation), PutObject (with If-Match and If-None-Match: *),
# DeleteObject, and the multipart upload verbs. A GET or HEAD carrying
# If-Match is answered 412 unless the ETag matches. Its state lives behind an
# Arc the connector shares with every stream it dials, so it outlives each
# connection. No socket. Signatures are not checked.
#
# Faults, each off by default and set on the connector: the next
# `conflicts` conditional PutObjects are answered 409
# ConditionalRequestConflict; requests past a budget (`max_requests`) are
# answered 403 RequestBudgetSpent; a request whose decoded target holds
# `trap` is answered 403 TrappedKeyRead; once `overwrite_after_reads` GETs
# and HEADs have been answered, the object the last one read is overwritten
# (a writer racing a reader); UploadPart of part `fail_part`, and with
# `fail_complete` CompleteMultipartUpload, are answered 403 InjectedFault.
# With `record_writes`, every write verb records the counts of PutObject,
# DeleteObject and the multipart verbs as the object `~fake/writes` of
# bucket `lake`, which a test reads back through the store.
#
# Test-only: komira_objectstore_s3's welded tests name it in `test_deps`.
from std.memory import ArcPointer

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedStream


struct FakeS3State(Movable):
    """The objects of every bucket (`<bucket>/<key>` -> body, ETag), kept
    sorted by name, the faults still to inject, and what the write verbs
    did."""

    var names: List[String]
    var bodies: List[List[UInt8]]
    var etags: List[String]
    var next_etag: Int
    # The next `conflicts` conditional PutObjects (If-Match or
    # If-None-Match) are answered 409 ConditionalRequestConflict, writing
    # nothing.
    var conflicts: Int
    # Requests answered past this many are refused. -1 for no budget.
    var max_requests: Int
    # A request whose decoded target holds this is refused. "" for none.
    var trap: String
    # Once this many GETs and HEADs have been answered, the object the last
    # one read is overwritten (its first byte changed, a new ETag). -1 for
    # never.
    var overwrite_after_reads: Int
    var reads: Int
    var requests: Int
    # Multipart uploads, by index (the id is `up-<index>`): the object name,
    # and whether it is still open; and their parts, flat.
    var upload_names: List[String]
    var upload_open: List[Bool]
    var part_upload: List[Int]
    var part_number: List[Int]
    var part_bodies: List[List[UInt8]]
    var part_etags: List[String]
    # UploadPart of this part number is answered 403 InjectedFault. -1 for
    # never.
    var fail_part: Int
    # CompleteMultipartUpload is answered 403 InjectedFault.
    var fail_complete: Bool
    # Whether each write verb records what the write verbs did as the
    # object `~fake/writes` of bucket `lake` (note_writes).
    var record_writes: Bool
    # What the write verbs did.
    var puts: Int
    var completed: Int
    var aborted: Int
    var deletes: Int

    def __init__(
        out self,
        conflicts: Int,
        max_requests: Int,
        var trap: String,
        overwrite_after_reads: Int,
        fail_part: Int,
        fail_complete: Bool,
        record_writes: Bool,
    ):
        self.names = List[String]()
        self.bodies = List[List[UInt8]]()
        self.etags = List[String]()
        self.next_etag = 1
        self.conflicts = conflicts
        self.max_requests = max_requests
        self.trap = trap^
        self.overwrite_after_reads = overwrite_after_reads
        self.reads = 0
        self.requests = 0
        self.upload_names = List[String]()
        self.upload_open = List[Bool]()
        self.part_upload = List[Int]()
        self.part_number = List[Int]()
        self.part_bodies = List[List[UInt8]]()
        self.part_etags = List[String]()
        self.fail_part = fail_part
        self.fail_complete = fail_complete
        self.record_writes = record_writes
        self.puts = 0
        self.completed = 0
        self.aborted = 0
        self.deletes = 0

    def remove(mut self, name: String):
        var at = self.find(name)
        if at >= 0:
            _ = self.names.pop(at)
            _ = self.bodies.pop(at)
            _ = self.etags.pop(at)

    def open_uploads(self) -> Int:
        var n = 0
        for i in range(len(self.upload_open)):
            if self.upload_open[i]:
                n += 1
        return n

    def parts_held(self) -> Int:
        """Parts stored for uploads still open."""
        var n = 0
        for i in range(len(self.part_upload)):
            if self.upload_open[self.part_upload[i]]:
                n += 1
        return n

    def note_writes(mut self):
        """With `record_writes`, records what the write verbs did as the
        object `~fake/writes` of bucket `lake`, which a test reads through
        the store."""
        if not self.record_writes:
            return
        _ = self.put(
            String("lake/~fake/writes"),
            _bytes(
                String("created=")
                + String(len(self.upload_names))
                + " open="
                + String(self.open_uploads())
                + " parts_held="
                + String(self.parts_held())
                + " completed="
                + String(self.completed)
                + " aborted="
                + String(self.aborted)
                + " puts="
                + String(self.puts)
                + " deletes="
                + String(self.deletes)
            ),
        )

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def put(mut self, name: String, var body: List[UInt8]) -> String:
        var etag = String('"etag-') + String(self.next_etag) + '"'
        self.next_etag += 1
        var at = self.find(name)
        if at >= 0:
            self.bodies[at] = body^
            self.etags[at] = etag
            return etag
        var i = 0
        while i < len(self.names) and self.names[i] < name:
            i += 1
        self.names.insert(i, name)
        self.bodies.insert(i, body^)
        self.etags.insert(i, etag)
        return etag


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _sub(s: String, i: Int, j: Int) -> String:
    return String(s[byte=i:j])


def _hex(c: UInt8) -> Int:
    if c >= 0x30 and c <= 0x39:
        return Int(c) - 0x30
    if c >= 0x41 and c <= 0x46:
        return Int(c) - 0x41 + 10
    if c >= 0x61 and c <= 0x66:
        return Int(c) - 0x61 + 10
    return -1


def unquote_plus(s: String) raises -> String:
    """`s` with each `%XX` decoded to its byte and each `+` to a space, as a
    URL-encoded name or query value is read. Refuses a `%` not followed by
    two hex digits."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(0x2B):
            out.append(UInt8(0x20))
            i += 1
        elif c == UInt8(0x25):
            if i + 2 >= len(b):
                raise Error("the fake S3 read a name that ends inside an escape: " + s)
            var hi = _hex(b[i + 1])
            var lo = _hex(b[i + 2])
            if hi < 0 or lo < 0:
                raise Error("the fake S3 read a name with a bad escape: " + s)
            out.append(UInt8(hi * 16 + lo))
            i += 3
        else:
            out.append(c)
            i += 1
    return String(unsafe_from_utf8=Span(out))


def _response(status: Int, reason: String, headers: String, body: List[UInt8], head: Bool) -> List[UInt8]:
    var out = _bytes(
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + reason
        + "\r\nContent-Length: "
        + String(len(body))
        + "\r\nConnection: close\r\n"
        + headers
        + "\r\n"
    )
    if not head:
        out.extend(Span(body))
    return out^


def _error(status: Int, reason: String, code: String, head: Bool) -> List[UInt8]:
    if head:
        return _response(status, reason, "", List[UInt8](), True)
    return _response(
        status,
        reason,
        "Content-Type: application/xml\r\n",
        _bytes(String("<Error><Code>") + code + "</Code><Message>fake</Message></Error>"),
        False,
    )


def _query(query: String, name: String) raises -> String:
    var parts = query.split("&")
    for i in range(len(parts)):
        var p = String(parts[i])
        var eq = p.find("=")
        var k = p if eq < 0 else _sub(p, 0, eq)
        if k == name:
            return unquote_plus(String("") if eq < 0 else _sub(p, eq + 1, p.byte_length()))
    return String("")


def _xml_escape(s: String) -> String:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _list(mut st: FakeS3State, bucket: String, query: String) raises -> List[UInt8]:
    var prefix = _query(query, "prefix")
    var delimiter = _query(query, "delimiter")
    var after = _query(query, "continuation-token")
    var max_keys = 1000
    var mk = _query(query, "max-keys")
    if mk.byte_length() > 0:
        max_keys = Int(mk)
    var full_prefix = bucket + "/" + prefix
    var skip = bucket.byte_length() + 1
    var body = String('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>')
    body += bucket + "</Name><Prefix>" + _xml_escape(prefix) + "</Prefix>"
    var count = 0
    var truncated = False
    var last = String("")
    var last_prefix = String("")
    var entries = String("")
    for i in range(len(st.names)):
        ref name = st.names[i]
        if not name.startswith(full_prefix):
            continue
        var key = _sub(name, skip, name.byte_length())
        if after.byte_length() > 0 and key <= after:
            continue
        var group = String("")
        if delimiter.byte_length() > 0:
            var rest = _sub(key, prefix.byte_length(), key.byte_length())
            var d = rest.find(delimiter)
            if d >= 0:
                group = prefix + _sub(rest, 0, d + delimiter.byte_length())
        if group.byte_length() > 0 and group == last_prefix:
            last = key
            continue
        if count == max_keys:
            truncated = True
            break
        count += 1
        last = key
        if group.byte_length() > 0:
            last_prefix = group
            entries += "<CommonPrefixes><Prefix>" + _xml_escape(group) + "</Prefix></CommonPrefixes>"
        else:
            entries += (
                "<Contents><Key>"
                + _xml_escape(key)
                + "</Key><Size>"
                + String(len(st.bodies[i]))
                + "</Size><ETag>"
                + _xml_escape(st.etags[i])
                + "</ETag></Contents>"
            )
    body += "<KeyCount>" + String(count) + "</KeyCount><MaxKeys>" + String(max_keys) + "</MaxKeys>"
    body += "<IsTruncated>" + ("true" if truncated else "false") + "</IsTruncated>"
    body += entries
    if truncated:
        body += "<NextContinuationToken>" + _xml_escape(last) + "</NextContinuationToken>"
    body += "</ListBucketResult>"
    return _response(200, "OK", "Content-Type: application/xml\r\n", _bytes(body), False)


def _serve(mut st: FakeS3State, written: List[UInt8]) raises -> List[UInt8]:
    """The answer to the one request in `written`."""
    st.requests += 1
    var n = len(written)
    var end = -1
    for i in range(n - 3):
        if written[i] == 13 and written[i + 1] == 10 and written[i + 2] == 13 and written[i + 3] == 10:
            end = i
            break
    if end < 0:
        raise Error("the fake S3 read no complete request head")
    var head = String(unsafe_from_utf8=Span(written)[0:end])
    var lines = head.split("\r\n")
    var request_line = String(lines[0]).split(" ")
    var method = String(request_line[0])
    var target = String(request_line[1])
    var body = List[UInt8]()
    body.extend(Span(written)[end + 4 : n])
    var is_head = method == "HEAD"
    if st.max_requests >= 0 and st.requests > st.max_requests:
        return _error(403, "Forbidden", "RequestBudgetSpent", is_head)
    if st.trap.byte_length() > 0 and unquote_plus(target).find(st.trap) >= 0:
        return _error(403, "Forbidden", "TrappedKeyRead", is_head)
    var if_match = String("")
    var if_none_match = String("")
    var range_ = String("")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon < 0:
            continue
        var name = _sub(line, 0, colon).lower()
        var value = String(_sub(line, colon + 1, line.byte_length()).strip())
        if name == "if-match":
            if_match = value
        elif name == "if-none-match":
            if_none_match = value
        elif name == "range":
            range_ = value
    var q = target.find("?")
    var path = target if q < 0 else _sub(target, 0, q)
    var query = String("") if q < 0 else _sub(target, q + 1, target.byte_length())
    var slash = path.find("/", 1)
    if slash < 0:
        var bucket = _sub(path, 1, path.byte_length())
        if method == "GET" and query.find("list-type=2") >= 0:
            return _list(st, bucket, query)
        return _error(400, "Bad Request", "NotImplemented", is_head)
    var name = unquote_plus(_sub(path, 1, path.byte_length()))
    if method == "POST" or (method == "PUT" and query.find("uploadId=") >= 0) or (
        method == "DELETE" and query.find("uploadId=") >= 0
    ):
        var answer = _multipart(st, method, name, query, body^)
        st.note_writes()
        return answer^
    var at = st.find(name)
    if method == "PUT":
        if if_match.byte_length() > 0 or if_none_match.byte_length() > 0:
            if st.conflicts > 0:
                st.conflicts -= 1
                return _error(409, "Conflict", "ConditionalRequestConflict", False)
        if if_none_match == "*" and at >= 0:
            return _error(412, "Precondition Failed", "PreconditionFailed", False)
        if if_match.byte_length() > 0:
            if at < 0:
                return _error(404, "Not Found", "NoSuchKey", False)
            if st.etags[at] != if_match:
                return _error(412, "Precondition Failed", "PreconditionFailed", False)
        var etag = st.put(name, body^)
        st.puts += 1
        st.note_writes()
        return _response(200, "OK", String("ETag: ") + etag + "\r\n", List[UInt8](), False)
    if method == "DELETE":
        st.remove(name)
        st.deletes += 1
        st.note_writes()
        return _response(204, "No Content", "", List[UInt8](), False)
    if method == "GET" or is_head:
        if at < 0:
            return _error(404, "Not Found", "NoSuchKey", is_head)
        if if_match.byte_length() > 0 and st.etags[at] != if_match:
            return _error(412, "Precondition Failed", "PreconditionFailed", is_head)
        var answer = _read(st, at, range_, is_head)
        st.reads += 1
        if st.reads == st.overwrite_after_reads:
            var changed = st.bodies[at].copy()
            changed[0] = changed[0] ^ UInt8(0x20)
            _ = st.put(name, changed^)
        return answer^
    return _error(405, "Method Not Allowed", "MethodNotAllowed", is_head)


def _xml_text(s: String, tag: String) -> String:
    """The text of the first `<tag>` element of `s`, "" when absent, with
    the quote entities decoded."""
    var open_tag = String("<") + tag + ">"
    var a = s.find(open_tag)
    if a < 0:
        return String("")
    a += open_tag.byte_length()
    var b = s.find(String("</") + tag + ">", a)
    if b < 0:
        return String("")
    return _sub(s, a, b).replace("&quot;", '"').replace("&#34;", '"')


def _multipart(
    mut st: FakeS3State, method: String, name: String, query: String, var body: List[UInt8]
) raises -> List[UInt8]:
    """CreateMultipartUpload (POST ?uploads), UploadPart (PUT ?partNumber
    &uploadId), CompleteMultipartUpload (POST ?uploadId) and
    AbortMultipartUpload (DELETE ?uploadId) of the object `name`."""
    if method == "POST" and query.find("uploads") >= 0:
        var id = len(st.upload_names)
        st.upload_names.append(name)
        st.upload_open.append(True)
        return _response(
            200,
            "OK",
            "Content-Type: application/xml\r\n",
            _bytes(
                String("<InitiateMultipartUploadResult><UploadId>up-")
                + String(id)
                + "</UploadId></InitiateMultipartUploadResult>"
            ),
            False,
        )
    var id_text = _query(query, "uploadId")
    if not id_text.startswith("up-"):
        return _error(404, "Not Found", "NoSuchUpload", False)
    var id = Int(_sub(id_text, 3, id_text.byte_length()))
    if id >= len(st.upload_names) or not st.upload_open[id] or st.upload_names[id] != name:
        return _error(404, "Not Found", "NoSuchUpload", False)
    if method == "DELETE":
        st.upload_open[id] = False
        st.aborted += 1
        return _response(204, "No Content", "", List[UInt8](), False)
    if method == "PUT":
        var number = Int(_query(query, "partNumber"))
        if number == st.fail_part:
            return _error(403, "Forbidden", "InjectedFault", False)
        var etag = String('"p-') + String(id) + "-" + String(number) + '"'
        st.part_upload.append(id)
        st.part_number.append(number)
        st.part_bodies.append(body^)
        st.part_etags.append(etag)
        return _response(200, "OK", String("ETag: ") + etag + "\r\n", List[UInt8](), False)
    # POST ?uploadId: the completion, its parts in the order listed.
    if st.fail_complete:
        return _error(403, "Forbidden", "InjectedFault", False)
    var doc = String(unsafe_from_utf8=Span(body))
    var listed = doc.split("<Part>")
    var whole = List[UInt8]()
    for i in range(1, len(listed)):
        var entry = String(listed[i])
        var number = Int(_xml_text(entry, "PartNumber"))
        var etag = _xml_text(entry, "ETag")
        var found = -1
        for p in range(len(st.part_upload)):
            if st.part_upload[p] == id and st.part_number[p] == number:
                found = p
        if found < 0 or st.part_etags[found] != etag:
            return _error(400, "Bad Request", "InvalidPart", False)
        whole.extend(Span(st.part_bodies[found]))
    st.upload_open[id] = False
    st.completed += 1
    var etag = st.put(name, whole^)
    return _response(
        200,
        "OK",
        "Content-Type: application/xml\r\n",
        _bytes(
            String("<CompleteMultipartUploadResult><ETag>")
            + _xml_escape(etag)
            + "</ETag></CompleteMultipartUploadResult>"
        ),
        False,
    )


def _read(st: FakeS3State, at: Int, range_: String, is_head: Bool) raises -> List[UInt8]:
    """The answer to a GET or HEAD of the object at `at`: `bytes=a-b` and
    the suffix form `bytes=-n`."""
    ref obj = st.bodies[at]
    var etag_header = String("ETag: ") + st.etags[at] + "\r\n"
    if range_.byte_length() > 0 and not is_head:
        var spec = _sub(range_, 6, range_.byte_length())
        var dash = spec.find("-")
        var first: Int
        var last: Int
        if dash == 0:
            var want = Int(_sub(spec, 1, spec.byte_length()))
            if len(obj) == 0:
                return _error(416, "Requested Range Not Satisfiable", "InvalidRange", False)
            first = max(0, len(obj) - want)
            last = len(obj) - 1
        else:
            first = Int(_sub(spec, 0, dash))
            last = Int(_sub(spec, dash + 1, spec.byte_length()))
        if first >= len(obj):
            return _error(416, "Requested Range Not Satisfiable", "InvalidRange", False)
        last = min(last, len(obj) - 1)
        var part = List[UInt8]()
        part.extend(Span(obj)[first : last + 1])
        return _response(
            206,
            "Partial Content",
            etag_header
            + "Content-Range: bytes "
            + String(first)
            + "-"
            + String(last)
            + "/"
            + String(len(obj))
            + "\r\n",
            part^,
            False,
        )
    var whole = obj.copy()
    return _response(200, "OK", etag_header, whole^, is_head)


struct FakeS3Stream(IoStream, Movable, Deinitable):
    """Keeps what is written; answers the first read from the shared
    state."""

    var _state: ArcPointer[FakeS3State]
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self, var state: ArcPointer[FakeS3State]):
        self._state = state^
        self._written = List[UInt8]()
        self._answer = ScriptedStream()
        self._answered = False

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](mut self, mut reactor: Reactor[RT.Sink], dst: Span[UInt8, o]) raises -> StreamIo:
        if not self._answered:
            self._answered = True
            self._answer = ScriptedStream.from_read_script(_serve(self._state[], self._written))
        return self._answer.try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], src: Span[UInt8, _]
    ) raises -> StreamIo:
        self._written.extend(src)
        return StreamIo.ready(Int64(len(src)))

    def unread(mut self, src: Span[UInt8, _]) raises:
        self._answer.unread(src)

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct FakeS3Connector(Connector, Movable, Deinitable):
    """Each dial is a stream over the one shared state."""

    comptime Stream = FakeS3Stream

    var _state: ArcPointer[FakeS3State]

    def __init__(
        out self,
        conflicts: Int = 0,
        max_requests: Int = -1,
        trap: String = "",
        overwrite_after_reads: Int = -1,
        fail_part: Int = -1,
        fail_complete: Bool = False,
        record_writes: Bool = False,
    ):
        """A fake S3 holding no object. Each argument is a fault or a
        record, off by default: see FakeS3State's fields."""
        self._state = ArcPointer[FakeS3State](
            FakeS3State(
                conflicts,
                max_requests,
                trap,
                overwrite_after_reads,
                fail_part,
                fail_complete,
                record_writes,
            )
        )

    def seed(mut self, key: String, body: String):
        """Stores `body` as `key` of bucket `lake` before any request."""
        _ = self._state[].put(String("lake/") + key, _bytes(body))

    def seed_bytes(mut self, key: String, var body: List[UInt8]):
        """Stores `body` as `key` of bucket `lake` before any request."""
        _ = self._state[].put(String("lake/") + key, body^)

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> FakeS3Stream:
        _ = ip_be
        _ = port
        return FakeS3Stream(self._state.copy())

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


def fake_s3_error_response(status: Int, reason: String, code: String) -> List[UInt8]:
    """The bytes of an S3 error response as the fake answers one: the status
    line, Content-Length, `Connection: close`, and an XML `<Error>` with
    `code` and the message `fake`. For a ScriptedStream's read script."""
    return _error(status, reason, code, False)
