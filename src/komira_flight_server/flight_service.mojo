# =============================================================================
# flight_service.mojo: the FlightBrokerService adapter.
# =============================================================================
#
# The Arrow Flight service adapter. It conforms to the `GrpcDispatch` +
# `GrpcStreamDispatch` seams of `komira_http_core.transport.grpc_emit` (as
# `komira_connect.ConnectService` does) so it installs directly into the h2
# serve loop as `HttpServer[FlightBrokerService]`. It owns the
# `FlightBrokerData` Arrow-native broker data plane by value and routes three
# Flight RPCs:
#
#   GetFlightInfo  (UNARY, dispatch_grpc):
#       FlightDescriptor(path=[topic]) -> FlightInfo {
#           schema = the topic's Arrow schema as an IPC schema message,
#           endpoint = one FlightEndpoint per partition { ticket = {topic,
#                      start_offset=0, partition=p}, location = [this server] },
#           total_records = the sum of the partitions' high watermarks (a
#                           manifest read), total_bytes = -1 }
#
#   DoGet  (SERVER-STREAM, dispatch_grpc_stream, GRPC_KIND_SERVER_STREAM):
#       Ticket{topic, offset, partition} -> STREAM of FlightData.
#       Flight schema-first convention: FlightData[0] = schema (IPC schema
#       message in data_header, empty body), then one FlightData per RecordBatch
#       (IPC message header in data_header, IPC body bytes in data_body).
#
#   DoPut  (CLIENT-STREAM, dispatch_grpc_stream, GRPC_KIND_CLIENT_STREAM):
#       STREAM of FlightData (first = schema, then batches) -> one PutResult.
#       Each batch FlightData is decoded back to a RecordBatch (the first
#       message's data_header is the schema) and produced to
#       flight_descriptor.path[0] of the first message, on the partition named
#       by path[1] (default 0).
#
# Not served: the other FlightService RPCs (Handshake, ListFlights,
# PollFlightInfo, GetSchema, DoExchange, DoAction, ListActions). A call to one
# is answered with gRPC status NOT_FOUND ("unknown ... method").
#
# WIRE: each streaming handler's request and response messages are the inner
# protobuf bytes. The gRPC envelope split and framing is done by the h2 serve
# loop and the `GrpcStreamResponse` emit. DoGet returns a List of serialized
# FlightData messages (one per stream message); DoPut receives a List of
# serialized FlightData messages and returns a 1-element List with the
# serialized PutResult.
#
# No pointer appears in any signature. The data plane is owned by value; the
# service is the `G` HttpServer owns by value for its whole lifetime (the
# per-connection loop borrows `mut` each round), so the registry outlives every
# dispatch.
# =============================================================================

from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
)

from komira_connect.codec_grpc import (
    GRPC_CONTENT_TYPE_PROTO,
    grpc_decode_stream,
    grpc_encode_unary,
    grpc_percent_encode_message,
)
from komira_connect.status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_INVALID_ARGUMENT,
)

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow_ipc.ipc_encoder_dispatch import encode_schema_message

from komira_flight import (
    BrokerTicket,
    FlightData,
    FlightDescriptor,
    FlightEndpoint,
    FlightInfo,
    Location,
    PutResult,
    Ticket,
    encode_batch_flight_data,
    encode_schema_flight_data,
    flight_data_to_record_batch,
)

from .flight_broker_data import FlightBrokerData


comptime FLIGHT_GET_INFO_PATH: String = "/arrow.flight.protocol.FlightService/GetFlightInfo"
comptime FLIGHT_DO_GET_PATH: String = "/arrow.flight.protocol.FlightService/DoGet"
comptime FLIGHT_DO_PUT_PATH: String = "/arrow.flight.protocol.FlightService/DoPut"

