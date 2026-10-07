# S3Fs, komira_fs's FileSystem over one S3 bucket, against a fake S3 that
# keeps objects in memory: `FakeS3Connector`, a komira_http_core Connector
# whose streams parse each HTTP request the store sends (through the
# generated client, komira_aws_core's signer and komira_http_client) and
# answer it as S3 does: ranged and suffix GETs, HEAD, ListObjectsV2 with a
# delimiter and continuation, If-Match, PutObject, DeleteObject and the
# multipart upload verbs. No socket.
#
# The fake also counts: a factory may give it a request budget, and every
# request past it is answered 403 RequestBudgetSpent (a HEAD's 403 has no
# body to carry the code, so the rows spend budgets with GETs), so a verb
# that sends more requests than it should fails. It may be given a trap, a
# key fragment: any request whose target names it is answered 403
# TrappedKeyRead, so a verb that touches an object or prefix it should not
# fails, naming it. It may be told to refuse one part number, or every
# completion, with 403 InjectedFault. And once a write verb has run it
# keeps what the write verbs did (uploads created and still open, parts
# held, completions, aborts, PutObjects, deletes) as the object
# `~fake/writes`, which a row reads through the file system.
#
# Rows: construction dials nothing; the accessors (bucket, handle key,
# prefetch depth, random read, scheme, options); read_at (exact bytes, a
# zero length sends nothing, negative and short reads, an absent key);
# read_footer (one request, the tail and the object's size, a window past
# the object, a window below the trailer, an object too small); file_size;
# list (bare keys, every page); is_dir (a prefix, a key, a sibling that
# shares the prefix, the bucket root, an empty bucket); list_dir_shallow
# (directories then files, the placeholder skipped, the bucket root);
# read_ranges_prefetched (input order, a zero-length range, a range past
# the object, near ranges in one request, one version of an object
# overwritten during the fetch); writes (an object below one part is one
# PutObject and open_write sends nothing; an empty object; an object of
# several parts written in pieces that straddle them, and one of whole
# parts, each one multipart upload with no upload left open; a failed part
# and a failed completion each abort the upload and leave no object, and
# the handle is refused after; abort_write with and without a part sent;
# append, create-exclusive and pwrite_at refused); delete (an object, an
# absent key) and the fsyncs; a clone with its own store.
#
# Then the Hive partition prune over S3Fs: komira_fs's PrunedHiveDiscovery
# with `region == us`, over a bucket whose `region=eu` partition is
# trapped. The discovery lists only `t/region=us/`, and reading every
# surviving file (footer, size, a range) sends no request into the pruned
# partition. The trap is live: `region IN (us, eu)` lists the eu prefix and
# is refused. And a pruned partition is read only when a caller asks for
# it: the first file of the UNPRUNED listing of `t/` is `t/region=eu/...`,
# and a footer read of it is refused. That is the read a caller resolving a
# schema from the unpruned listing's first file makes; S3Fs sends only the
# requests its caller asks for.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_arrow.arrow_types import ArrowType
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_S3
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_fs.file_system import WriteMode
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedStream
from komira_objectstore_s3 import (
    AddressingStyle,
    S3Config,
    S3FileHandle,
    S3Fs,
    S3FsOptions,
    s3_url_decode,
)
from komira_retry import Backoff, Jitter, RetryPolicy


# =============================================================================
# The fake S3.
# =============================================================================


struct FakeS3State(Movable):
    """The objects of every bucket (`<bucket>/<key>` -> body, ETag), kept
    sorted by name, and the faults to inject."""

    var names: List[String]
    var bodies: List[List[UInt8]]
    var etags: List[String]
    var next_etag: Int
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
    # What the write verbs did, in `~fake/writes` once any has run.
    var puts: Int
    var completed: Int
    var aborted: Int
    var deletes: Int

    def __init__(
        out self,
        max_requests: Int,
        var trap: String,
        overwrite_after_reads: Int,
        fail_part: Int,
        fail_complete: Bool,
    ):
        self.names = List[String]()
        self.bodies = List[List[UInt8]]()
        self.etags = List[String]()
        self.next_etag = 1
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
        """Records what the write verbs did as the object `~fake/writes` of
        bucket `lake`, which a test reads through the file system."""
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


