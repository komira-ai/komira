# A stand-in inference engine for test_spawning_backend_live: it takes the
# argv a spawning backend passes (llama-server's or mlx-openai-server's) and
# serves the two probe endpoints on 127.0.0.1:<--port>.
#
#   GET  /v1/models      -> `status` (default 200) and a one-model list.
#   POST /v1/embeddings  -> 200 when the body's model is --served-model-name,
#                           404 otherwise.
#   anything else        -> 404.
#
# It logs a line to stdout and to stderr for every request, as a real engine
# does. The test steers it through the model argument (--model, or
# --model-path for the embeddings argv), a comma-separated list of:
#
#   flood=N   write N bytes to stdout and N to stderr before listening, as an
#             engine does while loading a model.
#   exit=N    exit with code N at once, without listening.
#   status=N  answer GET /v1/models with status N.
#   stall     accept connections and never answer them.
#
# Single-threaded, blocking, plain libc sockets: one request per connection.
# It runs until it is signalled.
from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys import argv, exit
from std.sys.info import CompilationTarget

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
# setsockopt(2) level/optname differ between Linux and macOS.
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_REUSEADDR_LINUX: Int32 = Int32(2)
comptime _SO_REUSEADDR_MACOS: Int32 = Int32(0x0004)
comptime _SIGPIPE: Int32 = 13
comptime _REQ_CAP: Int = 16384


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for accept(2)'s address
    arguments.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. It is never
    # dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    return addr^


def _write_all(fd: Int32, bytes: Span[UInt8, _]):
    """write(2) until every byte is out; stops on an error."""
    var done = 0
    while done < len(bytes):
        # SAFETY: the span outlives the synchronous call; write(2) reads it
        # and keeps no pointer.
        var n = external_call["write", Int](
            Int(fd), bytes.unsafe_ptr() + done, len(bytes) - done
        )
        if n <= 0:
            return
        done += Int(n)


def _log(line: String):
    var s = line + "\n"
    _write_all(Int32(1), s.as_bytes())
    _write_all(Int32(2), s.as_bytes())


def _flood(n: Int):
    """`n` bytes of log lines to stdout and to stderr."""
    var line = String("stub engine: loading model ")
    while line.byte_length() < 127:
        line += "."
    line += "\n"
    var chunk = String("")
    for _ in range(64):
        chunk += line  # 8 KiB
    for fd in [Int32(1), Int32(2)]:
        var left = n
        while left > 0:
            var take = min(left, chunk.byte_length())
            _write_all(fd, chunk.as_bytes()[0:take])
            left -= take


def _listen(port: UInt16) -> Int32:
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        return Int32(-1)
    var one = Array[Int32, 1](fill=Int32(1))
    comptime if CompilationTarget.is_macos():
        _ = external_call["setsockopt", Int32](
            fd, _SOL_SOCKET_MACOS, _SO_REUSEADDR_MACOS, one.unsafe_ptr(), UInt32(4)
        )
    else:
        _ = external_call["setsockopt", Int32](
            fd, _SOL_SOCKET_LINUX, _SO_REUSEADDR_LINUX, one.unsafe_ptr(), UInt32(4)
        )
    var addr = _sockaddr_in_loopback(port)
    # SAFETY: `addr` is a stack local; bind(2) reads 16 bytes synchronously.
    if (
        external_call["bind", Int32](
            fd, UnsafePointer(to=addr).bitcast[UInt8](), UInt32(16)
        )
        < Int32(0)
    ):
        return Int32(-1)
    if external_call["listen", Int32](fd, Int32(16)) < Int32(0):
        return Int32(-1)
    return fd


def _head_end(buf: List[UInt8]) -> Int:
    """The index just past `\\r\\n\\r\\n`, or -1."""
    for i in range(len(buf) - 3):
        if (
            buf[i] == UInt8(0x0D)
            and buf[i + 1] == UInt8(0x0A)
            and buf[i + 2] == UInt8(0x0D)
            and buf[i + 3] == UInt8(0x0A)
        ):
            return i + 4
    return -1


