# =============================================================================
# komira_aws_core/echo_connector.mojo -- a test double that answers a
# request with the request
# =============================================================================
#
# `AwsEchoConnector` is a komira_http_core `Connector` for hermetic tests of
# a generated client in client mode. Its stream takes every byte the HTTP
# client writes, and answers the first read with an AWS error response, HTTP
# 400, whose code is `Echo` (`AWS_ECHO_CODE`) and whose message is the
# request head as it reached the wire: the request line and each header
# line, joined by " | " (`aws_echo_head`). The client's error builder raises
# that code and message, so a test asserts the exact request line, Host,
# signing scope and headers of each verb through the generated client
# itself, with no transport seam on the client and no socket.
#
# The answer is in the service's error form: a restXml <Error> document
# (`AwsEchoConnector.xml()`), or an awsJson body naming `__type`
# (`AwsEchoConnector.json()`). A 400 with an unknown code is never retried,
# so one call is one request. A HEAD request's answer has no body to carry
# the message.
# =============================================================================

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


comptime AWS_ECHO_CODE = "Echo"
"""The error code of every answer an `AwsEchoConnector` stream gives."""


def aws_echo_head(written: List[UInt8]) -> String:
    """The request head in `written`, the bytes before its first blank line
    (all of them when there is none), its lines joined by " | "."""
    var n = len(written)
    var end = n
    for i in range(n - 3):
        if (
            written[i] == UInt8(13)
            and written[i + 1] == UInt8(10)
            and written[i + 2] == UInt8(13)
            and written[i + 3] == UInt8(10)
        ):
            end = i
            break
    var head = String(unsafe_from_utf8=Span(written)[0:end])
    return head.replace("\r\n", " | ")


def _answer(head: String, json: Bool) -> List[UInt8]:
    var body: String
    var content_type: String
    if json:
        var text = head.replace("\\", "\\\\").replace('"', '\\"')
        body = (
            String('{"__type":"')
            + AWS_ECHO_CODE
            + '","message":"'
            + text
            + '"}'
        )
        content_type = String("application/x-amz-json-1.0")
    else:
        var text = (
            head.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        )
        body = (
            String("<Error><Code>")
            + AWS_ECHO_CODE
            + "</Code><Message>"
            + text
            + "</Message></Error>"
        )
        content_type = String("application/xml")
    var response = (
        String("HTTP/1.1 400 Bad Request\r\nContent-Type: ")
        + content_type
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    var out = List[UInt8]()
    out.extend(Span(response.as_bytes()))
    return out^


struct AwsEchoStream(IoStream, Movable, Deinitable):
    """Keeps what is written; answers the first read with it (module
    header)."""

    var _json: Bool
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self, json: Bool):
        self._json = json
        self._written = List[UInt8]()
        self._answer = ScriptedStream()
        self._answered = False

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        if not self._answered:
            self._answered = True
            self._answer = ScriptedStream.from_read_script(
                _answer(aws_echo_head(self._written), self._json)
            )
        return self._answer.try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
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
        """No kernel descriptor, as komira_http_core's ScriptedStream."""
        return Int32(-1)


struct AwsEchoConnector(Connector, Movable, Deinitable):
    """Each dial is a fresh `AwsEchoStream` (module header)."""

    comptime Stream = AwsEchoStream

    var _json: Bool

    def __init__(out self, json: Bool):
        self._json = json

    @staticmethod
    def xml() -> AwsEchoConnector:
        """Answers in the restXml error form."""
        return AwsEchoConnector(False)

    @staticmethod
    def json() -> AwsEchoConnector:
        """Answers in the awsJson error form."""
        return AwsEchoConnector(True)

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> AwsEchoStream:
        _ = ip_be
        _ = port
        return AwsEchoStream(self._json)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^