def _buf_text(b: SharedAlignedBuffer[HeapRegion]) -> String:
    var view = b.view_range_ro(0, b.len())
    return String(unsafe_from_utf8=view.into_span())


def _sub(s: String, i: Int, j: Int) -> String:
    return String(s[byte=i:j])


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


def _error(status: Int, reason: String, code: String, head: Bool, message: String = "fake") -> List[UInt8]:
    if head:
        return _response(status, reason, "", List[UInt8](), True)
    return _response(
        status,
        reason,
        "Content-Type: application/xml\r\n",
        _bytes(String("<Error><Code>") + code + "</Code><Message>" + message + "</Message></Error>"),
        False,
    )


def _query(query: String, name: String) raises -> String:
    var parts = query.split("&")
    for i in range(len(parts)):
        var p = String(parts[i])
        var eq = p.find("=")
        var k = p if eq < 0 else _sub(p, 0, eq)
        if k == name:
            return s3_url_decode(String("") if eq < 0 else _sub(p, eq + 1, p.byte_length()))
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
    if st.trap.byte_length() > 0 and s3_url_decode(target).find(st.trap) >= 0:
        return _error(403, "Forbidden", "TrappedKeyRead", is_head)
    var if_match = String("")
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
    var name = s3_url_decode(_sub(path, 1, path.byte_length()))
    if method == "POST" or (method == "PUT" and query.find("uploadId=") >= 0) or (
        method == "DELETE" and query.find("uploadId=") >= 0
    ):
        var answer = _multipart(st, method, name, query, body^)
        st.note_writes()
        return answer^
    if method == "PUT":
        var etag = st.put(name, body^)
        st.puts += 1
        st.note_writes()
        return _response(200, "OK", String("ETag: ") + etag + "\r\n", List[UInt8](), False)
    if method == "DELETE":
        st.remove(name)
        st.deletes += 1
        st.note_writes()
        return _response(204, "No Content", "", List[UInt8](), False)
    var at = st.find(name)
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
        max_requests: Int = -1,
        trap: String = "",
        overwrite_after_reads: Int = -1,
        fail_part: Int = -1,
        fail_complete: Bool = False,
    ):
        self._state = ArcPointer[FakeS3State](
            FakeS3State(max_requests, trap, overwrite_after_reads, fail_part, fail_complete)
        )

    def seed(mut self, key: String, body: String):
        """Stores `body` as `key` of bucket `lake` before any request."""
        _ = self._state[].put(String("lake/") + key, _bytes(body))

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


# =============================================================================
# The file systems.
# =============================================================================


comptime _Fs = S3Fs[FakeS3Connector, StaticCredsSource, FixedClock]

comptime _DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"  # 36 bytes


def _config() raises -> S3Config:
    return S3Config(
        "us-east-1",
        endpoint="http://127.0.0.1:9000",
        addressing=AddressingStyle.path(),
        list_page_size=2,
        retry=RetryPolicy(
            Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
            max_attempts=3,
            deadline_ms=Int64(60_000),
        ),
    )


def _http() -> HttpClientConfig:
    return HttpClientConfig.defaults()


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _fs(mk: def () raises thin -> FakeS3Connector) raises -> _Fs:
    return _Fs.built("lake", _config(), mk, _http(), _creds(), FixedClock(1790000000))


def _seed_tree(mut c: FakeS3Connector):
    c.seed("d/digits", _DIGITS)
    c.seed("d/small", "tiny")
    c.seed("t/a", "1")
    c.seed("t/b", "22")
    c.seed("t/c", "333")
    c.seed("t/sub1/", "")
    c.seed("t/sub1/x", "x")
    c.seed("t/sub1/y", "y")
    c.seed("t/sub2/z", "z")
    c.seed("events.parquet", "not a directory")
    c.seed("u/a", "u")


def _mk_tree() raises -> FakeS3Connector:
    var c = FakeS3Connector()
    _seed_tree(c)
    return c^


def _mk_tree_budget_0() raises -> FakeS3Connector:
    var c = FakeS3Connector(max_requests=0)
    _seed_tree(c)
    return c^


def _mk_tree_budget_1() raises -> FakeS3Connector:
    var c = FakeS3Connector(max_requests=1)
    _seed_tree(c)
    return c^


def _mk_refused() raises -> FakeS3Connector:
    raise Error("no connector here")


