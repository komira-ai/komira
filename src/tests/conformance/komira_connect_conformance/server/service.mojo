# =============================================================================
# service.mojo -- connectrpc.conformance.v1.ConformanceService on ConnectService
# =============================================================================
#
# The methods the suite calls, registered on a komira_connect ConnectService
# through its public registration API, and answered as the suite's
# testing_servers.md says, as far as that API lets a handler:
#
#   Unary, IdempotentUnary  register_method: decode the response definition;
#                           raise its error, or return a ConformancePayload
#                           with its response_data and the request as an Any.
#   ClientStream            register_client_stream: the definition is the
#                           first request's; every request is echoed.
#   ServerStream            register_server_stream: one payload per
#                           response_data, the request echoed in the first;
#                           then the definition's error, if any, is raised.
#   Unimplemented           not registered, as the suite requires: the
#                           framework is to answer UNIMPLEMENTED itself.
#   BidiStream              not registered: ConnectService has no
#                           bidirectional streaming (the config excludes it).
#
# What a handler cannot do, and so this server does not do (each a
# known-failing reason in known_failing.txt): read request headers or the
# request timeout, set response headers or trailers, attach error details,
# send a raw HTTP response, send a stream's messages before its error. The
# response delay is slept inside the handler, which blocks the server's one
# serve loop for that long.
#
# A handler raises `format_connect_error(code, message)`; the dispatcher maps
# the code to the wire status of the request's protocol.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_clock import now_ns
from komira_connect import ConnectService, format_connect_error

from wire import (
    ResponseDef,
    decode_response_def,
    encode_payload_response,
    encode_request_info,
)

comptime SERVICE_PATH = "/connectrpc.conformance.v1.ConformanceService/"


def _sleep_ms(ms: Int) raises:
    """Wait `ms` milliseconds on an empty reactor (an epoll_wait with a
    timeout): std's sleep would declare a second `nanosleep` beside
    komira_async's, which does not legalize in one program."""
    if ms <= 0:
        return
    var until = now_ns() + UInt64(ms) * 1_000_000
    var idle = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    while True:
        var now = now_ns()
        if now >= until:
            return
        var left_us = Int((until - now) // 1_000)
        _ = idle.poll_completions(0, Int32(min(left_us, 100_000)))


def _raise_defined(d: ResponseDef) raises:
    ref e = d.error.value()
    raise Error(format_connect_error(UInt8(e.code), e.message))


def _unary_like(message_name: String, request: List[UInt8]) raises -> List[UInt8]:
    """Unary and IdempotentUnary: one request, one response or the error."""
    var d = decode_response_def(request, stream=False)
    var requests = List[List[UInt8]]()
    requests.append(request.copy())
    var info = encode_request_info(message_name, requests)
    _sleep_ms(d.delay_ms)
    if d.error:
        _raise_defined(d)
    var data = List[UInt8]()
    if len(d.data) > 0:
        data = d.data[0].copy()
    return encode_payload_response(data, Optional(info^))


def unary(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return _unary_like(String("UnaryRequest"), req_body)


def idempotent_unary(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return _unary_like(String("IdempotentUnaryRequest"), req_body)


def client_stream(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    """The first request's definition decides; every request is echoed."""
    var d = ResponseDef()
    if len(req_messages) > 0:
        d = decode_response_def(req_messages[0], stream=False)
    var info = encode_request_info(String("ClientStreamRequest"), req_messages)
    _sleep_ms(d.delay_ms)
    if d.error:
        _raise_defined(d)
    var data = List[UInt8]()
    if len(d.data) > 0:
        data = d.data[0].copy()
    var out = List[List[UInt8]]()
    out.append(encode_payload_response(data, Optional(info^)))
    return out^


def server_stream(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    """One payload per response_data, the request echoed in the first, the
    delay before each; then the definition's error. ConnectService drops the
    messages of a handler that raises, so the error goes out alone."""
    var out = List[List[UInt8]]()
    if len(req_messages) == 0:
        return out^
    var d = decode_response_def(req_messages[0], stream=True)
    var info = encode_request_info(String("ServerStreamRequest"), req_messages)
    for i in range(len(d.data)):
        _sleep_ms(d.delay_ms)
        if i == 0:
            out.append(encode_payload_response(d.data[i], Optional(info.copy())))
        else:
            out.append(encode_payload_response(d.data[i], None))
    if d.error:
        _raise_defined(d)
    return out^


def conformance_service() -> ConnectService:
    var svc = ConnectService(String("connectrpc.conformance.v1.ConformanceService"))
    svc.register_method(String(SERVICE_PATH) + "Unary", unary)
    svc.register_method(String(SERVICE_PATH) + "IdempotentUnary", idempotent_unary)
    svc.register_client_stream(String(SERVICE_PATH) + "ClientStream", client_stream)
    svc.register_server_stream(String(SERVICE_PATH) + "ServerStream", server_stream)
    return svc^