# The partition-as-COUNT ceiling.
#
# `_do_put` auto-registers an unknown topic with `put_partition + 1`
# partitions, and `FlightBrokerData.add_topic` then builds one BrokerCore and
# one ConsumeCore per partition, each cloning the store and constructing a
# CasManifestStore. A DoPut to a not-yet-existing topic name with descriptor
# path[1] = "1000000000" would otherwise ask for a billion core pairs, so the
# count is capped.
#
# Partition-as-INDEX is gated separately (`FlightBrokerData._check_partition`
# raises on `partition < 0 or partition >= np`, covering produce /
# read_batches / high_watermark).
#
# 1024 is well past any real topic's partition count while bounding the work
# `add_topic` can be made to do at about 1024 core pairs.
comptime MAX_TOPIC_PARTITIONS: Int = 1024


# =============================================================================
# FlightBrokerService — the GrpcDispatch + GrpcStreamDispatch conformer.
# =============================================================================


struct FlightBrokerService(
    GrpcDispatch, GrpcStreamDispatch, Movable, Deinitable
):
    """The Arrow Flight service over the broker. Install via
    `HttpServer[FlightBrokerService]`."""

    var _data: FlightBrokerData
    var _location_uri: String
    """The server's own URI, echoed in FlightInfo endpoints (e.g.
    `grpc+tls://broker.example:<port>`). The caller supplies it at construction."""

    def __init__(out self, var data: FlightBrokerData, var location_uri: String):
        self._data = data^
        self._location_uri = location_uri^

    def add_topic(mut self, var name: String, num_partitions: Int = 1) raises:
        self._data.add_topic(name^, num_partitions)

    # -------------------------------------------------------------------------
    # GetFlightInfo — UNARY (GrpcDispatch).
    # -------------------------------------------------------------------------

    def dispatch_grpc(
        mut self,
        path: String,
        content_type: String,
        request_body: List[UInt8],
    ) -> GrpcResponse:
        if path != FLIGHT_GET_INFO_PATH:
            return _unary_error(
                GRPC_STATUS_NOT_FOUND, String("unknown unary method ") + path
            )
        try:
            return self._get_flight_info(request_body)
        except e:
            return _unary_error(GRPC_STATUS_INTERNAL, String(e))

    def _get_flight_info(mut self, request_body: List[UInt8]) raises -> GrpcResponse:
        # The unary request body is a single gRPC envelope; split it.
        var envelopes = grpc_decode_stream(Span(request_body))
        if len(envelopes) != 1:
            return _unary_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("GetFlightInfo expects exactly 1 request message"),
            )
        var view = envelopes[0].payload
        var desc = FlightDescriptor.decode(view)
        if len(desc.path) == 0:
            return _unary_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("FlightDescriptor.path is empty (need [topic])"),
            )
        var topic = desc.path[0]
        if not self._data.has_topic(topic):
            return _unary_error(
                GRPC_STATUS_NOT_FOUND, String("unknown topic '") + topic + "'"
            )

        # schema (IPC schema message bytes) — only if a DoPut established it.
        var schema_bytes = List[UInt8]()
        if self._data.has_schema(topic):
            # We want the raw IPC schema message bytes for FlightInfo.schema,
            # NOT a FlightData wrapper — encode the schema message directly.
            var sch = self._data.schema_copy(topic)
            schema_bytes = _ipc_schema_message_bytes(sch^)

        # Fan out ONE FlightEndpoint per partition (loop over the topic's
        # partition count). Each endpoint's ticket carries
        # BrokerTicket{topic, start_offset=0, partition=p}, so a client DoGets
        # each partition's stream via the matching endpoint. total_records is the
        # SUM of the per-partition high watermarks (the topic-wide record count).
        var np = self._data.num_partitions(topic)
        var total_records = Int64(0)
        var endpoints = List[FlightEndpoint]()
        for p in range(np):
            total_records += self._data.high_watermark(topic, p)
            # ticket {topic, start_offset=0, partition=p}
            var bt = BrokerTicket(topic.copy(), Int64(0), Int64(p))
            var ticket = Ticket(bt.encode())
            var locs = List[Location]()
            locs.append(Location(self._location_uri.copy()))
            endpoints.append(FlightEndpoint(ticket^, locs^))

        var info = FlightInfo(
            schema_bytes^,
            FlightDescriptor.for_path(topic.copy()),
            endpoints^,
            total_records,
            Int64(-1),  # total_bytes unknown
            False,
        )
        var framed = grpc_encode_unary(Span(info.encode()))
        return GrpcResponse(
            framed^,
            UInt16(200),
            GRPC_STATUS_OK,
            String(""),
            String(GRPC_CONTENT_TYPE_PROTO),
            True,
        )

    # -------------------------------------------------------------------------
    # Streaming kind resolution + dispatch (GrpcStreamDispatch).
    # -------------------------------------------------------------------------

    def grpc_stream_kind(self, path: String) -> UInt8:
        if path == FLIGHT_DO_GET_PATH:
            return GRPC_KIND_SERVER_STREAM
        if path == FLIGHT_DO_PUT_PATH:
            return GRPC_KIND_CLIENT_STREAM
        return GRPC_KIND_UNARY

    def dispatch_grpc_stream(
        mut self,
        path: String,
        content_type: String,
        kind: UInt8,
        request_body: List[UInt8],
    ) -> GrpcStreamResponse:
        # `_grpc_ct()` mints a fresh content-type String per use (String is
        # cheap; avoids threading a single ^-moved value across try/except arms,
        # which the compiler flags as a use-after-move).
        # Split the inbound envelopes into owned FlightData message payloads.
        var req_messages = List[List[UInt8]]()
        try:
            var envelopes = grpc_decode_stream(Span(request_body))
            for ei in range(len(envelopes)):
                var payload = List[UInt8]()
                var view = envelopes[ei].payload
                for bi in range(len(view)):
                    payload.append(view[bi])
                req_messages.append(payload^)
        except e:
            return _stream_error(GRPC_STATUS_INVALID_ARGUMENT, String(e), _grpc_ct())

        if path == FLIGHT_DO_GET_PATH:
            try:
                return self._do_get(req_messages^, _grpc_ct())
            except e:
                return _stream_error(GRPC_STATUS_INTERNAL, String(e), _grpc_ct())
        elif path == FLIGHT_DO_PUT_PATH:
            try:
                return self._do_put(req_messages^, _grpc_ct())
            except e:
                return _stream_error(GRPC_STATUS_INTERNAL, String(e), _grpc_ct())
        else:
            return _stream_error(
                GRPC_STATUS_NOT_FOUND,
                String("unknown streaming method ") + path,
                _grpc_ct(),
            )

    # -------------------------------------------------------------------------
    # DoGet — SERVER-STREAM: Ticket -> [schema FlightData, batch FlightData...].
    # -------------------------------------------------------------------------

    def _do_get(
        mut self, var req_messages: List[List[UInt8]], var resp_ct: String
    ) raises -> GrpcStreamResponse:
        if len(req_messages) != 1:
            return _stream_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("DoGet expects exactly 1 request (Ticket)"),
                resp_ct^,
            )
        var ticket = Ticket.decode(Span(req_messages[0]))
        var bt = BrokerTicket.decode(Span(ticket.ticket))
        var topic = bt.topic
        if not self._data.has_topic(topic):
            return _stream_error(
                GRPC_STATUS_NOT_FOUND, String("unknown topic '") + topic + "'",
                resp_ct^,
            )

        # The client-supplied partition (ticket field 3; absent -> 0).
        # `FlightBrokerData._check_partition` would raise on a bad value, but
        # that raise is caught by the dispatch arm as GRPC_STATUS_INTERNAL,
        # reporting a client-caused error as a server fault. So the range is
        # checked here and answered INVALID_ARGUMENT naming the ticket field
        # and the legal range, as `_do_put` does for its partition.
        # `bt.partition` is an Int64 built from a full 64-bit protobuf varint,
        # so it is the whole signed range, not a small index.
        var get_partition = Int(bt.partition)
        if get_partition < 0 or get_partition > MAX_TOPIC_PARTITIONS:
            return _stream_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("DoGet ticket partition ")
                + String(get_partition)
                + " is out of range (expected [0, "
                + String(MAX_TOPIC_PARTITIONS)
                + "])",
                resp_ct^,
            )
        var batches = self._data.read_batches(
            topic, get_partition, bt.start_offset
        )

        var out = List[List[UInt8]]()
        # FlightData[0] = schema (from the first batch, or the registered schema).
        if len(batches) > 0:
            var schema0 = batches[0].schema.copy()
            out.append(grpc_encode_unary(Span(encode_schema_flight_data(schema0^))))
        elif self._data.has_schema(topic):
            var sch = self._data.schema_copy(topic)
            out.append(grpc_encode_unary(Span(encode_schema_flight_data(sch^))))
        # else: no schema yet and no batches -> empty stream (just the OK trailer).

        # One FlightData per RecordBatch.
        for i in range(len(batches)):
            var rb = batches.take_slot_unchecked(i)
            var fd_bytes = encode_batch_flight_data(rb^)
            out.append(grpc_encode_unary(Span(fd_bytes)))
        batches.set_len_unchecked(0)
        _ = batches^

        return GrpcStreamResponse(
            out^, UInt16(200), GRPC_STATUS_OK, String(""), resp_ct^
        )

    # -------------------------------------------------------------------------
    # DoPut — CLIENT-STREAM: [schema FlightData, batch FlightData...] -> PutResult.
    # -------------------------------------------------------------------------

    def _do_put(
        mut self, var req_messages: List[List[UInt8]], var resp_ct: String
    ) raises -> GrpcStreamResponse:
        if len(req_messages) == 0:
            return _stream_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("DoPut received no FlightData messages"),
                resp_ct^,
            )

        # The first FlightData carries the schema (data_header = IPC schema
        # message, no body) + the FlightDescriptor (destination topic). Each
        # subsequent FlightData carries one RecordBatch.
        var first = FlightData.decode(Span(req_messages[0]))
        if not first.has_descriptor or len(first.flight_descriptor.path) == 0:
            return _stream_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("DoPut first FlightData lacks a FlightDescriptor path"),
                resp_ct^,
            )
        var topic = first.flight_descriptor.path[0]
        # The client-supplied target partition rides the descriptor path as
        # path[1] (a decimal string). Absent (single-segment path) -> 0. The
        # partition is caller-supplied on the wire; there is no hash router.
        var put_partition = Int(0)
        if len(first.flight_descriptor.path) >= 2:
            put_partition = _parse_partition(first.flight_descriptor.path[1])
            # `_parse_partition` returns -1 for malformed, negative, empty AND
            # out-of-range (> MAX_TOPIC_PARTITIONS), the last of which keeps
            # the auto-registration below from being a resource-exhaustion
            # lever. The error names the ceiling.
            if put_partition < 0:
                return _stream_error(
                    GRPC_STATUS_INVALID_ARGUMENT,
                    String("DoPut descriptor path[1] is not a valid partition: '")
                    + first.flight_descriptor.path[1]
                    + "' (expected a decimal integer in [0, "
                    + String(MAX_TOPIC_PARTITIONS) + "])",
                    resp_ct^,
                )
        if not self._data.has_topic(topic):
            # Auto-register the topic on first DoPut (Flight clients do_put to a
            # path without a prior CreateTopic; the broker materializes it). The
            # auto-registered topic must have ENOUGH partitions for the supplied
            # index (>= put_partition + 1); a single-partition put gives 1.
            self._data.add_topic(topic.copy(), put_partition + 1)

        # The schema message bytes for reassembly (data_header of FlightData[0]).
        var schema_header = first.data_header.copy()
        if len(schema_header) == 0:
            return _stream_error(
                GRPC_STATUS_INVALID_ARGUMENT,
                String("DoPut first FlightData has no schema (empty data_header)"),
                resp_ct^,
            )

        # Establish the topic schema from the first batch (decoded below) so
        # GetFlightInfo can surface it. Done after we decode batch 0.
        var schema_set = False
        var n_produced = Int64(0)
        var now_ms = Int64(0)

        for i in range(1, len(req_messages)):
            var fd = FlightData.decode(Span(req_messages[i]))
            if len(fd.data_header) == 0:
                # A schema-only / metadata-only FlightData (no batch); skip.
                continue
            var batch = flight_data_to_record_batch(
                schema_header.copy(), fd.data_header.copy(), fd.data_body.copy()
            )
            if not schema_set:
                self._data.set_schema(topic, batch.schema.copy())
                schema_set = True
            # NOT LEASE-FENCED. This Flight produce has no assignment or
            # lease ingestion wired in, so `produce` runs at the default lease
            # epochs, which make the manifest append fence a no-op here. To
            # fence it, the coordinator's assigned generations would have to
            # be plumbed into this server and passed to `produce` as
            # writer and current lease epochs.
            # Route to the client-supplied partition (descriptor path[1];
            # default 0). FlightBrokerData.produce bounds-checks it.
            var base = self._data.produce(topic, put_partition, batch^, now_ms)
            n_produced += Int64(1)
            _ = base

        # PutResult with empty app_metadata (the standard "all received" ack).
        var pr = PutResult()
        var out = List[List[UInt8]]()
        out.append(grpc_encode_unary(Span(pr.encode())))
        return GrpcStreamResponse(
            out^, UInt16(200), GRPC_STATUS_OK, String(""), resp_ct^
        )