# =============================================================================
# Construction and accessors.
# =============================================================================


def test_construction_dials_nothing() raises:
    # The store is built on the first verb, so a factory that cannot make a
    # connector is not called until then.
    var fs = _Fs("lake", _config(), _mk_refused, _http(), _creds(), FixedClock(1790000000))
    assert_equal(fs.bucket(), "lake")
    with assert_raises(contains="no connector here"):
        _ = fs.file_size("d/digits")
    # `built` builds it now.
    with assert_raises(contains="no connector here"):
        _ = _Fs.built("lake", _config(), _mk_refused, _http(), _creds(), FixedClock(1790000000))


def test_accessors() raises:
    var fs = _fs(_mk_tree_budget_0)
    assert_equal(fs.bucket(), "lake")
    var handle = fs.open("data/file.parquet")
    assert_equal(handle.key(), "data/file.parquet")
    assert_equal(fs.prefetch_depth(), 64)
    assert_true(fs.supports_random_read())
    assert_equal(_Fs.SCHEME, FS_SCHEME_S3)
    assert_true(_Fs.SUPPORTS_LAZY_HIVE)
    assert_false(_Fs.SUPPORTS_PARALLEL_WRITES)
    assert_equal(fs.options().prefetch_max_inflight(), 0)
    # A handle and the file system move whole.
    var moved_handle = handle^
    assert_equal(moved_handle.key(), "data/file.parquet")
    var moved = fs^
    assert_equal(moved.bucket(), "lake")
    # Options are the caller's.
    var express = _Fs.built(
        "lake",
        _config(),
        _mk_tree_budget_0,
        _http(),
        _creds(),
        FixedClock(1790000000),
        S3FsOptions(prefetch_max_inflight=4, prefetch_depth=32),
    )
    assert_equal(express.prefetch_depth(), 32)
    assert_equal(express.options().prefetch_max_inflight(), 4)


# =============================================================================
# Reads.
# =============================================================================


def test_read_at() raises:
    var fs = _fs(_mk_tree)
    var f = fs.open("d/digits")
    assert_equal(_buf_text(fs.read_at(f, 3, 4)), "3456")
    assert_equal(_buf_text(fs.read_at(f, 0, 36)), _DIGITS)
    with assert_raises(contains="short read: asked for 4 bytes, got 2"):
        _ = fs.read_at(f, 34, 4)
    with assert_raises(contains="negative offset"):
        _ = fs.read_at(f, -1, 4)
    with assert_raises(contains="negative offset"):
        _ = fs.read_at(f, 0, -4)
    var absent = fs.open("d/absent")
    with assert_raises(contains="StoreError[NOT_FOUND] GetObject s3://lake/d/absent status=404"):
        _ = fs.read_at(absent, 0, 4)


def test_a_zero_length_read_sends_nothing() raises:
    var fs = _fs(_mk_tree_budget_0)
    var f = fs.open("d/digits")
    assert_equal(fs.read_at(f, 5, 0).len(), 0)
    # The budget is real: the first request is refused.
    with assert_raises(contains="RequestBudgetSpent"):
        _ = fs.read_at(f, 5, 1)


def test_read_footer_is_one_request() raises:
    var fs = _fs(_mk_tree_budget_1)
    var region = fs.read_footer("d/digits", 10)
    assert_equal(region.file_size, 36)
    assert_equal(region.offset, 26)
    assert_equal(region.len(), 10)
    assert_equal(_text(region.bytes), "qrstuvwxyz")
    # A second request on this budget is refused, so the footer was one.
    var f = fs.open("d/digits")
    with assert_raises(contains="RequestBudgetSpent"):
        _ = fs.read_at(f, 0, 1)


def test_read_footer_windows() raises:
    var fs = _fs(_mk_tree)
    # A window past the object reads the whole object.
    var whole = fs.read_footer("d/digits", 1000)
    assert_equal(whole.offset, 0)
    assert_equal(whole.file_size, 36)
    assert_equal(_text(whole.bytes), _DIGITS)
    # A window below the 8-byte trailer reads the trailer.
    var trailer = fs.read_footer("d/digits", 2)
    assert_equal(trailer.offset, 28)
    assert_equal(_text(trailer.bytes), "stuvwxyz")
    with assert_raises(contains="object too small for a parquet trailer (size 4 < 8): d/small"):
        _ = fs.read_footer("d/small", 64)
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.read_footer("d/absent", 64)


