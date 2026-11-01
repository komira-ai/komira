"""The Flight service's three RPCs, driven through its gRPC dispatch seams.

No socket: the tests call `FlightBrokerService.dispatch_grpc` (GetFlightInfo)
and `dispatch_grpc_stream` (DoGet, DoPut) with gRPC-framed request bodies, as
the h2 serve loop does, and decode the framed responses. What they pin:

  * the DoPut -> GetFlightInfo -> DoGet round trip over a real broker core:
    values, order, the schema, one endpoint per partition, ticket contents;
  * partition routing through the wire (descriptor path[1], ticket field 3);
  * every refusal and its gRPC status: unknown topic and unknown method are
    NOT_FOUND, a malformed or out-of-range request (a partition past the topic,
    a topic name that is empty or too long, a schema that differs from the
    topic's, a batch that does not decode) is INVALID_ARGUMENT, and a protobuf
    that does not parse is INTERNAL; a refused DoPut registers nothing and
    stores no row;
  * the partition-count ceiling that stops a DoPut from asking for an unbounded
    number of cores, including a digit run that would wrap a 64-bit Int.
"""

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_connect.codec_grpc import grpc_append_message, grpc_decode_unary, grpc_encode_unary
from komira_connect.status import (
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_OK,
)
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcResponse,
    GrpcStreamResponse,
)

from komira_flight import (
    BrokerTicket,
    FlightData,
    FlightDescriptor,
    FlightInfo,
    PutResult,
    Ticket,
    encode_batch_flight_data,
    encode_schema_flight_data,
    flight_data_to_record_batch,
)
from komira_flight_server import (
    FLIGHT_DO_GET_PATH,
    FLIGHT_DO_PUT_PATH,
    FLIGHT_GET_INFO_PATH,
    FlightBrokerData,
    FlightBrokerService,
    MAX_TOPIC_NAME_BYTES,
)

comptime _CT = "application/grpc+proto"
comptime _URI = "grpc+tls://broker.example:8815"


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _lb(values: List[UInt8]) -> List[UInt8]:
    """A byte list from a literal."""
    return values.copy()


def _schema(name: String = String("val")) -> Schema:
    return Schema(
        names=[name.copy()],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base: Int64, n: Int, column: String = String("val")) raises -> RecordBatch:
    var values = List[Int64]()
    for i in range(n):
        values.append(base + Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(column), col^)


def _service() raises -> FlightBrokerService:
    return FlightBrokerService(FlightBrokerData(String("flight-svc")), String(_URI))


def _descriptor_path(topic: String, partition: String = String("")) -> FlightDescriptor:
    var d = FlightDescriptor.for_path(topic.copy())
    if len(partition.as_bytes()) > 0:
        d.path.append(partition.copy())
    return d^


def _put_body(
    var descriptor: FlightDescriptor,
    base: Int64,
    n_batches: Int,
    column: String = String("val"),
) raises -> List[UInt8]:
    """A DoPut request body: the schema message carrying the descriptor, then
    `n_batches` batches of three rows, each batch starting `10` above the last."""
    var body = List[UInt8]()
    var first = FlightData.decode(Span(encode_schema_flight_data(_schema(column))))
    first.flight_descriptor = descriptor^
    first.has_descriptor = True
    grpc_append_message(body, Span(first.encode()))
    for b in range(n_batches):
        var fd_bytes = encode_batch_flight_data(_batch(base + Int64(10 * b), 3, column))
        grpc_append_message(body, Span(fd_bytes))
    return body^


def _do_put(mut svc: FlightBrokerService, body: List[UInt8]) -> GrpcStreamResponse:
    return svc.dispatch_grpc_stream(
        String(FLIGHT_DO_PUT_PATH), String(_CT), GRPC_KIND_CLIENT_STREAM, body.copy()
    )


def _do_get(mut svc: FlightBrokerService, ticket: List[UInt8]) -> GrpcStreamResponse:
    return svc.dispatch_grpc_stream(
        String(FLIGHT_DO_GET_PATH),
        String(_CT),
        GRPC_KIND_SERVER_STREAM,
        grpc_encode_unary(Span(Ticket(ticket.copy()).encode())),
    )


def _get_info(mut svc: FlightBrokerService, d: FlightDescriptor) -> GrpcResponse:
    return svc.dispatch_grpc(
        String(FLIGHT_GET_INFO_PATH),
        String(_CT),
        grpc_encode_unary(Span(d.encode())),
    )


