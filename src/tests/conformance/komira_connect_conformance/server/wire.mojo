# =============================================================================
# wire.mojo -- the connectrpc.conformance.v1 messages the server reads and writes
# =============================================================================
#
# The protobuf binary form of the fields of the suite's protocol
# (third_party/connect-conformance: server_compat.proto, service.proto and
# config.proto at the pinned commit) that this server-under-test reads or
# writes, through komira_protobuf's cursor and writers. Field numbers are the
# .proto files'; a field this file does not name is skipped, as protobuf
# requires.
#
# It is written by hand because the generated form does not compile:
# protoc-gen-mojo emits `write_bytes_element` / `read_into_repeated_bytes`
# for a `repeated bytes` field (StreamResponseDefinition.response_data), and
# komira_proto_codec's WireEncoder / WireDecoder have neither.
#
# Read: ServerCompatRequest (and its TLSCreds), the request messages of the
# ConformanceService methods (UnaryRequest, IdempotentUnaryRequest,
# ClientStreamRequest share one layout; ServerStreamRequest another), their
# UnaryResponseDefinition / StreamResponseDefinition and Error.
# Written: ServerCompatResponse, google.protobuf.Any, RequestInfo,
# ConformancePayload and the one-field response messages that carry it.
# =============================================================================

from komira_protobuf import (
    pb_write_bytes_field,
    pb_write_message_field,
    pb_write_string_field,
    pb_write_varint_field,
)
from komira_protobuf.reader import PbFieldCursor

comptime TYPE_URL_PREFIX = "type.googleapis.com/connectrpc.conformance.v1."


# -----------------------------------------------------------------------------
# ServerCompatRequest / ServerCompatResponse (server_compat.proto)
# -----------------------------------------------------------------------------


struct CompatRequest(Movable):
    """ServerCompatRequest: what the runner asks the server to start."""

    var protocol: Int  # 1, connectrpc.conformance.v1.Protocol
    var http_version: Int  # 2, HTTPVersion
    var use_tls: Bool  # 4
    var has_client_tls_cert: Bool  # 5, client certificates are required
    var message_receive_limit: Int  # 6
    var cert_pem: String  # 7.1, TLSCreds.cert
    var key_pem: String  # 7.2, TLSCreds.key

    def __init__(out self):
        self.protocol = 0
        self.http_version = 0
        self.use_tls = False
        self.has_client_tls_cert = False
        self.message_receive_limit = 0
        self.cert_pem = String("")
        self.key_pem = String("")


def decode_compat_request(bytes: List[UInt8]) raises -> CompatRequest:
    var out = CompatRequest()
    var cur = PbFieldCursor.over(Span(bytes))
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            out.protocol = Int(cur.read_varint())
        elif tag.field_number == 2:
            out.http_version = Int(cur.read_varint())
        elif tag.field_number == 4:
            out.use_tls = cur.read_bool()
        elif tag.field_number == 5:
            out.has_client_tls_cert = len(cur.read_bytes()) > 0
        elif tag.field_number == 6:
            out.message_receive_limit = Int(cur.read_varint())
        elif tag.field_number == 7:
            var creds = cur.read_message()
            while creds.has_next():
                var t = creds.next_tag()
                if t.field_number == 1:
                    out.cert_pem = creds.read_string()
                elif t.field_number == 2:
                    out.key_pem = creds.read_string()
                else:
                    creds.skip()
        else:
            cur.skip()
    return out^


def encode_compat_response(host: String, port: UInt16, pem_cert: String) -> List[UInt8]:
    """ServerCompatResponse{host = 1, port = 2, pem_cert = 3}."""
    var out = List[UInt8]()
    pb_write_string_field(out, 1, host)
    pb_write_varint_field(out, 2, UInt64(port))
    if pem_cert.byte_length() > 0:
        pb_write_bytes_field(out, 3, pem_cert.as_bytes())
    return out^


# -----------------------------------------------------------------------------
# Response definitions (service.proto)
# -----------------------------------------------------------------------------


@fieldwise_init
struct ErrorDef(Copyable, Movable):
    """connectrpc.conformance.v1.Error: the error the server must return."""

    var code: Int  # 1, Code (the gRPC code numbers)
    var message: String  # 2, optional; empty when absent


