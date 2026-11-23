# A fake Azure Blob service that keeps blobs in memory, for tests of the
# Azure read path: `FakeAzureConnector`, a http_core Connector whose streams
# parse each HTTP/1.1 request written to them and answer it as the Blob
# service answers a reader, path-style as the Azurite emulator is addressed
# (`/<account>/<container>/<blob>`, the blob name percent-encoded): Get Blob
# Properties (HEAD: the size in Content-Length) and Get Blob (GET, the whole
# blob, or a `bytes=a-b` or `bytes=a-` range as 206 Partial Content). A blob
# that is not there is 404 BlobNotFound, a range that starts past the end 416
# InvalidRange, and any other method 405 UnsupportedHttpVerb. Signatures and
# the account are not checked.
#
# One fault, off by default: a request whose decoded path holds `trap` is
# answered 403 AuthorizationPermissionMismatch.
#
# Its state lives behind an Arc the connector shares with every stream it
# dials, so it outlives each connection. No socket. `fake_azure_answer` is
# the answer to one request's bytes, for a test of the fake itself.
#
# Test-only: azure_blob's and sdk_exec's welded tests name it in `test_deps`.
from std.memory import ArcPointer

from async_rt.reactor.reactor import Reactor
from async_rt.runtime.runtime_trait import Runtime
from http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from http_core.transport.scripted import ScriptedStream


struct FakeAzureState(Movable):
    """The blobs, by `<container>/<blob>`, and the fault."""

    var names: List[String]
    var bodies: List[List[UInt8]]
    var trap: String
    var requests: Int
    """Requests answered so far, the refused ones included."""

    def __init__(out self, trap: String = ""):
        """No blob; `trap` (empty: none) as `fake_azure.mojo` says."""
        self.names = List[String]()
        self.bodies = List[List[UInt8]]()
        self.trap = trap
        self.requests = 0

    def find(self, name: String) -> Int:
        """The index of blob `name` (`<container>/<blob>`), or -1."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def put(mut self, name: String, var body: List[UInt8]):
        """Stores `body` as blob `name` (`<container>/<blob>`), replacing one
        there."""
        var at = self.find(name)
        if at >= 0:
            self.bodies[at] = body^
            return
        self.names.append(name)
        self.bodies.append(body^)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


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


def fake_azure_unquote(s: String) raises -> String:
    """`s` with each `%XX` decoded to its byte, as the service reads a path.
    Refuses a `%` not followed by two hex digits."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(0x25):
            if i + 2 >= len(b):
                raise Error("the fake Azure read a path that ends inside an escape: " + s)
            var hi = _hex(b[i + 1])
            var lo = _hex(b[i + 2])
            if hi < 0 or lo < 0:
                raise Error("the fake Azure read a path with a bad escape: " + s)
            out.append(UInt8(hi * 16 + lo))
            i += 3
        else:
            out.append(c)
            i += 1
    return String(unsafe_from_utf8=Span(out))


def _response(status: Int, reason: String, headers: String, body: List[UInt8], head: Bool) -> List[UInt8]:
    """A response whose Content-Length is `body`'s; a HEAD's carries no
    body."""
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
    """The service's error: an XML body naming `code`, none for a HEAD."""
    if head:
        return _response(status, reason, String("x-ms-error-code: ") + code + "\r\n", List[UInt8](), True)
    return _response(
        status,
        reason,
        String("Content-Type: application/xml\r\nx-ms-error-code: ") + code + "\r\n",
        _bytes(
            String("<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>")
            + code
            + "</Code><Message>fake</Message></Error>"
        ),
        False,
    )


def _blob_name(target: String) raises -> String:
    """`<container>/<blob>` of a path-style target
    `/<account>/<container>/<blob>[?query]`, decoded; empty when the target
    names no blob."""
    var path = target
    var q = path.find("?")
    if q >= 0:
        path = _sub(path, 0, q)
    var decoded = fake_azure_unquote(path)
    if not decoded.startswith("/"):
        return String("")
    var after_account = decoded.find("/", 1)
    if after_account < 0:
        return String("")
    var name = _sub(decoded, after_account + 1, decoded.byte_length())
    var slash = name.find("/")
    if slash <= 0 or slash == name.byte_length() - 1:
        return String("")
    return name^