def _values_of(resp: GrpcStreamResponse) raises -> List[Int64]:
    """The int64 values of a DoGet response: message 0 is the schema, the rest
    are batches, decoded through the DoPut-side bridge."""
    var out = List[Int64]()
    if len(resp.messages) == 0:
        return out^
    var schema_fd = FlightData.decode(grpc_decode_unary(Span(resp.messages[0])))
    assert_equal(len(schema_fd.data_body), 0)
    for i in range(1, len(resp.messages)):
        var fd = FlightData.decode(grpc_decode_unary(Span(resp.messages[i])))
        var rb = flight_data_to_record_batch(
            schema_fd.data_header.copy(), fd.data_header.copy(), fd.data_body.copy()
        )
        var col = rb.column_as_primitive_int64(0)
        for r in range(rb.num_rows()):
            out.append(col.get(r))
    return out^


# -----------------------------------------------------------------------------
# The round trip.
# -----------------------------------------------------------------------------


def test_put_info_get_round_trip() raises:
    print("  test_put_info_get_round_trip...")
    var svc = _service()
    # DoPut to a topic that does not exist yet registers it (one partition).
    var put = _do_put(svc, _put_body(_descriptor_path(String("t1")), Int64(10), 2))
    assert_equal(Int(put.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(len(put.messages), 1)
    var pr = PutResult.decode(grpc_decode_unary(Span(put.messages[0])))
    assert_equal(len(pr.app_metadata), 0)

    var info_resp = _get_info(svc, FlightDescriptor.for_path(String("t1")))
    assert_equal(Int(info_resp.grpc_status), Int(GRPC_STATUS_OK))
    assert_true(info_resp.emit_trailer)
    var info = FlightInfo.decode(grpc_decode_unary(Span(info_resp.body)))
    assert_equal(info.total_records, Int64(6))
    assert_equal(info.total_bytes, Int64(-1))
    assert_true(len(info.schema) > 0)
    assert_equal(info.flight_descriptor.path[0], String("t1"))
    assert_equal(len(info.endpoint), 1)
    assert_equal(info.endpoint[0].location[0].uri, String(_URI))
    var bt = BrokerTicket.decode(Span(info.endpoint[0].ticket.ticket))
    assert_equal(bt.topic, String("t1"))
    assert_equal(bt.start_offset, Int64(0))
    assert_equal(bt.partition, Int64(0))

    var got = _do_get(svc, info.endpoint[0].ticket.ticket.copy())
    assert_equal(Int(got.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(len(got.messages), 3)  # schema + 2 batches (one per flush)
    var vals = _values_of(got)
    assert_equal(len(vals), 6)
    var want: List[Int64] = [10, 11, 12, 20, 21, 22]
    for i in range(6):
        assert_equal(vals[i], want[i])
    print("    OK: put -> info -> get returns the six rows in order")


def test_partition_routing_over_the_wire() raises:
    print("  test_partition_routing_over_the_wire...")
    var svc = _service()
    # The partition rides the descriptor as path[1]; the topic is registered
    # with partition + 1 partitions.
    var p2 = _do_put(
        svc, _put_body(_descriptor_path(String("orders"), String("2")), Int64(200), 1)
    )
    assert_equal(Int(p2.grpc_status), Int(GRPC_STATUS_OK))
    var p0 = _do_put(
        svc, _put_body(_descriptor_path(String("orders"), String("0")), Int64(100), 1)
    )
    assert_equal(Int(p0.grpc_status), Int(GRPC_STATUS_OK))

    var info = FlightInfo.decode(
        grpc_decode_unary(
            Span(_get_info(svc, FlightDescriptor.for_path(String("orders"))).body)
        )
    )
    assert_equal(len(info.endpoint), 3)  # one endpoint per partition
    assert_equal(info.total_records, Int64(6))
    for p in range(3):
        var bt = BrokerTicket.decode(Span(info.endpoint[p].ticket.ticket))
        assert_equal(bt.partition, Int64(p))
    var v0 = _values_of(_do_get(svc, info.endpoint[0].ticket.ticket.copy()))
    var v1 = _values_of(_do_get(svc, info.endpoint[1].ticket.ticket.copy()))
    var v2 = _values_of(_do_get(svc, info.endpoint[2].ticket.ticket.copy()))
    assert_equal(len(v0), 3)
    assert_equal(v0[0], Int64(100))
    assert_equal(len(v1), 0)  # nothing was put on partition 1
    assert_equal(len(v2), 3)
    assert_equal(v2[0], Int64(200))
    print("    OK: each partition's endpoint returns only its own rows")


def test_do_get_of_an_empty_known_topic_is_schema_only() raises:
    print("  test_do_get_of_an_empty_known_topic...")
    var svc = _service()
    svc.add_topic(String("empty"))
    var bt = BrokerTicket(String("empty"), Int64(0), Int64(0))
    var empty = _do_get(svc, bt.encode())
    assert_equal(Int(empty.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(len(empty.messages), 0)  # no schema and no batch yet
    var info = FlightInfo.decode(
        grpc_decode_unary(
            Span(_get_info(svc, FlightDescriptor.for_path(String("empty"))).body)
        )
    )
    assert_equal(len(info.schema), 0)
    assert_equal(info.total_records, Int64(0))
    # After a put and a get of a different, empty partition the schema is known.
    _ = _do_put(svc, _put_body(_descriptor_path(String("two"), String("1")), Int64(1), 1))
    var p0 = _do_get(svc, BrokerTicket(String("two"), Int64(0), Int64(0)).encode())
    assert_equal(len(p0.messages), 1)  # the schema message alone
    print("    OK: no schema -> empty stream; a known schema -> schema alone")


# -----------------------------------------------------------------------------
# Refusals.
# -----------------------------------------------------------------------------


def test_get_flight_info_refusals() raises:
    print("  test_get_flight_info_refusals...")
    var svc = _service()
    svc.add_topic(String("t"))
    var unknown = _get_info(svc, FlightDescriptor.for_path(String("nope")))
    assert_equal(Int(unknown.grpc_status), Int(GRPC_STATUS_NOT_FOUND))
    assert_equal(len(unknown.body), 0)
    var no_path = _get_info(svc, FlightDescriptor())
    assert_equal(Int(no_path.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # Two envelopes where exactly one is expected.
    var two = List[UInt8]()
    grpc_append_message(two, Span(FlightDescriptor.for_path(String("t")).encode()))
    grpc_append_message(two, Span(FlightDescriptor.for_path(String("t")).encode()))
    var r2 = svc.dispatch_grpc(String(FLIGHT_GET_INFO_PATH), String(_CT), two^)
    assert_equal(Int(r2.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # A different unary method is not served.
    var other = svc.dispatch_grpc(
        String("/arrow.flight.protocol.FlightService/ListFlights"),
        String(_CT),
        grpc_encode_unary(Span(List[UInt8]())),
    )
    assert_equal(Int(other.grpc_status), Int(GRPC_STATUS_NOT_FOUND))
    # A body that is not a gRPC envelope is an internal error here (the
    # envelope split raises), not a crash.
    var junk = svc.dispatch_grpc(
        String(FLIGHT_GET_INFO_PATH), String(_CT), _lb([1, 2, 3])
    )
    assert_equal(Int(junk.grpc_status), Int(GRPC_STATUS_INTERNAL))
    print("    OK: unknown topic / empty path / two messages / other method / junk")


def test_do_get_refusals() raises:
    print("  test_do_get_refusals...")
    var svc = _service()
    svc.add_topic(String("t"))
    var unknown = _do_get(svc, BrokerTicket(String("nope"), Int64(0), Int64(0)).encode())
    assert_equal(Int(unknown.grpc_status), Int(GRPC_STATUS_NOT_FOUND))
    # A partition outside [0, 1024] is the client's error, not an internal one.
    var neg = _do_get(svc, BrokerTicket(String("t"), Int64(0), Int64(-1)).encode())
    assert_equal(Int(neg.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var huge = _do_get(
        svc, BrokerTicket(String("t"), Int64(0), Int64(9_000_000_000)).encode()
    )
    assert_equal(Int(huge.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # In range for the ceiling but not for this topic: also the client's error.
    var past = _do_get(svc, BrokerTicket(String("t"), Int64(0), Int64(5)).encode())
    assert_equal(Int(past.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # Exactly one request message is expected.
    var two = List[UInt8]()
    grpc_append_message(two, Span(Ticket(BrokerTicket(String("t"), Int64(0)).encode()).encode()))
    grpc_append_message(two, Span(Ticket(BrokerTicket(String("t"), Int64(0)).encode()).encode()))
    var r2 = svc.dispatch_grpc_stream(
        String(FLIGHT_DO_GET_PATH), String(_CT), GRPC_KIND_SERVER_STREAM, two^
    )
    assert_equal(Int(r2.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # A truncated envelope never reaches the handler.
    var trunc = svc.dispatch_grpc_stream(
        String(FLIGHT_DO_GET_PATH),
        String(_CT),
        GRPC_KIND_SERVER_STREAM,
        _lb([0, 0, 0, 0, 9, 1]),
    )
    assert_equal(Int(trunc.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # A Ticket whose bytes are not protobuf is an internal error.
    var bad = svc.dispatch_grpc_stream(
        String(FLIGHT_DO_GET_PATH),
        String(_CT),
        GRPC_KIND_SERVER_STREAM,
        grpc_encode_unary(Span(_lb([0x0A, 0x7F]))),
    )
    assert_equal(Int(bad.grpc_status), Int(GRPC_STATUS_INTERNAL))
    # An unknown streaming method.
    var other = svc.dispatch_grpc_stream(
        String("/arrow.flight.protocol.FlightService/DoExchange"),
        String(_CT),
        GRPC_KIND_UNARY,
        List[UInt8](),
    )
    assert_equal(Int(other.grpc_status), Int(GRPC_STATUS_NOT_FOUND))
    print("    OK: every DoGet refusal carries its status")


def _not_registered(mut svc: FlightBrokerService, topic: String) raises:
    var info = _get_info(svc, FlightDescriptor.for_path(topic.copy()))
    assert_equal(
        Int(info.grpc_status),
        Int(GRPC_STATUS_NOT_FOUND),
        String("a refused DoPut registered topic '") + topic + "'",
    )


def test_do_put_refusals() raises:
    print("  test_do_put_refusals...")
    var svc = _service()
    var none = _do_put(svc, List[UInt8]())
    assert_equal(Int(none.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))

    # The first message must carry a descriptor with a path.
    var no_desc = List[UInt8]()
    grpc_append_message(no_desc, Span(encode_schema_flight_data(_schema())))
    assert_equal(Int(_do_put(svc, no_desc).grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var empty_path = _put_body(FlightDescriptor(), Int64(0), 0)
    assert_equal(Int(_do_put(svc, empty_path).grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))

    # The first message must carry the schema header; the topic it names is
    # not registered by the refusal.
    var no_schema = FlightData(
        FlightDescriptor.for_path(String("no_schema")), True, List[UInt8](), List[UInt8](), List[UInt8]()
    )
    var no_schema_body = List[UInt8]()
    grpc_append_message(no_schema_body, Span(no_schema.encode()))
    assert_equal(Int(_do_put(svc, no_schema_body).grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    _not_registered(svc, String("no_schema"))

    # path[1] must be a decimal partition within the ceiling. 25 digits would
    # wrap a 64-bit Int to a positive value if the parser did not cap its
    # accumulator, and a ceiling of 1024 means 1025 is refused.
    var bad_partitions: List[String] = [
        String("abc"),
        String("-1"),
        String("1x"),
        String(" 1"),
        String("1025"),
        String("99999999999"),
        String("9999999999999999999999999"),
    ]
    for i in range(len(bad_partitions)):
        var resp = _do_put(
            svc,
            _put_body(_descriptor_path(String("hostile"), bad_partitions[i]), Int64(0), 1),
        )
        assert_equal(
            Int(resp.grpc_status),
            Int(GRPC_STATUS_INVALID_ARGUMENT),
            String("path[1] = '") + bad_partitions[i] + "'",
        )
        _not_registered(svc, String("hostile"))
    # An empty path[1] is built by hand: `_descriptor_path` drops it.
    var empty_seg = FlightDescriptor.for_path(String("hostile"))
    empty_seg.path.append(String(""))
    assert_equal(
        Int(_do_put(svc, _put_body(empty_seg^, Int64(0), 1)).grpc_status),
        Int(GRPC_STATUS_INVALID_ARGUMENT),
    )
    _not_registered(svc, String("hostile"))

    # A partition past the end of an existing topic is the client's error, and
    # nothing is produced.
    svc.add_topic(String("two"), 2)
    var past = _do_put(svc, _put_body(_descriptor_path(String("two"), String("2")), Int64(0), 1))
    assert_equal(Int(past.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    assert_equal(len(_values_of(_do_get(svc, BrokerTicket(String("two"), Int64(0), Int64(0)).encode()))), 0)

    # A truncated envelope never reaches the handler.
    var trunc = _do_put(svc, _lb([0, 0, 0, 0, 9, 1]))
    assert_equal(Int(trunc.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    print("    OK: every DoPut refusal carries its status; none registers a topic")


def test_topic_name_limits() raises:
    print("  test_topic_name_limits...")
    var svc = _service()
    var empty = _do_put(svc, _put_body(FlightDescriptor.for_path(String("")), Int64(0), 1))
    assert_equal(Int(empty.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var longest = String("")
    for _ in range(MAX_TOPIC_NAME_BYTES):
        longest += "a"
    var ok = _do_put(svc, _put_body(FlightDescriptor.for_path(longest.copy()), Int64(0), 1))
    assert_equal(Int(ok.grpc_status), Int(GRPC_STATUS_OK))
    var too_long = longest + "a"
    var refused = _do_put(svc, _put_body(FlightDescriptor.for_path(too_long.copy()), Int64(0), 1))
    assert_equal(Int(refused.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    _not_registered(svc, too_long)
    # The data plane refuses the same names for a caller that skips the service.
    var data = FlightBrokerData(String("names"))
    var raised = False
    try:
        data.add_topic(String(""), 1)
    except:
        raised = True
    assert_true(raised, "an empty topic name must raise")
    raised = False
    try:
        data.add_topic(too_long.copy(), 1)
    except:
        raised = True
    assert_true(raised, "an over-long topic name must raise")
    print("    OK: empty and over-long topic names are refused, the longest is accepted")


def test_do_put_schema_mismatch_is_refused() raises:
    print("  test_do_put_schema_mismatch_is_refused...")
    var svc = _service()
    var first = _do_put(svc, _put_body(_descriptor_path(String("t")), Int64(10), 1))
    assert_equal(Int(first.grpc_status), Int(GRPC_STATUS_OK))
    # A second DoPut under another schema (another column name) is refused and
    # leaves the topic as it was.
    var other = _do_put(
        svc, _put_body(_descriptor_path(String("t")), Int64(500), 1, String("other"))
    )
    assert_equal(Int(other.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var got = _do_get(svc, BrokerTicket(String("t"), Int64(0), Int64(0)).encode())
    assert_equal(len(got.messages), 2)  # the first schema + the first batch only
    var vals = _values_of(got)
    assert_equal(len(vals), 3)
    assert_equal(vals[0], Int64(10))
    var info = FlightInfo.decode(
        grpc_decode_unary(Span(_get_info(svc, FlightDescriptor.for_path(String("t"))).body))
    )
    assert_equal(info.total_records, Int64(3))
    # The same schema again is still accepted.
    var again = _do_put(svc, _put_body(_descriptor_path(String("t")), Int64(20), 1))
    assert_equal(Int(again.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(len(_values_of(_do_get(svc, BrokerTicket(String("t"), Int64(0), Int64(0)).encode()))), 6)
    print("    OK: a different schema is refused and changes nothing")


def test_do_put_with_a_bad_batch_stores_nothing() raises:
    print("  test_do_put_with_a_bad_batch_stores_nothing...")
    var svc = _service()
    # Schema, a good batch, then a batch whose header is not an IPC message.
    var body = _put_body(_descriptor_path(String("atomic")), Int64(1), 1)
    var bad = FlightData.batch_message(_lb([1, 2, 3, 4, 5, 6, 7, 8]), _lb([9, 9]))
    grpc_append_message(body, Span(bad.encode()))
    var resp = _do_put(svc, body)
    assert_equal(Int(resp.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    # A refused new topic is not registered and holds no rows.
    _not_registered(svc, String("atomic"))

    # On an existing topic, the good first batch of a refused DoPut is not stored.
    var ok = _do_put(svc, _put_body(_descriptor_path(String("kept")), Int64(100), 1))
    assert_equal(Int(ok.grpc_status), Int(GRPC_STATUS_OK))
    var body2 = _put_body(_descriptor_path(String("kept")), Int64(200), 1)
    grpc_append_message(body2, Span(bad.encode()))
    assert_equal(Int(_do_put(svc, body2).grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var vals = _values_of(_do_get(svc, BrokerTicket(String("kept"), Int64(0), Int64(0)).encode()))
    assert_equal(len(vals), 3)
    assert_equal(vals[0], Int64(100))
    print("    OK: one bad batch refuses the whole DoPut and stores no row of it")


def test_partition_1024_edge() raises:
    print("  test_partition_1024_edge...")
    var svc = _service()
    # path[1] = "1024" is the highest partition a DoPut can name; it creates a
    # 1025-partition topic.
    var put = _do_put(svc, _put_body(_descriptor_path(String("wide"), String("1024")), Int64(7), 1))
    assert_equal(Int(put.grpc_status), Int(GRPC_STATUS_OK))
    var last = _values_of(_do_get(svc, BrokerTicket(String("wide"), Int64(0), Int64(1024)).encode()))
    assert_equal(len(last), 3)
    assert_equal(last[0], Int64(7))
    var first = _do_get(svc, BrokerTicket(String("wide"), Int64(0), Int64(0)).encode())
    assert_equal(Int(first.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(len(_values_of(first)), 0)
    # One past the topic is the client's error, not an internal one.
    var past = _do_get(svc, BrokerTicket(String("wide"), Int64(0), Int64(1025)).encode())
    assert_equal(Int(past.grpc_status), Int(GRPC_STATUS_INVALID_ARGUMENT))
    var info = FlightInfo.decode(
        grpc_decode_unary(Span(_get_info(svc, FlightDescriptor.for_path(String("wide"))).body))
    )
    assert_equal(len(info.endpoint), 1025)
    print("    OK: partition 1024 of a 1025-partition topic is served; 1025 is refused")


def test_do_put_skips_header_less_messages() raises:
    print("  test_do_put_skips_header_less_messages...")
    var svc = _service()
    var body = _put_body(_descriptor_path(String("skip")), Int64(1), 1)
    # A trailing FlightData with no data_header (a metadata-only message).
    grpc_append_message(body, Span(FlightData().encode()))
    assert_equal(Int(_do_put(svc, body).grpc_status), Int(GRPC_STATUS_OK))
    var vals = _values_of(_do_get(svc, BrokerTicket(String("skip"), Int64(0), Int64(0)).encode()))
    assert_equal(len(vals), 3)
    print("    OK: a header-less FlightData is skipped, not produced")


def test_stream_kind_and_data_plane_limits() raises:
    print("  test_stream_kind_and_data_plane_limits...")
    var svc = _service()
    assert_equal(Int(svc.grpc_stream_kind(String(FLIGHT_DO_GET_PATH))), Int(GRPC_KIND_SERVER_STREAM))
    assert_equal(Int(svc.grpc_stream_kind(String(FLIGHT_DO_PUT_PATH))), Int(GRPC_KIND_CLIENT_STREAM))
    assert_equal(Int(svc.grpc_stream_kind(String(FLIGHT_GET_INFO_PATH))), Int(GRPC_KIND_UNARY))

    var data = FlightBrokerData(String("limits"))
    var raised = False
    try:
        data.add_topic(String("zero"), 0)
    except:
        raised = True
    assert_true(raised, "0 partitions must raise")
    raised = False
    try:
        data.add_topic(String("many"), 1026)
    except:
        raised = True
    assert_true(raised, "1026 partitions must raise")
    assert_true(not data.has_topic(String("many")))
    # add_topic is idempotent: a second call with another count changes nothing.
    data.add_topic(String("t"), 2)
    data.add_topic(String("t"), 5)
    assert_equal(data.num_partitions(String("t")), 2)
    # Unknown-topic accessors raise.
    raised = False
    try:
        _ = data.num_partitions(String("missing"))
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        data.set_schema(String("missing"), _schema())
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = data.schema_copy(String("t"))  # known topic, no schema yet
    except:
        raised = True
    assert_true(raised)
    assert_true(not data.has_schema(String("missing")))
    print("    OK: stream kinds map; partition counts are bounded")


def main() raises:
    print("== Flight service dispatch ==")
    test_put_info_get_round_trip()
    test_partition_routing_over_the_wire()
    test_do_get_of_an_empty_known_topic_is_schema_only()
    test_get_flight_info_refusals()
    test_do_get_refusals()
    test_do_put_refusals()
    test_topic_name_limits()
    test_do_put_schema_mismatch_is_refused()
    test_do_put_with_a_bad_batch_stores_nothing()
    test_partition_1024_edge()
    test_do_put_skips_header_less_messages()
    test_stream_kind_and_data_plane_limits()
    print("== Flight service dispatch PASSED (12 tests) ==")