struct ResponseDef(Movable):
    """The response definition of a request message, unary or stream form,
    reduced to what this server can act on."""

    var present: Bool  # the request carried a response_definition
    var data: List[List[UInt8]]  # response_data: 0 or 1 (unary), N (stream)
    var error: Optional[ErrorDef]
    var delay_ms: Int  # response_delay_ms
    # Response headers / trailers or a raw HTTP response were asked for. The
    # komira_connect handler API cannot set either, so they are not served.
    var wants_metadata: Bool
    var wants_raw_response: Bool

    def __init__(out self):
        self.present = False
        self.data = List[List[UInt8]]()
        self.error = None
        self.delay_ms = 0
        self.wants_metadata = False
        self.wants_raw_response = False


def _read_error[o: Origin[mut=False]](mut cur: PbFieldCursor[o]) raises -> ErrorDef:
    var code = 0
    var message = String("")
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            code = Int(cur.read_varint())
        elif tag.field_number == 2:
            message = cur.read_string()
        else:
            cur.skip()  # 3, details: the request does not set any
    return ErrorDef(code=code, message=message^)


def _read_unary_def[o: Origin[mut=False]](mut cur: PbFieldCursor[o], mut d: ResponseDef) raises:
    """UnaryResponseDefinition: response_headers 1, response_data 2 (oneof),
    error 3 (oneof), response_trailers 4, raw_response 5, response_delay_ms 6."""
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1 or tag.field_number == 4:
            d.wants_metadata = True
            cur.skip()
        elif tag.field_number == 2:
            d.data.append(cur.read_bytes())
        elif tag.field_number == 3:
            var sub = cur.read_message()
            d.error = _read_error(sub)
        elif tag.field_number == 5:
            d.wants_raw_response = True
            cur.skip()
        elif tag.field_number == 6:
            d.delay_ms = Int(cur.read_varint())
        else:
            cur.skip()


def _read_stream_def[o: Origin[mut=False]](mut cur: PbFieldCursor[o], mut d: ResponseDef) raises:
    """StreamResponseDefinition: response_headers 1, response_data 2
    (repeated), response_delay_ms 3, error 4, response_trailers 5,
    raw_response 6."""
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1 or tag.field_number == 5:
            d.wants_metadata = True
            cur.skip()
        elif tag.field_number == 2:
            d.data.append(cur.read_bytes())
        elif tag.field_number == 3:
            d.delay_ms = Int(cur.read_varint())
        elif tag.field_number == 4:
            var sub = cur.read_message()
            d.error = _read_error(sub)
        elif tag.field_number == 6:
            d.wants_raw_response = True
            cur.skip()
        else:
            cur.skip()


def decode_response_def(request: List[UInt8], stream: Bool) raises -> ResponseDef:
    """The response definition (field 1) of a ConformanceService request
    message. `stream` selects the StreamResponseDefinition layout
    (ServerStreamRequest, BidiStreamRequest); otherwise the
    UnaryResponseDefinition one (UnaryRequest, IdempotentUnaryRequest,
    ClientStreamRequest)."""
    var d = ResponseDef()
    var cur = PbFieldCursor.over(Span(request))
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            d.present = True
            var sub = cur.read_message()
            if stream:
                _read_stream_def(sub, d)
            else:
                _read_unary_def(sub, d)
        else:
            cur.skip()
    return d^


# -----------------------------------------------------------------------------
# What the server writes back (service.proto, google/protobuf/any.proto)
# -----------------------------------------------------------------------------


def encode_any(message_name: String, value: List[UInt8]) -> List[UInt8]:
    """google.protobuf.Any{type_url = 1, value = 2} holding a
    connectrpc.conformance.v1 message."""
    var out = List[UInt8]()
    pb_write_string_field(out, 1, String(TYPE_URL_PREFIX) + message_name)
    pb_write_bytes_field(out, 2, Span(value))
    return out^


def encode_request_info(message_name: String, requests: List[List[UInt8]]) -> List[UInt8]:
    """ConformancePayload.RequestInfo with `requests` (3) only: every request
    message, in the order received, as an Any. request_headers (1) and
    timeout_ms (2) are not echoed: a komira_connect handler sees neither."""
    var out = List[UInt8]()
    for ref r in requests:
        pb_write_message_field(out, 3, encode_any(message_name, r))
    return out^


def encode_payload_response(
    data: List[UInt8], request_info: Optional[List[UInt8]]
) -> List[UInt8]:
    """A response message whose field 1 is a ConformancePayload{data = 1,
    request_info = 2}: UnaryResponse, ClientStreamResponse,
    ServerStreamResponse and IdempotentUnaryResponse all have this shape."""
    var payload = List[UInt8]()
    if len(data) > 0:
        pb_write_bytes_field(payload, 1, Span(data))
    if request_info:
        pb_write_message_field(payload, 2, request_info.value())
    var out = List[UInt8]()
    pb_write_message_field(out, 1, payload)
    return out^