def _read(st: FakeAzureState, at: Int, range_: String, is_head: Bool) raises -> List[UInt8]:
    """The answer to a GET or HEAD of the blob at `at`."""
    ref blob = st.bodies[at]
    var etag = String("ETag: \"0x8D0000000000") + String(at) + "\"\r\n"
    if range_.byte_length() == 0 or is_head:
        var whole = blob.copy()
        return _response(200, "OK", etag + "x-ms-blob-type: BlockBlob\r\n", whole^, is_head)
    if not range_.startswith("bytes="):
        return _error(416, "Range Not Satisfiable", "InvalidRange", False)
    var spec = _sub(range_, 6, range_.byte_length())
    var dash = spec.find("-")
    if dash <= 0:
        # Azure has no suffix range (`bytes=-n`).
        return _error(416, "Range Not Satisfiable", "InvalidRange", False)
    var first = Int(_sub(spec, 0, dash))
    var last = len(blob) - 1
    if dash + 1 < spec.byte_length():
        last = min(last, Int(_sub(spec, dash + 1, spec.byte_length())))
    if first >= len(blob) or last < first:
        return _error(416, "Range Not Satisfiable", "InvalidRange", False)
    var part = List[UInt8]()
    part.extend(Span(blob)[first : last + 1])
    return _response(
        206,
        "Partial Content",
        etag
        + "Content-Range: bytes "
        + String(first)
        + "-"
        + String(last)
        + "/"
        + String(len(blob))
        + "\r\n",
        part^,
        False,
    )


def fake_azure_answer(mut st: FakeAzureState, written: List[UInt8]) raises -> List[UInt8]:
    """The answer to the one request in `written` (`fake_azure.mojo` says
    what is served). Raises when `written` holds no complete request head."""
    st.requests += 1
    var n = len(written)
    var end = -1
    for i in range(n - 3):
        if written[i] == 13 and written[i + 1] == 10 and written[i + 2] == 13 and written[i + 3] == 10:
            end = i
            break
    if end < 0:
        raise Error("the fake Azure read no complete request head")
    var head = String(unsafe_from_utf8=Span(written)[0:end])
    var lines = head.split("\r\n")
    var request_line = String(lines[0]).split(" ")
    var method = String(request_line[0])
    var target = String(request_line[1])
    var is_head = method == "HEAD"
    if method != "GET" and not is_head:
        return _error(405, "Method Not Allowed", "UnsupportedHttpVerb", False)
    var name = _blob_name(target)
    if st.trap.byte_length() > 0 and name.find(st.trap) >= 0:
        return _error(403, "Forbidden", "AuthorizationPermissionMismatch", is_head)
    var range_ = String("")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon < 0:
            continue
        var header = _sub(line, 0, colon).lower()
        if header == "range" or header == "x-ms-range":
            range_ = String(_sub(line, colon + 1, line.byte_length()).strip())
    var at = st.find(name) if name.byte_length() > 0 else -1
    if at < 0:
        return _error(404, "The specified blob does not exist.", "BlobNotFound", is_head)
    return _read(st, at, range_, is_head)


struct FakeAzureStream(IoStream, Movable, Deinitable):
    """Keeps what is written; answers the first read from the shared
    state."""

    var _state: ArcPointer[FakeAzureState]
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self, var state: ArcPointer[FakeAzureState]):
        self._state = state^
        self._written = List[UInt8]()
        self._answer = ScriptedStream()
        self._answered = False

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](mut self, mut reactor: Reactor[RT.Sink], dst: Span[UInt8, o]) raises -> StreamIo:
        if not self._answered:
            self._answered = True
            self._answer = ScriptedStream.from_read_script(fake_azure_answer(self._state[], self._written))
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


struct FakeAzureConnector(Connector, Movable, Deinitable):
    """Each dial is a stream over the one shared state."""

    comptime Stream = FakeAzureStream

    var _state: ArcPointer[FakeAzureState]

    def __init__(out self, trap: String = ""):
        """A fake Blob service holding no blob; `trap` as `fake_azure.mojo`
        says."""
        self._state = ArcPointer[FakeAzureState](FakeAzureState(trap))

    def seed(mut self, container: String, blob: String, var body: List[UInt8]):
        """Stores `body` as `blob` of `container` before any request."""
        self._state[].put(container + "/" + blob, body^)

    def requests(self) -> Int:
        """The requests the streams this connector dialed have answered."""
        return self._state[].requests

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> FakeAzureStream:
        _ = ip_be
        _ = port
        return FakeAzureStream(self._state.copy())

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^