def test_file_size() raises:
    var fs = _fs(_mk_tree)
    assert_equal(fs.file_size("d/digits"), 36)
    assert_equal(fs.file_size("t/c"), 3)
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/d/absent status=404"):
        _ = fs.file_size("d/absent")


def test_read_ranges_prefetched() raises:
    var fs = _fs(_mk_tree)
    var f = fs.open("d/digits")
    var ranges = List[Tuple[Int64, Int64]]()
    # Input order differs from the object's; the buffers come back in input
    # order, and a zero-length range is an empty buffer.
    ranges.append((Int64(30), Int64(3)))
    ranges.append((Int64(0), Int64(2)))
    ranges.append((Int64(10), Int64(0)))
    ranges.append((Int64(12), Int64(4)))
    var out = fs.read_ranges_prefetched(f, ranges)
    assert_equal(out.len(), 4)
    assert_equal(_buf_text(out[0]), "uvw")
    assert_equal(_buf_text(out[1]), "01")
    assert_equal(out[2].len(), 0)
    assert_equal(_buf_text(out[3]), "cdef")
    # No ranges: no buffers.
    assert_equal(fs.read_ranges_prefetched(f, List[Tuple[Int64, Int64]]()).len(), 0)
    var past = List[Tuple[Int64, Int64]]()
    past.append((Int64(34), Int64(4)))
    with assert_raises(contains="ends past the object"):
        _ = fs.read_ranges_prefetched(f, past)
    var negative = List[Tuple[Int64, Int64]]()
    negative.append((Int64(0), Int64(1)))
    negative.append((Int64(-1), Int64(1)))
    with assert_raises(contains="range 1 has a negative offset"):
        _ = fs.read_ranges_prefetched(f, negative)


def test_near_ranges_are_one_request() raises:
    # Ranges within the coalescing gap are one GetObject.
    var fs = _fs(_mk_tree_budget_1)
    var f = fs.open("d/digits")
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(1), Int64(2)))
    ranges.append((Int64(20), Int64(2)))
    ranges.append((Int64(33), Int64(3)))
    var out = fs.read_ranges_prefetched(f, ranges)
    assert_equal(_buf_text(out[0]), "12")
    assert_equal(_buf_text(out[1]), "kl")
    assert_equal(_buf_text(out[2]), "xyz")


comptime _BIG = 1_100_010  # past the coalescing gap (1 MiB) between two ranges


def _alphabet(n: Int) -> String:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(0x61 + i % 26))
    return String(unsafe_from_utf8=Span(out))


def _mk_big() raises -> FakeS3Connector:
    var c = FakeS3Connector()
    c.seed("r/big", _alphabet(_BIG))
    return c^


def _mk_big_overwritten_after_get() raises -> FakeS3Connector:
    var c = FakeS3Connector(overwrite_after_reads=1)
    c.seed("r/big", _alphabet(_BIG))
    return c^


def _two_far_ranges() -> List[Tuple[Int64, Int64]]:
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(0), Int64(3)))
    ranges.append((Int64(1_100_000), Int64(3)))
    return ranges^


def test_a_prefetch_reads_one_version() raises:
    # Two ranges too far apart to coalesce are two GETs. Untouched, both
    # land.
    var fs = _Fs.built(
        "lake",
        _config(),
        _mk_big,
        _http(),
        _creds(),
        FixedClock(1790000000),
        S3FsOptions(prefetch_max_inflight=1),
    )
    var f = fs.open("r/big")
    var out = fs.read_ranges_prefetched(f, _two_far_ranges())
    assert_equal(_buf_text(out[0]), "abc")
    assert_equal(_buf_text(out[1]), "stu")
    # Overwritten after the first GET: the second carries the first one's
    # ETag in If-Match (the handle's, pinned by the first answer), is
    # answered 412, and the read raises rather than return bytes of two
    # versions. The second GET is the only one left after the first, so it
    # goes on store 0, whose fake was overwritten.
    var g = _fs(_mk_big_overwritten_after_get)
    var h = g.open("r/big")
    with assert_raises(contains="StoreError[PRECONDITION] GetObject s3://lake/r/big status=412"):
        _ = g.read_ranges_prefetched(h, _two_far_ranges())


