# S3ConditionalStore, komira_objectstore's conformer for one S3 bucket, run
# against a fake S3 that keeps objects in memory: `FakeS3Connector`, a
# komira_http_core Connector whose streams parse each HTTP request the store
# sends (through the generated client, komira_aws_core's signer and
# komira_http_client) and answer it as S3 does, honouring If-None-Match: *
# and If-Match. Its state lives behind an Arc the connector shares with
# every stream it dials, so it outlives each connection. No socket.
#
# Rows: create-if-absent wins once and then loses with a 412; a
# compare-and-swap with the current ETag wins and with a stale one loses; an
# unconditional put overwrites; get, get_range (exact, and a short read
# refused), head and delete (an absent key is not an error); a listing with
# a delimiter over several pages; get_ranges scattering coalesced ranges
# into a caller's buffer in input order, and reading one version of an
# object overwritten during the fetch (412, not torn bytes); a clone that
# builds its own store.
#
# Then each status S3 can answer a conditional PutObject with, as the named
# StoreError kind a caller branches on (each over a ScriptedConnector):
# 403, 404, 409 ConditionalRequestConflict, 412, 429, 500 and 503.
#
# Then komira_objectstore's CasManifestStore over S3: when S3 answers a
# conditional write with 409 ConditionalRequestConflict, as it does when two
# conditional writes race on one key, the append reads again and retries, as
# for a 412. A 409 classified as MALFORMED would end a compare-and-swap loop
# that retries only a lost precondition.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_core.collections.byte_view import ByteView
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy as CasRetry
from komira_objectstore.path import Path
from komira_objectstore.types import (
    GetRange,
    RangeSet,
    STORE_ERR_MALFORMED,
    STORE_ERR_NOT_FOUND,
    STORE_ERR_PERMISSION_DENIED,
    STORE_ERR_PRECONDITION,
    STORE_ERR_THROTTLED,
    STORE_ERR_TRANSPORT,
    WritePrecondition,
)
from komira_objectstore_s3 import (
    AddressingStyle,
    S3Config,
    S3ConditionalStore,
    s3_url_decode,
    store_error_kind_from_message,
)
from komira_retry import Backoff, Jitter, RetryPolicy


# =============================================================================
# The fake S3.
# =============================================================================


struct FakeS3State(Movable):
    """The objects of every bucket (`<bucket>/<key>` -> body, ETag), kept
    sorted by name, and the faults still to inject."""

    var names: List[String]
    var bodies: List[List[UInt8]]
    var etags: List[String]
    var next_etag: Int
    # The next `conflicts` conditional PutObjects are answered 409
    # ConditionalRequestConflict, writing nothing.
    var conflicts: Int
    # Once this many GETs and HEADs have been answered, the object the last
    # one read is overwritten (its first byte changed, a new ETag), as by a
    # writer racing a reader. -1 for never.
    var overwrite_after_reads: Int
    var reads: Int
    var requests: Int

    def __init__(out self, conflicts: Int = 0, overwrite_after_reads: Int = -1):
        self.names = List[String]()
        self.bodies = List[List[UInt8]]()
        self.etags = List[String]()
        self.next_etag = 1
        self.conflicts = conflicts
        self.overwrite_after_reads = overwrite_after_reads
        self.reads = 0
        self.requests = 0

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

    def remove(mut self, name: String):
        var at = self.find(name)
        if at >= 0:
            _ = self.names.pop(at)
            _ = self.bodies.pop(at)
            _ = self.etags.pop(at)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


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
    var body = List[UInt8]()
    body.extend(Span(written)[end + 4 : n])
    var lines = head.split("\r\n")
    var request_line = String(lines[0]).split(" ")
    var method = String(request_line[0])
    var target = String(request_line[1])
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
    var is_head = method == "HEAD"
    if slash < 0:
        var bucket = _sub(path, 1, path.byte_length())
        if method == "GET" and query.find("list-type=2") >= 0:
            return _list(st, bucket, query)
        return _error(400, "Bad Request", "NotImplemented", is_head)
    var name = s3_url_decode(_sub(path, 1, path.byte_length()))
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
        return _response(200, "OK", String("ETag: ") + etag + "\r\n", List[UInt8](), False)
    if method == "DELETE":
        st.remove(name)
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


