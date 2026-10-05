# =============================================================================
# komira_gcp_firestore/firestore_scripted.mojo — a scripted Firestore, for
#   tests of code that talks to Firestore through `FirestoreClient`.
# =============================================================================
#
# `ScriptedFirestore` answers the client's HTTP requests with responses the
# test queues, in order, and records each request so the test can read back
# what was sent. It is komira_http_core's `ScriptedConnector` underneath: one
# scripted stream per request (the client dials once per request over
# https), each with a write capture the script keeps. No socket, no network,
# no credential: the client under test is an ordinary
# `FirestoreClient[ScriptedConnector, S]`, so every byte it puts on the wire
# is the generated client's own.
#
#     var script = ScriptedFirestore()
#     script.queue_response(200, '{"writeResults":[{"updateTime":"..."}]}')
#     var client = FirestoreClient[ScriptedConnector](
#         script.take_connector(), "demo-project", "(default)", "token"
#     )
#     _ = client.create_if_absent("items", "a", fields)
#     assert_equal(script.call_path(0), "/v1/projects/demo-project/databases/%28default%29/documents:commit")
#
# The answers are written as the service writes them: a document read is a
# BatchGetDocuments stream (`[{"found":{...}}]` or `[{"missing":"..."}]`), a
# write a Commit response (`{"writeResults":[...]}`), a query a RunQuery
# stream (`[{"document":{...}}, ...]`), a failure the `google.rpc.Status`
# envelope with its HTTP status.
# =============================================================================

from std.memory import ArcPointer

from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


def _reason(status: Int) -> String:
    if status == 200:
        return String("OK")
    if status == 400:
        return String("Bad Request")
    if status == 401:
        return String("Unauthorized")
    if status == 403:
        return String("Forbidden")
    if status == 404:
        return String("Not Found")
    if status == 409:
        return String("Conflict")
    if status == 429:
        return String("Too Many Requests")
    if status == 500:
        return String("Internal Server Error")
    if status == 503:
        return String("Service Unavailable")
    return String("Status")


def scripted_http_response(status: Int, body: String) -> List[UInt8]:
    """An HTTP/1.1 response with a JSON `body`, closing the connection."""
    var text = (
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + _reason(status)
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^


struct _Request(Copyable, Movable):
    var method: String
    var path: String
    var host: String
    var authorization: String
    var body: String

    def __init__(out self, text: String):
        """Split one HTTP/1.1 request as komira_http_client writes it."""
        self.method = String("")
        self.path = String("")
        self.host = String("")
        self.authorization = String("")
        self.body = String("")
        var end = text.find("\r\n\r\n")
        var head = text
        if end >= 0:
            head = String(unsafe_from_utf8=text.as_bytes()[:end])
            self.body = String(unsafe_from_utf8=text.as_bytes()[end + 4 :])
        var lines = head.split("\r\n")
        if len(lines) == 0:
            return
        var first = String(lines[0]).split(" ")
        if len(first) >= 2:
            self.method = String(first[0])
            self.path = String(first[1])
        for i in range(1, len(lines)):
            var line = String(lines[i])
            var lower = line.lower()
            if lower.startswith("host: "):
                self.host = String(unsafe_from_utf8=line.as_bytes()[6:])
            elif lower.startswith("authorization: "):
                self.authorization = String(unsafe_from_utf8=line.as_bytes()[15:])


struct ScriptedFirestore(Movable):
    """Queued HTTP answers for a `FirestoreClient[ScriptedConnector, S]`, and
    the requests it sent (see the module header)."""

    var _connector: ScriptedConnector
    var _taken: Bool
    var _captures: List[ArcPointer[List[UInt8]]]

    def __init__(out self):
        self._connector = ScriptedConnector()
        # Generated clients send https; the script claims TLS without any
        # (the ScriptedConnector fixture toggle), so the scheme check passes.
        self._connector._claim_tls = True
        self._taken = False
        self._captures = List[ArcPointer[List[UInt8]]]()

    @staticmethod
    def plaintext() -> ScriptedFirestore:
        """A script whose connector does NOT claim TLS: for a client pointed at
        a plaintext endpoint (the emulator, `FirestoreClient.set_endpoint` with
        `insecure`), whose `http` URLs the HttpClient refuses over a TLS one."""
        var s = ScriptedFirestore()
        s._connector._claim_tls = False
        return s^

    def queue_response(mut self, status: Int, var body: String) raises:
        """Answer the next request with `status` and `body`."""
        if self._taken:
            raise Error("ScriptedFirestore: queue every response before take_connector()")
        var capture = ArcPointer[List[UInt8]](List[UInt8]())
        var stream = ScriptedStream.from_read_script_with_capture(
            scripted_http_response(status, body), capture
        )
        if len(self._captures) == 0:
            self._connector.arm(stream^)
        else:
            self._connector.arm_next(stream^)
        self._captures.append(capture)

    def take_connector(mut self) raises -> ScriptedConnector:
        """The connector to build the client over (once)."""
        if self._taken:
            raise Error("ScriptedFirestore: the connector was already taken")
        self._taken = True
        var c = ScriptedConnector()
        swap(c, self._connector)
        return c^

    def call_count(self) -> Int:
        """How many requests the client wrote."""
        var n = 0
        for i in range(len(self._captures)):
            if len(self._captures[i][]) > 0:
                n += 1
        return n

    def _request(self, i: Int) raises -> _Request:
        if i < 0 or i >= len(self._captures):
            raise Error("ScriptedFirestore: no request " + String(i))
        return _Request(String(unsafe_from_utf8=Span(self._captures[i][])))

    def call_text(self, i: Int) raises -> String:
        """The bytes of request `i` as written."""
        if i < 0 or i >= len(self._captures):
            raise Error("ScriptedFirestore: no request " + String(i))
        return String(unsafe_from_utf8=Span(self._captures[i][]))

    def call_method(self, i: Int) raises -> String:
        """The method of request `i` (`POST`)."""
        return self._request(i).method

    def call_path(self, i: Int) raises -> String:
        """The request target of request `i` (path and query)."""
        return self._request(i).path

    def call_host(self, i: Int) raises -> String:
        """The Host header of request `i`."""
        return self._request(i).host

    def call_bearer(self, i: Int) raises -> String:
        """The token of request `i`'s `authorization: Bearer <token>`."""
        var a = self._request(i).authorization
        if a.startswith("Bearer "):
            return String(unsafe_from_utf8=a.as_bytes()[7:])
        return a^

    def call_body(self, i: Int) raises -> String:
        """The JSON body of request `i`."""
        return self._request(i).body