def _content_length(head: String) -> Int:
    var lower = head.lower()
    var key = String("\r\ncontent-length:")
    var at = lower.find(key)
    if at < 0:
        return 0
    var b = lower.as_bytes()
    var i = at + key.byte_length()
    while i < len(b) and b[i] == UInt8(ord(" ")):
        i += 1
    var n = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        n = n * 10 + Int(b[i] - UInt8(ord("0")))
        i += 1
    return n


def _read_request(conn: Int32) -> Tuple[String, String]:
    """(head, body) of one request; empty strings when the peer sent none."""
    var req = List[UInt8]()
    var chunk = List[UInt8](length=4096, fill=UInt8(0))
    while len(req) < _REQ_CAP:
        # SAFETY: `chunk` outlives the synchronous call; recv(2) writes at most
        # its length and keeps no pointer.
        var n = external_call["recv", Int64](
            conn, chunk.unsafe_ptr(), UInt64(len(chunk)), Int32(0)
        )
        if n <= Int64(0):
            break
        req.extend(Span[UInt8](chunk)[0 : Int(n)])
        var he = _head_end(req)
        if he >= 0:
            var head = String(unsafe_from_utf8=Span[UInt8](req)[0:he])
            if len(req) >= he + _content_length(head):
                return (
                    head^,
                    String(unsafe_from_utf8=Span[UInt8](req)[he : len(req)]),
                )
    return (String(""), String(""))


def _reason(status: Int) -> String:
    if status == 200:
        return "OK"
    if status == 404:
        return "Not Found"
    return "Error"


def _respond(conn: Int32, status: Int, body: String):
    var resp = String("HTTP/1.1 ") + String(status) + " " + _reason(status)
    resp += "\r\nContent-Type: application/json\r\nContent-Length: "
    resp += String(body.byte_length())
    resp += "\r\nConnection: close\r\n\r\n"
    resp += body
    _write_all(conn, resp.as_bytes())


def _directive(spec: String, key: String) -> Int:
    """The integer value of `key=N` in the comma-separated `spec`; -1 when
    absent."""
    for part in spec.split(","):
        var p = String(part)
        if p.startswith(key + "="):
            try:
                return Int(p[byte = key.byte_length() + 1 :])
            except:
                return -1
    return -1


def main():
    var args = argv()
    var port = 0
    var model = String("")
    var served = String("")
    var i = 1
    while i + 1 < len(args):
        var flag = String(args[i])
        var value = String(args[i + 1])
        if flag == "--port":
            try:
                port = Int(value)
            except:
                port = 0
        elif flag == "--model" or flag == "--model-path":
            model = value
        elif flag == "--served-model-name":
            served = value
        i += 1

    var code = _directive(model, "exit")
    if code >= 0:
        exit(code)
    var flood = _directive(model, "flood")
    if flood > 0:
        _flood(flood)
    var models_status = _directive(model, "status")
    if models_status < 0:
        models_status = 200
    var stall = False
    for part in model.split(","):
        if String(part) == "stall":
            stall = True

    # A client that hangs up early must not kill the engine with SIGPIPE.
    # SIG_IGN is the handler value 1.
    _ = external_call["signal", Int](_SIGPIPE, Int(1))
    var fd = _listen(UInt16(port))
    if fd < Int32(0):
        _log("stub engine: cannot listen on port " + String(port))
        exit(2)
    _log("stub engine: listening on 127.0.0.1:" + String(port))

    var held = List[Int32]()
    while True:
        var conn = external_call["accept", Int32](
            fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        if conn < Int32(0):
            continue
        if stall:
            held.append(conn)  # never answered, never closed
            continue
        var req = _read_request(conn)
        var head = req[0]
        var body = req[1]
        if head.startswith("GET /v1/models "):
            _respond(
                conn,
                models_status,
                String('{"object":"list","data":[{"id":"') + model + '"}]}',
            )
        elif head.startswith("POST /v1/embeddings "):
            if served.byte_length() > 0 and body.find(
                String('"model":"') + served + '"'
            ) >= 0:
                _respond(
                    conn,
                    200,
                    String('{"object":"list","data":[{"embedding":[0.0]}]}'),
                )
            else:
                _respond(conn, 404, String('{"error":"model_not_found"}'))
        else:
            _respond(conn, 404, String("{}"))
        _log("stub engine: " + head.split("\r\n")[0])
        _ = external_call["close", Int32](conn)