# =============================================================================
# Helpers — error responses + the raw IPC schema-message bytes for FlightInfo.
# =============================================================================


@always_inline
def _grpc_ct() -> String:
    """A fresh `application/grpc+proto` content-type String."""
    return String(GRPC_CONTENT_TYPE_PROTO)


def _parse_partition(s: String) -> Int:
    """Parse the descriptor path[1] partition segment (a non-negative decimal
    string) to an Int. Returns -1 on a malformed / negative / empty /
    out-of-range value (the DoPut handler maps that to INVALID_ARGUMENT).
    Byte-level digit scan, no String slicing.

    The accumulator is capped in the loop. Without the cap `v = v * 10 + digit`
    silently wraps on a long digit run (Int is 64-bit and the overflow is not
    trapped in every assert mode), so an attacker-chosen digit string could
    land on an arbitrary value including a positive one, defeating the
    `put_partition < 0` rejection at the call site and feeding an arbitrary
    partition COUNT into `add_topic`. Capping at MAX_TOPIC_PARTITIONS also makes
    the value a legal partition index by construction.
    """
    var b = s.as_bytes()
    if len(b) == 0:
        return -1
    var v = Int(0)
    for i in range(len(b)):
        var c = b[i]
        if c < UInt8(48) or c > UInt8(57):  # not '0'..'9'
            return -1
        v = v * 10 + Int(c - UInt8(48))
        # In the loop, BEFORE the next multiply: v can never exceed
        # MAX_TOPIC_PARTITIONS * 10 + 9, so the multiply cannot wrap. Without
        # this, the 25-digit string "9999999999999999999999999" wraps to a
        # positive value that passes the `put_partition < 0` check.
        if v > MAX_TOPIC_PARTITIONS:
            return -1
    return v


def _unary_error(status: UInt8, var message: String) -> GrpcResponse:
    return GrpcResponse(
        List[UInt8](),
        UInt16(200),
        status,
        grpc_percent_encode_message(message),
        String(GRPC_CONTENT_TYPE_PROTO),
        True,
    )


def _stream_error(
    status: UInt8, var message: String, var resp_ct: String
) -> GrpcStreamResponse:
    return GrpcStreamResponse(
        List[List[UInt8]](),
        UInt16(200),
        status,
        grpc_percent_encode_message(message),
        resp_ct^,
    )


def _ipc_schema_message_bytes(var schema: Schema) raises -> List[UInt8]:
    """The raw IPC SCHEMA message frame bytes (what pyarrow's
    `pyarrow.ipc.read_schema` consumes), for FlightInfo.schema. Distinct from
    `encode_schema_flight_data` which wraps it in a FlightData."""
    var frame = encode_schema_message(schema)
    var out = List[UInt8]()
    var n = frame.len()
    for i in range(n):
        out.append(frame.read_u8_at(i))
    _ = frame^
    return out^
