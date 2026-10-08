# S3Fs reads ONE version of an object per file handle. The handle keeps the
# ETag its first read answered, and every later read on it (read_at,
# read_ranges_prefetched, read_footer_of) sends `If-Match` with that ETag, so
# an object overwritten while the handle is in use raises the handle's
# PRECONDITION error instead of returning bytes of two versions.
#
# The fake S3 here keeps objects in memory and answers ranged, suffix and
# whole GETs. It may be told to overwrite an object after it has answered N
# reads (the object's first byte flips case and it gets a new ETag), and it
# records the `If-Match` of each GET as the object `~fake/if-match` (a
# newline per GET, "-" when the GET carried none), which a row reads through
# a second handle. No socket.
#
# Rows:
#  * read_at, then the object is overwritten: the next read_at on the handle
#    raises the named error, and a new handle reads the new version.
#  * read_at, then an overwrite, then read_ranges_prefetched on the same
#    handle: refused the same way (the prefetch is pinned to the handle, not
#    only to its own first request).
#  * two prefetches on one handle with an overwrite between them: refused.
#  * an object left alone: the reads after the first carry the first one's
#    ETag in If-Match, and the first carries none.
#  * read_footer_of pins the handle, so a column read after an overwrite
#    that came between the footer and the columns is refused; and a footer
#    read through a handle already pinned to an older version is refused.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_raises

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedStream
from komira_objectstore_s3 import AddressingStyle, S3Config, S3Fs
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _BODY = "abcdefghijklmnopqrstuvwxyz0123456789"  # 36 bytes


struct _State(Movable):
    var names: List[String]
    var bodies: List[List[UInt8]]
    var etags: List[String]
    var next_etag: Int
    var reads: Int
    # After this many GETs the object the last one read is overwritten. -1
    # for never.
    var overwrite_after: Int
    var if_matches: String

    def __init__(out self, overwrite_after: Int):
        self.names = List[String]()
        self.bodies = List[List[UInt8]]()
        self.etags = List[String]()
        self.next_etag = 1
        self.reads = 0
        self.overwrite_after = overwrite_after
        self.if_matches = String("")

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def put(mut self, name: String, var body: List[UInt8]):
        var etag = String('"etag-') + String(self.next_etag) + '"'
        self.next_etag += 1
        var at = self.find(name)
        if at >= 0:
            self.bodies[at] = body^
            self.etags[at] = etag^
            return
        self.names.append(name)
        self.bodies.append(body^)
        self.etags.append(etag^)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _sub(s: String, i: Int, j: Int) -> String:
    return String(s[byte=i:j])


def _response(status: Int, reason: String, headers: String, body: List[UInt8]) -> List[UInt8]:
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
    out.extend(Span(body))
    return out^


def _error(status: Int, reason: String, code: String) -> List[UInt8]:
    return _response(
        status,
        reason,
        "Content-Type: application/xml\r\n",
        _bytes(String("<Error><Code>") + code + "</Code><Message>fake</Message></Error>"),
    )


def _serve(mut st: _State, written: List[UInt8]) raises -> List[UInt8]:
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
    if method != "GET":
        return _error(405, "Method Not Allowed", "MethodNotAllowed")
    var q = target.find("?")
    var name = _sub(target, 1, target.byte_length() if q < 0 else q)
    if not name.startswith("lake/~fake/"):
        st.if_matches += (if_match if if_match.byte_length() > 0 else String("-")) + "\n"
        st.put(String("lake/~fake/if-match"), _bytes(st.if_matches))
    var at = st.find(name)
    if at < 0:
        return _error(404, "Not Found", "NoSuchKey")
    if if_match.byte_length() > 0 and st.etags[at] != if_match:
        return _error(412, "Precondition Failed", "PreconditionFailed")
    var obj = st.bodies[at].copy()
    var etag_header = String("ETag: ") + st.etags[at] + "\r\n"
    var answer: List[UInt8]
    if range_.byte_length() > 0:
        var spec = _sub(range_, 6, range_.byte_length())
        var dash = spec.find("-")
        var first: Int
        var last: Int
        if dash == 0:
            first = max(0, len(obj) - Int(_sub(spec, 1, spec.byte_length())))
            last = len(obj) - 1
        else:
            first = Int(_sub(spec, 0, dash))
            last = min(Int(_sub(spec, dash + 1, spec.byte_length())), len(obj) - 1)
        if first >= len(obj):
            return _error(416, "Requested Range Not Satisfiable", "InvalidRange")
        var part = List[UInt8]()
        part.extend(Span(obj)[first : last + 1])
        answer = _response(
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
            part,
        )
    else:
        answer = _response(200, "OK", etag_header, obj)
    if not name.startswith("lake/~fake/"):
        st.reads += 1
        if st.reads == st.overwrite_after:
            var changed = st.bodies[at].copy()
            changed[0] = changed[0] ^ UInt8(0x20)
            st.put(name, changed^)
    return answer^


struct _Stream(IoStream, Movable, Deinitable):
    var _state: ArcPointer[_State]
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self, var state: ArcPointer[_State]):
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