# =============================================================================
# Listing.
# =============================================================================


def test_list_is_recursive_bare_keys() raises:
    var fs = _fs(_mk_tree)
    # Pages of two: every page is drained.
    var keys = fs.list("t/")
    assert_equal(len(keys), 7)
    assert_equal(keys[0], "t/a")
    assert_equal(keys[2], "t/c")
    assert_equal(keys[3], "t/sub1/")
    assert_equal(keys[4], "t/sub1/x")
    assert_equal(keys[6], "t/sub2/z")
    assert_equal(len(fs.list("nothing/")), 0)
    # What list returns, open takes.
    var f = fs.open(keys[2])
    assert_equal(_buf_text(fs.read_at(f, 0, 3)), "333")


def test_is_dir() raises:
    var fs = _fs(_mk_tree)
    assert_true(fs.is_dir("t"))
    assert_true(fs.is_dir("t/"))
    assert_true(fs.is_dir("t/sub1"))
    # A key is not a directory, and `events` does not match the sibling
    # object `events.parquet`.
    assert_false(fs.is_dir("t/a"))
    assert_false(fs.is_dir("events"))
    assert_false(fs.is_dir("nothing"))
    # The empty path is the bucket root, which holds keys.
    assert_true(fs.is_dir(""))


def _mk_empty() raises -> FakeS3Connector:
    return FakeS3Connector()


def test_is_dir_of_an_empty_bucket() raises:
    var fs = _fs(_mk_empty)
    assert_false(fs.is_dir(""))
    assert_false(fs.is_dir("t"))


def test_list_dir_shallow() raises:
    var fs = _fs(_mk_tree)
    var entries = fs.list_dir_shallow("t")
    # Directories first, then files; pages of two drained.
    assert_equal(len(entries), 5)
    assert_equal(entries[0].name, "sub1")
    assert_true(entries[0].is_dir)
    assert_equal(entries[1].name, "sub2")
    assert_true(entries[1].is_dir)
    assert_equal(entries[2].name, "a")
    assert_false(entries[2].is_dir)
    assert_equal(entries[4].name, "c")
    # The placeholder object `t/sub1/` is the directory itself, skipped.
    var sub = fs.list_dir_shallow("t/sub1/")
    assert_equal(len(sub), 2)
    assert_equal(sub[0].name, "x")
    assert_equal(sub[1].name, "y")
    # The bucket root: top-level prefixes and objects.
    var root = fs.list_dir_shallow("")
    assert_equal(len(root), 4)
    assert_equal(root[0].name, "d")
    assert_equal(root[1].name, "t")
    assert_equal(root[2].name, "u")
    assert_equal(root[3].name, "events.parquet")
    assert_false(root[3].is_dir)


# =============================================================================
# Writes, clones.
# =============================================================================


comptime _PART = 5 * 1024 * 1024  # S3's smallest part


def _pattern(n: Int, seed: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + seed) % 251))
    return out^


def _small_parts() raises -> S3FsOptions:
    # One part in flight: the fake keeps its objects per connector, so parts
    # sent on the extra stores of a larger bound would land in fakes that
    # store 0's completion cannot see. test_s3_fs_inflight covers the bound.
    return S3FsOptions(upload_part_bytes=_PART, upload_max_inflight=1)


def _fs_parts(mk: def () raises thin -> FakeS3Connector) raises -> _Fs:
    return _Fs.built("lake", _config(), mk, _http(), _creds(), FixedClock(1790000000), _small_parts())


def _writes(fs: _Fs) raises -> String:
    """What the fake's write verbs did (`FakeS3State.note_writes`)."""
    var f = fs.open("~fake/writes")
    return _buf_text(fs.read_at(f, 0, Int64(fs.file_size("~fake/writes"))))


def _assert_object(fs: _Fs, key: String, expected: List[UInt8]) raises:
    assert_equal(fs.file_size(key), len(expected))
    var f = fs.open(key)
    var got = fs.read_at(f, 0, Int64(len(expected)))
    var view = got.view_range_ro(0, got.len()).into_span()
    for i in range(len(expected)):
        if view[i] != expected[i]:
            raise Error(String("byte ") + String(i) + " of " + key + " differs")