def _read(st: FakeS3State, at: Int, range_: String, is_head: Bool) raises -> List[UInt8]:
    """The answer to a GET or HEAD of the object at `at`."""
    ref obj = st.bodies[at]
    var etag_header = String("ETag: ") + st.etags[at] + "\r\n"
    if range_.byte_length() > 0 and not is_head:
        # bytes=a-b only: what S3ConditionalStore.get_range sends.
        var spec = _sub(range_, 6, range_.byte_length())
        var dash = spec.find("-")
        var first = Int(_sub(spec, 0, dash))
        var last = Int(_sub(spec, dash + 1, spec.byte_length()))
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
    state, as the echo stream of komira_aws_core does."""

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

    def __init__(out self, conflicts: Int = 0, overwrite_after_reads: Int = -1):
        self._state = ArcPointer[FakeS3State](
            FakeS3State(conflicts, overwrite_after_reads)
        )

    def seed(mut self, name: String, var body: List[UInt8]):
        """Stores `body` as `<bucket>/<key>` `name` before any request."""
        _ = self._state[].put(name, body^)

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
# The stores.
# =============================================================================


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


comptime _Fake = S3ConditionalStore[FakeS3Connector, StaticCredsSource, FixedClock]


def _mk_fake() raises -> FakeS3Connector:
    return FakeS3Connector()


def _mk_fake_one_conflict() raises -> FakeS3Connector:
    return FakeS3Connector(conflicts=1)


def _fake() raises -> _Fake:
    return _Fake.built("lake", _config(), _mk_fake, _http(), _creds(), FixedClock(1790000000))


def _p(s: String) raises -> Path:
    return Path.parse(s)


def test_create_if_absent_and_compare_and_swap() raises:
    var s = _fake()
    var m1 = s.conditional_put(_p("m/v.json"), _bytes("one"), WritePrecondition.if_none_match_star())
    assert_true(m1.etag.byte_length() > 0)
    assert_equal(m1.etag, m1.version)
    # A second create loses: the key exists.
    with assert_raises(contains="StoreError[PRECONDITION] PutObject s3://lake/m/v.json status=412"):
        _ = s.conditional_put(_p("m/v.json"), _bytes("two"), WritePrecondition.if_none_match_star())
    # A CAS with the current ETag wins and returns the next handle.
    var m2 = s.compare_and_swap(_p("m/v.json"), _bytes("two"), m1.etag)
    assert_true(m2.etag != m1.etag)
    # A CAS with the stale ETag loses.
    with assert_raises(contains="status=412"):
        _ = s.compare_and_swap(_p("m/v.json"), _bytes("three"), m1.etag)
    assert_equal(_text(s.get(_p("m/v.json"))), "two")
    # An unconditional put overwrites.
    var m3 = s.put(_p("m/v.json"), _bytes("four"))
    assert_equal(s.head(_p("m/v.json")).etag, m3.etag)
    assert_equal(s.head(_p("m/v.json")).size, 4)
    # A CAS on an absent key: S3 answers 404.
    with assert_raises(contains="StoreError[NOT_FOUND] PutObject s3://lake/absent status=404"):
        _ = s.compare_and_swap(_p("absent"), _bytes("x"), m3.etag)


def test_reads_and_delete() raises:
    var s = _fake()
    _ = s.put(_p("d/obj"), _bytes("0123456789"))
    assert_equal(_text(s.get_range(_p("d/obj"), 3, 4)), "3456")
    assert_equal(len(s.get_range(_p("d/obj"), 3, 0)), 0)
    with assert_raises(contains="short read: asked for 4 bytes, got 2"):
        _ = s.get_range(_p("d/obj"), 8, 4)
    with assert_raises(contains="negative start"):
        _ = s.get_range(_p("d/obj"), -1, 4)
    s.delete(_p("d/obj"))
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/d/obj status=404"):
        _ = s.head(_p("d/obj"))
    # Deleting an absent key is not an error.
    s.delete(_p("d/obj"))


def test_list_with_delimiter() raises:
    var s = _fake()
    for name in ["t/a", "t/b", "t/c", "t/sub1/x", "t/sub1/y", "t/sub2/z", "u/a"]:
        _ = s.put(_p(name), _bytes("v"))
    # Pages of two: the listing is drained across pages.
    var r = s.list_with_delimiter(_p("t/"))
    assert_equal(len(r.objects), 3)
    assert_equal(r.objects[0].location, "t/a")
    assert_equal(r.objects[2].location, "t/c")
    assert_equal(r.objects[1].size, 1)
    assert_equal(len(r.common_prefixes), 2)
    assert_equal(r.common_prefixes[0], "t/sub1/")
    assert_equal(r.common_prefixes[1], "t/sub2/")


def test_get_ranges() raises:
    var s = _fake()
    _ = s.put(_p("r/obj"), _bytes("abcdefghijklmnopqrstuvwxyz"))
    var ranges = RangeSet.empty()
    # Input order differs from the object's: the plan sorts and merges, the
    # bytes land at each range's own offset, the result is in input order.
    ranges.append(GetRange.bounded(20, 23), 0)
    ranges.append(GetRange.bounded(0, 2), 3)
    ranges.append(GetRange.suffix(2), 5)
    var dst = List[UInt8](length=7, fill=UInt8(0))
    var view = ByteView[origin_of(dst)](dst.unsafe_ptr(), 7)
    var res = s.get_ranges(_p("r/obj"), ranges, view)
    _ = view
    assert_equal(_text(dst), "uvwabyz")
    assert_equal(res.fetched_bytes_at(0), 3)
    assert_equal(res.fetched_bytes_at(1), 2)
    assert_equal(res.fetched_bytes_at(2), 2)
    assert_equal(res.total_fetched_bytes, 7)


comptime _BIG = 1_100_010  # past the coalescing gap (1 MiB) between two ranges


def _alphabet(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(0x61 + i % 26))
    return out^


def _mk_fake_overwritten_after_head() raises -> FakeS3Connector:
    var c = FakeS3Connector(overwrite_after_reads=1)
    c.seed("lake/r/obj", _alphabet(26))
    return c^


def _mk_fake_big() raises -> FakeS3Connector:
    var c = FakeS3Connector()
    c.seed("lake/r/big", _alphabet(_BIG))
    return c^


def _mk_fake_big_overwritten_after_get() raises -> FakeS3Connector:
    var c = FakeS3Connector(overwrite_after_reads=1)
    c.seed("lake/r/big", _alphabet(_BIG))
    return c^


def _two_far_ranges() raises -> RangeSet:
    var ranges = RangeSet.empty()
    ranges.append(GetRange.bounded(0, 3), 0)
    ranges.append(GetRange.bounded(1_100_000, 1_100_003), 3)
    return ranges^


def test_a_range_fetch_reads_one_version() raises:
    # Two ranges too far apart to coalesce are two GETs. Untouched, both
    # land.
    var b = _Fake.built("lake", _config(), _mk_fake_big, _http(), _creds(), FixedClock(1790000000))
    var dst = List[UInt8](length=6, fill=UInt8(0))
    var view = ByteView[origin_of(dst)](dst.unsafe_ptr(), 6)
    _ = b.get_ranges(_p("r/big"), _two_far_ranges(), view)
    _ = view
    assert_equal(_text(dst), "abcstu")
    # Overwritten after the first GET: the second carries the first one's
    # ETag in If-Match, is answered 412, and the fetch raises rather than
    # return bytes of two versions.
    var g = _Fake.built(
        "lake", _config(), _mk_fake_big_overwritten_after_get, _http(), _creds(), FixedClock(1790000000)
    )
    var dst2 = List[UInt8](length=6, fill=UInt8(0))
    var view2 = ByteView[origin_of(dst2)](dst2.unsafe_ptr(), 6)
    with assert_raises(contains="StoreError[PRECONDITION] GetObject s3://lake/r/big status=412"):
        _ = g.get_ranges(_p("r/big"), _two_far_ranges(), view2)
    _ = view2
    # A suffix range sends a HEAD for the size first; overwritten after it,
    # the GET carries the HEAD's ETag and is answered 412.
    var h = _Fake.built(
        "lake", _config(), _mk_fake_overwritten_after_head, _http(), _creds(), FixedClock(1790000000)
    )
    var ranges = RangeSet.empty()
    ranges.append(GetRange.suffix(2), 0)
    var dst3 = List[UInt8](length=2, fill=UInt8(0))
    var view3 = ByteView[origin_of(dst3)](dst3.unsafe_ptr(), 2)
    with assert_raises(contains="StoreError[PRECONDITION] GetObject s3://lake/r/obj status=412"):
        _ = h.get_ranges(_p("r/obj"), ranges, view3)
    _ = view3


def test_clone_builds_its_own_store() raises:
    var s = _fake()
    _ = s.put(_p("c/k"), _bytes("v"))
    var c = s.clone()
    assert_equal(c.bucket(), "lake")
    # The clone's store is its own (here, its own fake S3: a fresh, empty
    # one from the factory), built on its first verb.
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = c.head(_p("c/k"))
    assert_equal(_text(s.get(_p("c/k"))), "v")


# =============================================================================
# Each status, as the StoreError kind a caller branches on.
# =============================================================================


def _mk_status[status: Int, code: StringLiteral]() raises -> ScriptedConnector:
    var stream = ScriptedStream.from_read_script(_error(status, "Status", String(code), False))
    var c = ScriptedConnector.with_stream(stream^)
    # A throttle (503 SlowDown, 429) is resent even for a conditional write,
    # and gets the same answer again; a conditional 500 is not resent.
    c.arm_next(ScriptedStream.from_read_script(_error(status, "Status", String(code), False)))
    c.arm_next(ScriptedStream.from_read_script(_error(status, "Status", String(code), False)))
    return c^


def _kind_of(mk: def () raises thin -> ScriptedConnector) raises -> UInt8:
    var s = S3ConditionalStore[ScriptedConnector, StaticCredsSource, FixedClock].built(
        "lake", _config(), mk, _http(), _creds(), FixedClock(1790000000)
    )
    try:
        _ = s.conditional_put(_p("k"), _bytes("v"), WritePrecondition.if_match('"e"'))
    except e:
        return store_error_kind_from_message(String(e))
    raise Error("the conditional put succeeded")


def test_each_status_is_a_named_error() raises:
    assert_equal(_kind_of(_mk_status[403, "AccessDenied"]), STORE_ERR_PERMISSION_DENIED)
    assert_equal(_kind_of(_mk_status[404, "NoSuchKey"]), STORE_ERR_NOT_FOUND)
    assert_equal(_kind_of(_mk_status[409, "ConditionalRequestConflict"]), STORE_ERR_PRECONDITION)
    assert_equal(_kind_of(_mk_status[412, "PreconditionFailed"]), STORE_ERR_PRECONDITION)
    assert_equal(_kind_of(_mk_status[429, "TooManyRequests"]), STORE_ERR_THROTTLED)
    assert_equal(_kind_of(_mk_status[500, "InternalError"]), STORE_ERR_TRANSPORT)
    assert_equal(_kind_of(_mk_status[503, "SlowDown"]), STORE_ERR_THROTTLED)
    assert_equal(_kind_of(_mk_status[400, "InvalidArgument"]), STORE_ERR_MALFORMED)


# =============================================================================
# The CAS writer over S3, meeting a 409.
# =============================================================================


def test_cas_append_retries_a_409_conflict() raises:
    var store = _Fake.built(
        "lake", _config(), _mk_fake_one_conflict, _http(), _creds(), FixedClock(1790000000)
    )
    var manifest = CasManifestStore[_Fake](
        store=store^, prefix=String("topic/p0"), retry=CasRetry.fast_test()
    )
    # The first conditional write is answered 409 ConditionalRequestConflict:
    # nothing was written, so the append reads again and retries.
    var first = manifest.append(_bytes("record-0"), Int64(1))
    assert_equal(first.chunk_seq, Int64(0))
    assert_equal(first.base_offset, Int64(0))
    assert_true(first.attempts >= 2)
    var second = manifest.append(_bytes("record-1"), Int64(1))
    assert_equal(second.chunk_seq, Int64(1))
    assert_equal(second.base_offset, Int64(1))
    assert_equal(_text(manifest.read_chunk(Int64(0))), "record-0")
    assert_equal(_text(manifest.read_chunk(Int64(1))), "record-1")
    assert_equal(manifest.read_head().chunk_seq, Int64(1))


def main() raises:
    test_cas_append_retries_a_409_conflict()
    test_create_if_absent_and_compare_and_swap()
    test_reads_and_delete()
    test_list_with_delimiter()
    test_get_ranges()
    test_a_range_fetch_reads_one_version()
    test_clone_builds_its_own_store()
    test_each_status_is_a_named_error()
    print("OK")