struct _Connector(Connector, Movable, Deinitable):
    comptime Stream = _Stream

    var _state: ArcPointer[_State]

    def __init__(out self, overwrite_after: Int):
        self._state = ArcPointer[_State](_State(overwrite_after))
        self._state[].put(String("lake/d/obj"), _bytes(_BODY))

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> _Stream:
        _ = ip_be
        _ = port
        return _Stream(self._state.copy())

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


comptime _Fs = S3Fs[_Connector, StaticCredsSource, FixedClock]


def _mk_after_1() raises -> _Connector:
    return _Connector(1)


def _mk_untouched() raises -> _Connector:
    return _Connector(-1)


def _fs(mk: def () raises thin -> _Connector) raises -> _Fs:
    return _Fs.built(
        "lake",
        S3Config(
            "us-east-1",
            endpoint="http://127.0.0.1:9000",
            addressing=AddressingStyle.path(),
            retry=RetryPolicy(
                Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
                max_attempts=3,
                deadline_ms=Int64(60_000),
            ),
        ),
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        FixedClock(1790000000),
    )


def _text(b: SharedAlignedBuffer[HeapRegion]) -> String:
    var view = b.view_range_ro(0, b.len())
    return String(unsafe_from_utf8=view.into_span())


def _two_ranges() -> List[Tuple[Int64, Int64]]:
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(8), Int64(2)))
    ranges.append((Int64(30), Int64(3)))
    return ranges^


comptime _CHANGED = (
    "S3Fs: s3://lake/d/obj changed after this handle first read it (ETag"
    ' "etag-1"); open it again to read the new version: StoreError[PRECONDITION]'
    " GetObject s3://lake/d/obj status=412 s3_code=PreconditionFailed"
    " s3_message=fake"
)


def test_read_at_after_an_overwrite_is_refused() raises:
    var fs = _fs(_mk_after_1)
    var f = fs.open("d/obj")
    assert_equal(_text(fs.read_at(f, 0, 4)), "abcd")
    with assert_raises(contains=_CHANGED):
        _ = fs.read_at(f, 4, 4)
    # A new handle reads the version the object holds now.
    var g = fs.open("d/obj")
    assert_equal(_text(fs.read_at(g, 0, 4)), "Abcd")
    assert_equal(_text(fs.read_at(g, 4, 4)), "efgh")


def test_a_prefetch_after_read_at_is_pinned_to_the_handle() raises:
    var fs = _fs(_mk_after_1)
    var f = fs.open("d/obj")
    assert_equal(_text(fs.read_at(f, 0, 4)), "abcd")
    with assert_raises(contains=_CHANGED):
        _ = fs.read_ranges_prefetched(f, _two_ranges())


def test_two_prefetches_on_one_handle_are_one_version() raises:
    var fs = _fs(_mk_after_1)
    var f = fs.open("d/obj")
    var first = List[Tuple[Int64, Int64]]()
    first.append((Int64(0), Int64(2)))
    var out = fs.read_ranges_prefetched(f, first)
    assert_equal(_text(out[0]), "ab")
    with assert_raises(contains=_CHANGED):
        _ = fs.read_ranges_prefetched(f, _two_ranges())


def test_reads_after_the_first_send_its_etag() raises:
    var fs = _fs(_mk_untouched)
    var f = fs.open("d/obj")
    assert_equal(_text(fs.read_at(f, 0, 4)), "abcd")
    assert_equal(_text(fs.read_at(f, 4, 4)), "efgh")
    var out = fs.read_ranges_prefetched(f, _two_ranges())
    assert_equal(_text(out[0]), "ij")
    assert_equal(_text(out[1]), "456")
    var log = fs.open("~fake/if-match")
    assert_equal(
        _text(fs.read_at(log, 0, 20)), '-\n"etag-1"\n"etag-1"\n'
    )


def test_read_footer_of_pins_the_handle() raises:
    # The footer is the handle's first read; the object is overwritten
    # before the column read, which is refused.
    var fs = _fs(_mk_after_1)
    var f = fs.open("d/obj")
    var footer = fs.read_footer_of(f, 10)
    assert_equal(footer.file_size, 36)
    assert_equal(f.etag(), '"etag-1"')
    with assert_raises(contains=_CHANGED):
        _ = fs.read_at(f, 0, 4)


def test_a_footer_after_an_overwrite_is_refused() raises:
    var fs = _fs(_mk_after_1)
    var f = fs.open("d/obj")
    assert_equal(_text(fs.read_at(f, 0, 4)), "abcd")
    with assert_raises(contains=_CHANGED):
        _ = fs.read_footer_of(f, 10)
    # read_footer takes a path and pins nothing: it reads the new version.
    assert_equal(fs.read_footer("d/obj", 36).bytes[0], UInt8(ord("A")))


def main() raises:
    test_read_at_after_an_overwrite_is_refused()
    test_a_prefetch_after_read_at_is_pinned_to_the_handle()
    test_two_prefetches_on_one_handle_are_one_version()
    test_reads_after_the_first_send_its_etag()
    test_read_footer_of_pins_the_handle()
    test_a_footer_after_an_overwrite_is_refused()
    print("OK")