def _mk_writes_budget_2() raises -> FakeS3Connector:
    return FakeS3Connector(max_requests=2)


def test_a_small_object_is_one_put() raises:
    # open_write sends nothing; the bytes go in ONE PutObject at close, and
    # a read of them is the second request of a budget of two.
    var fs = _fs(_mk_writes_budget_2)
    var w = fs.open_write("w/small", WriteMode.create_truncate())
    assert_equal(w.key(), "w/small")
    assert_equal(fs.write_at(w, Span(_bytes("hello, "))), 7)
    assert_equal(fs.write_at(w, Span(_bytes("world"))), 5)
    assert_equal(fs.write_at(w, Span(List[UInt8]())), 0)
    assert_equal(w.bytes_written(), 12)
    assert_equal(w.upload_id(), "")
    fs.close_write(w^)
    var f = fs.open("w/small")
    assert_equal(_buf_text(fs.read_at(f, 0, 12)), "hello, world")
    with assert_raises(contains="RequestBudgetSpent"):
        _ = fs.read_at(f, 0, 1)


def test_an_empty_object() raises:
    var fs = _fs(_mk_empty)
    var w = fs.open_write("w/empty", WriteMode.create_truncate())
    fs.close_write(w^)
    assert_equal(fs.file_size("w/empty"), 0)
    assert_equal(_writes(fs), "created=0 open=0 parts_held=0 completed=0 aborted=0 puts=1 deletes=0")


def test_a_large_object_is_a_multipart_upload() raises:
    # 2 parts and 7 bytes, written in pieces that straddle the part
    # boundaries: each full part is sent as it fills, the first creating
    # the upload; close sends the 7 bytes as the last part and completes.
    var fs = _fs_parts(_mk_empty)
    var total = 2 * _PART + 7
    var data = _pattern(total, 3)
    var w = fs.open_write("w/large", WriteMode.create_truncate())
    var piece = 1024 * 1024 + 3
    var at = 0
    while at < total:
        var take = min(piece, total - at)
        assert_equal(fs.write_at(w, Span(data)[at : at + take]), Int64(take))
        at += take
        if at < _PART:
            assert_equal(w.upload_id(), "")
    assert_equal(w.upload_id(), "up-0")
    assert_equal(w.parts_sent(), 2)
    assert_equal(w.bytes_written(), Int64(total))
    fs.close_write(w^)
    _assert_object(fs, "w/large", data)
    assert_equal(_writes(fs), "created=1 open=0 parts_held=0 completed=1 aborted=0 puts=0 deletes=0")


def test_an_object_of_whole_parts_sends_no_empty_part() raises:
    # Exactly two parts: both are sent by write_at, and close only completes.
    var fs = _fs_parts(_mk_empty)
    var data = _pattern(2 * _PART, 5)
    var w = fs.open_write("w/whole", WriteMode.create_truncate())
    _ = fs.write_at(w, Span(data))
    assert_equal(w.parts_sent(), 2)
    fs.close_write(w^)
    _assert_object(fs, "w/whole", data)
    assert_equal(_writes(fs), "created=1 open=0 parts_held=0 completed=1 aborted=0 puts=0 deletes=0")


def _mk_fail_part_2() raises -> FakeS3Connector:
    return FakeS3Connector(fail_part=2)


def test_a_failed_part_aborts_the_upload() raises:
    var fs = _fs_parts(_mk_fail_part_2)
    var w = fs.open_write("w/failed", WriteMode.create_truncate())
    with assert_raises(contains="InjectedFault"):
        _ = fs.write_at(w, Span(_pattern(2 * _PART, 1)))
    # The upload was aborted before the error was raised, and its part
    # dropped; the handle is refused from then on.
    assert_equal(_writes(fs), "created=1 open=0 parts_held=0 completed=0 aborted=1 puts=0 deletes=0")
    with assert_raises(contains="S3Fs.write_at: the upload of w/failed failed and was aborted"):
        _ = fs.write_at(w, Span(_bytes("x")))
    with assert_raises(contains="S3Fs.close_write: the upload of w/failed failed and was aborted"):
        fs.close_write(w^)
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.file_size("w/failed")
    # abort_write after a failure sends nothing more.
    var v = fs.open_write("w/failed", WriteMode.create_truncate())
    with assert_raises(contains="InjectedFault"):
        _ = fs.write_at(v, Span(_pattern(2 * _PART, 1)))
    fs.abort_write(v^)
    assert_equal(_writes(fs), "created=2 open=0 parts_held=0 completed=0 aborted=2 puts=0 deletes=0")


def _mk_fail_complete() raises -> FakeS3Connector:
    return FakeS3Connector(fail_complete=True)


def test_a_failed_completion_aborts_the_upload() raises:
    var fs = _fs_parts(_mk_fail_complete)
    var w = fs.open_write("w/incomplete", WriteMode.create_truncate())
    _ = fs.write_at(w, Span(_pattern(_PART + 1, 2)))
    with assert_raises(contains="StoreError[PERMISSION_DENIED] CompleteMultipartUpload"):
        fs.close_write(w^)
    assert_equal(_writes(fs), "created=1 open=0 parts_held=0 completed=0 aborted=1 puts=0 deletes=0")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.file_size("w/incomplete")


def _mk_writes_budget_0() raises -> FakeS3Connector:
    return FakeS3Connector(max_requests=0)


def test_abort_write() raises:
    # A part sent: the upload is aborted, and no object is made.
    var fs = _fs_parts(_mk_empty)
    var w = fs.open_write("w/aborted", WriteMode.create_truncate())
    _ = fs.write_at(w, Span(_pattern(_PART + 9, 4)))
    assert_equal(w.parts_sent(), 1)
    fs.abort_write(w^)
    assert_equal(_writes(fs), "created=1 open=0 parts_held=0 completed=0 aborted=1 puts=0 deletes=0")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.file_size("w/aborted")
    # No part sent: nothing to abort, and nothing is sent.
    var quiet = _fs_parts(_mk_writes_budget_0)
    var v = quiet.open_write("w/never", WriteMode.create_truncate())
    _ = quiet.write_at(v, Span(_bytes("buffered")))
    quiet.abort_write(v^)
    with assert_raises(contains="RequestBudgetSpent"):
        _ = quiet.read_footer("d/digits", 8)


def test_refused_writes() raises:
    var fs = _fs(_mk_writes_budget_0)
    with assert_raises(contains="S3Fs.open_write: an S3 object cannot be appended to (WriteMode.append): w/a"):
        _ = fs.open_write("w/a", WriteMode.append())
    with assert_raises(contains="S3Fs.open_write: WriteMode.create_exclusive is not supported"):
        _ = fs.open_write("w/a", WriteMode.create_exclusive())
    var w = fs.open_write("w/a", WriteMode.create_truncate())
    with assert_raises(contains="S3Fs.pwrite_at: S3 has no disjoint-range concurrent write"):
        _ = fs.pwrite_at(w, 0, Span(_bytes("x")))
    # Nothing above sent a request: the budget's first is refused.
    with assert_raises(contains="RequestBudgetSpent"):
        fs.close_write(w^)


def test_delete() raises:
    var fs = _fs(_mk_tree)
    fs.delete("t/a")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.file_size("t/a")
    assert_equal(len(fs.list("t/")), 6)
    # An absent key: deleted already, not an error.
    fs.delete("t/a")
    fs.delete("never/was")
    assert_equal(_writes(fs), "created=0 open=0 parts_held=0 completed=0 aborted=0 puts=0 deletes=3")
    # Durable at write: the fsyncs do nothing, and send nothing.
    fs.fsync_file("t/b")
    fs.fsync_dir("t")


def test_a_clone_builds_its_own_store() raises:
    var fs = _fs(_mk_tree_budget_1)
    var c = fs.clone()
    assert_equal(c.bucket(), "lake")
    assert_equal(c.prefetch_depth(), 64)
    # Each spends its own budget of one request: the clone's store is its
    # own, built on its first verb.
    var fb = fs.open("t/b")
    var fc = c.open("t/c")
    assert_equal(_buf_text(fs.read_at(fb, 0, 2)), "22")
    assert_equal(_buf_text(c.read_at(fc, 0, 3)), "333")
    with assert_raises(contains="RequestBudgetSpent"):
        _ = fs.read_at(fb, 0, 2)
    with assert_raises(contains="RequestBudgetSpent"):
        _ = c.read_at(fc, 0, 3)


# =============================================================================
# The Hive partition prune.
# =============================================================================


def _seed_hive(mut c: FakeS3Connector):
    c.seed("t/region=eu/part-0.parquet", "eu-0 rows....PAR1")
    c.seed("t/region=us/part-0.parquet", "us-0 rows....PAR1")
    c.seed("t/region=us/part-1.parquet", "us-1 rows......PAR1")


def _mk_hive_eu_trapped() raises -> FakeS3Connector:
    var c = FakeS3Connector(trap="region=eu")
    _seed_hive(c)
    return c^


def _region_cols() -> List[String]:
    var c = List[String]()
    c.append(String("region"))
    return c^


def _region_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.STRING)
    return t^


def _region_eq(value: String) -> PartitionPredicate:
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.eq(String("region"), value, ArrowType.STRING))
    return PartitionPredicate(constraints=preds^)


def test_a_pruned_partition_is_never_read() raises:
    var fs = _fs(_mk_hive_eu_trapped)
    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        String("t/"),
        _region_cols(),
        _region_types(),
        _region_eq("us"),
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), "t/region=us/part-0.parquet")
    assert_equal(disc.path_at(1), "t/region=us/part-1.parquet")
    # Read every survivor as a reader does: its footer, its size, a range.
    # A request into region=eu would be refused, naming it.
    for i in range(disc.num_paths()):
        var path = disc.path_at(i)
        var footer = fs.read_footer(path, 8)
        assert_equal(_text(footer.bytes), "....PAR1")
        assert_equal(fs.file_size(path), footer.file_size)
        var f = fs.open(path)
        assert_equal(_buf_text(fs.read_at(f, 0, 4)), "us-" + String(i))
        var ranges = List[Tuple[Int64, Int64]]()
        ranges.append((Int64(0), Int64(2)))
        ranges.append((Int64(footer.file_size - 4), Int64(4)))
        var both = fs.read_ranges_prefetched(f, ranges)
        assert_equal(_buf_text(both[0]), "us")
        assert_equal(_buf_text(both[1]), "PAR1")


def test_the_trap_is_live() raises:
    var fs = _fs(_mk_hive_eu_trapped)
    # region IN (us, eu) lists the eu prefix: refused.
    var vals = List[String]()
    vals.append(String("us"))
    vals.append(String("eu"))
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.in_list(String("region"), vals, ArrowType.STRING))
    with assert_raises(contains="TrappedKeyRead"):
        _ = PrunedHiveDiscovery.open_pruned(
            fs,
            String("t/"),
            _region_cols(),
            _region_types(),
            PartitionPredicate(constraints=preds^),
            GlobDiscoveryOptions.default(),
        )
    # A pruned partition is read when, and only when, a caller asks for it.
    # The UNPRUNED listing of the base names every partition, and its first
    # file is in region=eu: a caller taking a schema from that file reads
    # the pruned partition.
    var unpruned = PrunedHiveDiscovery.open(fs, String("t/"))
    assert_equal(unpruned.num_paths(), 3)
    assert_equal(unpruned.path_at(0), "t/region=eu/part-0.parquet")
    with assert_raises(contains="StoreError[PERMISSION_DENIED] GetObject s3://lake/t/region=eu/part-0.parquet"):
        _ = fs.read_footer(unpruned.path_at(0), 8)


def main() raises:
    test_construction_dials_nothing()
    test_accessors()
    test_read_at()
    test_a_zero_length_read_sends_nothing()
    test_read_footer_is_one_request()
    test_read_footer_windows()
    test_file_size()
    test_read_ranges_prefetched()
    test_near_ranges_are_one_request()
    test_a_prefetch_reads_one_version()
    test_list_is_recursive_bare_keys()
    test_is_dir()
    test_list_dir_shallow()
    test_is_dir_of_an_empty_bucket()
    test_a_small_object_is_one_put()
    test_an_empty_object()
    test_a_large_object_is_a_multipart_upload()
    test_an_object_of_whole_parts_sends_no_empty_part()
    test_a_failed_part_aborts_the_upload()
    test_a_failed_completion_aborts_the_upload()
    test_abort_write()
    test_refused_writes()
    test_delete()
    test_a_clone_builds_its_own_store()
    test_a_pruned_partition_is_never_read()
    test_the_trap_is_live()
    print("OK")
