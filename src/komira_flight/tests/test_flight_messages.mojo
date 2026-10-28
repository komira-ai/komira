# =============================================================================
# test_flight_messages.mojo — Arrow Flight message + payload round-trip suite.
# =============================================================================
#
# Offline unit gate. Each Flight protobuf message
# encode->decode is byte/value-faithful; the FlightData carrying a real
# IPC-encoded RecordBatch round-trips back to an equal batch through the
# DoGet/DoPut payload bridge (the SAME encode_batch_flight_data /
# flight_data_to_record_batch the live server uses).
#
# Field numbers follow the canonical Flight.proto (see messages.mojo). The
# golden-bytes tests pin them against hand-written wire bytes; the round-trips
# prove the encoder and decoder agree.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_flight import (
    BrokerTicket,
    DESCRIPTOR_TYPE_PATH,
    DESCRIPTOR_TYPE_CMD,
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
from komira_arrow_ipc.ipc_encoder_dispatch import encode_schema_message


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _bytes(var s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _lb(values: List[UInt8]) -> List[UInt8]:
    """A byte list from a literal."""
    return values.copy()


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """A 1-column Int64 RecordBatch of `n` rows: val[i] = base_val + i."""
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var values = List[Int64]()
    for i in range(n):
        values.append(base_val + Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# -----------------------------------------------------------------------------
# T1 — FlightDescriptor round-trip (PATH + CMD).
# -----------------------------------------------------------------------------


def test_descriptor_roundtrip() raises:
    print("  test_descriptor_roundtrip...")
    # PATH descriptor with two segments.
    var path = List[String]()
    path.append(String("topic-a"))
    path.append(String("sub"))
    var d = FlightDescriptor(DESCRIPTOR_TYPE_PATH, List[UInt8](), path^)
    var d2 = FlightDescriptor.decode(Span(d.encode()))
    assert_equal(d2.type, DESCRIPTOR_TYPE_PATH)
    assert_equal(len(d2.path), 2)
    assert_equal(d2.path[0], String("topic-a"))
    assert_equal(d2.path[1], String("sub"))
    assert_equal(len(d2.cmd), 0)

    # CMD descriptor with opaque bytes.
    var cmd = _bytes(String("SELECT 1"))
    var dc = FlightDescriptor(DESCRIPTOR_TYPE_CMD, cmd^, List[String]())
    var dc2 = FlightDescriptor.decode(Span(dc.encode()))
    assert_equal(dc2.type, DESCRIPTOR_TYPE_CMD)
    assert_equal(len(dc2.cmd), 8)
    assert_equal(dc2.cmd[0], UInt8(ord("S")))
    assert_equal(len(dc2.path), 0)
    print("    OK")


# -----------------------------------------------------------------------------
# T2 — Ticket + BrokerTicket round-trip.
# -----------------------------------------------------------------------------


def test_ticket_roundtrip() raises:
    print("  test_ticket_roundtrip...")
    var t = Ticket(_bytes(String("opaque-ticket-bytes")))
    var t2 = Ticket.decode(Span(t.encode()))
    assert_equal(len(t2.ticket), "opaque-ticket-bytes".byte_length())
    assert_equal(t2.ticket[0], UInt8(ord("o")))

    # BrokerTicket {topic, offset}.
    var bt = BrokerTicket(String("orders"), Int64(4096))
    var bt2 = BrokerTicket.decode(Span(bt.encode()))
    assert_equal(bt2.topic, String("orders"))
    assert_equal(bt2.start_offset, Int64(4096))

    # offset 0 (proto3-omitted varint) still decodes to 0.
    var bt0 = BrokerTicket(String("t0"), Int64(0))
    var bt0d = BrokerTicket.decode(Span(bt0.encode()))
    assert_equal(bt0d.topic, String("t0"))
    assert_equal(bt0d.start_offset, Int64(0))
    print("    OK")


# -----------------------------------------------------------------------------
# T3 — FlightInfo round-trip (nested descriptor + repeated endpoints).
# -----------------------------------------------------------------------------


def test_flight_info_roundtrip() raises:
    print("  test_flight_info_roundtrip...")
    # A real IPC schema message as the schema bytes.
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var frame = encode_schema_message(schema)
    var schema_bytes = List[UInt8]()
    for i in range(frame.len()):
        schema_bytes.append(frame.read_u8_at(i))
    _ = frame^
    var schema_len = len(schema_bytes)

    # Two endpoints, each with a ticket + a location.
    var endpoints = List[FlightEndpoint]()
    for k in range(2):
        var bt = BrokerTicket(String("topic-x"), Int64(k * 10))
        var ticket = Ticket(bt.encode())
        var locs = List[Location]()
        locs.append(Location(String("grpc+tls://broker.example:5000")))
        endpoints.append(FlightEndpoint(ticket^, locs^))

    var info = FlightInfo(
        schema_bytes^,
        FlightDescriptor.for_path(String("topic-x")),
        endpoints^,
        Int64(123),
        Int64(-1),
        False,
    )
    var info2 = FlightInfo.decode(Span(info.encode()))

    assert_equal(len(info2.schema), schema_len)
    assert_equal(info2.total_records, Int64(123))
    assert_equal(info2.total_bytes, Int64(-1))
    assert_equal(len(info2.flight_descriptor.path), 1)
    assert_equal(info2.flight_descriptor.path[0], String("topic-x"))
    assert_equal(len(info2.endpoint), 2)
    # endpoint[1]'s ticket carries BrokerTicket{topic-x, offset=10}.
    var bt1 = BrokerTicket.decode(Span(info2.endpoint[1].ticket.ticket))
    assert_equal(bt1.topic, String("topic-x"))
    assert_equal(bt1.start_offset, Int64(10))
    assert_equal(len(info2.endpoint[0].location), 1)
    assert_equal(
        info2.endpoint[0].location[0].uri,
        String("grpc+tls://broker.example:5000"),
    )
    print("    OK")


# -----------------------------------------------------------------------------
# T4 — FlightData round-trip (the big field number 1000 + descriptor).
# -----------------------------------------------------------------------------


def test_flight_data_roundtrip() raises:
    print("  test_flight_data_roundtrip...")
    var header = _bytes(String("HEADER-BYTES"))
    var body = _bytes(String("BODY-BYTES-AT-FIELD-1000"))
    var fd = FlightData.batch_message(header^, body^)
    var fd2 = FlightData.decode(Span(fd.encode()))
    assert_equal(len(fd2.data_header), "HEADER-BYTES".byte_length())
    assert_equal(fd2.data_header[0], UInt8(ord("H")))
    # data_body is field 1000 — verify it round-trips through the 2-byte tag.
    assert_equal(len(fd2.data_body), "BODY-BYTES-AT-FIELD-1000".byte_length())
    assert_equal(fd2.data_body[0], UInt8(ord("B")))
    assert_true(not fd2.has_descriptor)

    # FlightData with a descriptor (the DoPut first-message shape).
    var d = FlightDescriptor.for_path(String("dest-topic"))
    var schema_hdr = _bytes(String("SCHEMA-MSG"))
    var fdd = FlightData(d^, True, schema_hdr^, List[UInt8](), List[UInt8]())
    var fdd2 = FlightData.decode(Span(fdd.encode()))
    assert_true(fdd2.has_descriptor)
    assert_equal(fdd2.flight_descriptor.path[0], String("dest-topic"))
    assert_equal(len(fdd2.data_header), "SCHEMA-MSG".byte_length())
    assert_equal(len(fdd2.data_body), 0)
    print("    OK")


# -----------------------------------------------------------------------------
# T5 — PutResult round-trip.
# -----------------------------------------------------------------------------


def test_put_result_roundtrip() raises:
    print("  test_put_result_roundtrip...")
    var pr = PutResult(_bytes(String("meta")))
    var pr2 = PutResult.decode(Span(pr.encode()))
    assert_equal(len(pr2.app_metadata), 4)
    assert_equal(pr2.app_metadata[0], UInt8(ord("m")))

    # Empty PutResult (the standard "all received" ack) decodes cleanly.
    var pre = PutResult()
    var pre2 = PutResult.decode(Span(pre.encode()))
    assert_equal(len(pre2.app_metadata), 0)
    print("    OK")


# -----------------------------------------------------------------------------
# T6 — RecordBatch <-> FlightData payload bridge (the real IPC path).
# -----------------------------------------------------------------------------


def test_record_batch_flight_data_roundtrip() raises:
    print("  test_record_batch_flight_data_roundtrip...")
    var n = 5
    var batch = _make_int64_batch(Int64(100), n)

    # DoGet encode: schema FlightData + batch FlightData.
    var schema_fd_bytes = encode_schema_flight_data(batch.schema.copy())
    var batch_fd_bytes = encode_batch_flight_data(batch^)

    # Decode the FlightData protobufs back.
    var schema_fd = FlightData.decode(Span(schema_fd_bytes))
    var batch_fd = FlightData.decode(Span(batch_fd_bytes))
    assert_true(len(schema_fd.data_header) > 0)
    assert_equal(len(schema_fd.data_body), 0)  # schema msg has no body
    assert_true(len(batch_fd.data_header) > 0)
    assert_true(len(batch_fd.data_body) > 0)  # int64 body present

    # DoPut decode: reassemble + decode back to a RecordBatch.
    var rt = flight_data_to_record_batch(
        schema_fd.data_header.copy(),
        batch_fd.data_header.copy(),
        batch_fd.data_body.copy(),
    )
    assert_equal(rt.num_rows(), n)
    assert_equal(rt.num_columns(), 1)
    var col = rt.column_as_primitive_int64(0)
    for i in range(n):
        assert_equal(col.get(i), Int64(100) + Int64(i))
    print("    OK — RecordBatch -> FlightData -> RecordBatch byte-faithful")


def test_wire_golden_field_numbers() raises:
    print("  test_wire_golden_field_numbers...")
    # FlightDescriptor { type=1 (PATH=1), path=3 "ab" } -> 08 01 1a 02 'a' 'b'
    var d = FlightDescriptor.for_path(String("ab"))
    assert_equal(d.encode(), _lb([0x08, 0x01, 0x1A, 0x02, 0x61, 0x62]))
    # FlightDescriptor { type=2 (CMD), cmd=2 [7] } -> 08 02 12 01 07
    var c = FlightDescriptor(DESCRIPTOR_TYPE_CMD, _lb([7]), List[String]())
    assert_equal(c.encode(), _lb([0x08, 0x02, 0x12, 0x01, 0x07]))
    # Ticket { ticket=1 [9] } -> 0a 01 09
    assert_equal(Ticket(_lb([9])).encode(), _lb([0x0A, 0x01, 0x09]))
    # Location { uri=1 "u" } -> 0a 01 'u'
    assert_equal(Location(String("u")).encode(), _lb([0x0A, 0x01, 0x75]))
    # PutResult { app_metadata=1 [5] } -> 0a 01 05
    assert_equal(PutResult(_lb([5])).encode(), _lb([0x0A, 0x01, 0x05]))
    # FlightData: data_header=2, app_metadata=3, data_body=1000 (tag 0xC2 0x3E).
    var fd = FlightData(
        FlightDescriptor(),
        False,
        _lb([1]),
        _lb([2]),
        _lb([3]),
    )
    assert_equal(
        fd.encode(),
        _lb([0x12, 0x01, 0x01, 0x1A, 0x01, 0x02, 0xC2, 0x3E, 0x01, 0x03]),
    )
    # FlightData with a descriptor: flight_descriptor=1 is a message field.
    var fd2 = FlightData(
        FlightDescriptor.for_path(String("t")),
        True,
        List[UInt8](),
        List[UInt8](),
        List[UInt8](),
    )
    assert_equal(
        fd2.encode(),
        _lb([0x0A, 0x05, 0x08, 0x01, 0x1A, 0x01, 0x74]),
    )
    # FlightInfo { schema=1, descriptor=2, endpoint=3, total_records=4,
    # total_bytes=5, ordered=6 }; a FlightEndpoint is { ticket=1, location=2 }.
    var eps = List[FlightEndpoint]()
    eps.append(FlightEndpoint(Ticket(_lb([9])), List[Location]()))
    var info = FlightInfo(
        _lb([4]),
        FlightDescriptor(),
        eps^,
        Int64(3),
        Int64(5),
        True,
    )
    assert_equal(
        info.encode(),
        _lb([
            0x0A, 0x01, 0x04,  # schema
            0x12, 0x00,  # empty descriptor
            0x1A, 0x05, 0x0A, 0x03, 0x0A, 0x01, 0x09,  # endpoint { ticket { 9 } }
            0x20, 0x03,  # total_records = 3
            0x28, 0x05,  # total_bytes = 5
            0x30, 0x01,  # ordered
        ]),
    )
    print("    OK: every message encodes the canonical field numbers")


def test_flight_data_skips_unmodelled_fields() raises:
    print("  test_flight_data_skips_unmodelled_fields...")
    # A FlightEndpoint carrying expiration_time (3) and app_metadata (4) next to
    # its ticket decodes with those two fields skipped.
    var wire = _lb([
        0x0A, 0x03, 0x0A, 0x01, 0x09,  # ticket { 9 }
        0x1A, 0x02, 0x08, 0x01,  # expiration_time { seconds = 1 }
        0x22, 0x01, 0x07,  # app_metadata
    ])
    var ep = FlightEndpoint.decode(Span(wire))
    assert_equal(ep.ticket.ticket, _lb([9]))
    assert_equal(len(ep.location), 0)
    print("    OK: unmodelled fields are skipped, modelled ones kept")


def test_ticket_partition_back_compat() raises:
    print("  test_ticket_partition_back_compat...")
    # Partition 0 and offset 0 are omitted on the wire, so a ticket for
    # partition 0 is the same bytes a ticket without the field would be.
    var t0 = BrokerTicket(String("t"), Int64(0), Int64(0))
    assert_equal(t0.encode(), _lb([0x0A, 0x01, 0x74]))
    var back = BrokerTicket.decode(Span(t0.encode()))
    assert_equal(back.partition, Int64(0))
    var t3 = BrokerTicket(String("t"), Int64(5), Int64(3))
    assert_equal(
        t3.encode(), _lb([0x0A, 0x01, 0x74, 0x10, 0x05, 0x18, 0x03])
    )
    var back3 = BrokerTicket.decode(Span(t3.encode()))
    assert_equal(back3.topic, String("t"))
    assert_equal(back3.start_offset, Int64(5))
    assert_equal(back3.partition, Int64(3))
    print("    OK: absent partition decodes to 0; the fields round-trip")


def test_schema_header_is_bare_flatbuffer() raises:
    print("  test_schema_header_is_bare_flatbuffer...")
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var fd = FlightData.decode(Span(encode_schema_flight_data(schema^)))
    # The encapsulation prefix (0xFFFFFFFF + length) is stripped from the header.
    assert_true(len(fd.data_header) > 0)
    assert_true(
        not (
            fd.data_header[0] == UInt8(0xFF)
            and fd.data_header[1] == UInt8(0xFF)
            and fd.data_header[2] == UInt8(0xFF)
            and fd.data_header[3] == UInt8(0xFF)
        )
    )
    assert_equal(len(fd.data_header) % 8, 0)
    print("    OK: data_header carries no encapsulation prefix")


def test_prefixed_data_header_accepted_on_put() raises:
    print("  test_prefixed_data_header_accepted_on_put...")
    # DoPut accepts a data_header that still carries the 0xFFFFFFFF + length
    # prefix as well as the bare one, and decodes the same batch from both.
    var batch = _make_int64_batch(Int64(7), 3)
    var schema_bare = FlightData.decode(
        Span(encode_schema_flight_data(batch.schema.copy()))
    ).data_header.copy()
    var fd = FlightData.decode(Span(encode_batch_flight_data(batch^)))

    def _prefixed(bare: List[UInt8]) -> List[UInt8]:
        var out = _lb([0xFF, 0xFF, 0xFF, 0xFF])
        var n = len(bare)
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 24) & 0xFF))
        for i in range(n):
            out.append(bare[i])
        return out^

    var rt = flight_data_to_record_batch(
        _prefixed(schema_bare), _prefixed(fd.data_header), fd.data_body.copy()
    )
    assert_equal(rt.num_rows(), 3)
    var col = rt.column_as_primitive_int64(0)
    for i in range(3):
        assert_equal(col.get(i), Int64(7) + Int64(i))
    print("    OK: prefixed and bare headers decode alike")


def test_unknown_fields_skipped_in_every_message() raises:
    print("  test_unknown_fields_skipped_in_every_message...")
    # Field 15 as a varint (tag 0x78, value 1) follows every modelled field.
    var junk = _lb([0x78, 0x01])

    var d = FlightDescriptor.for_path(String("t")).encode()
    d.extend(junk.copy())
    assert_equal(FlightDescriptor.decode(Span(d)).path[0], String("t"))

    var t = Ticket(_lb([9])).encode()
    t.extend(junk.copy())
    assert_equal(Ticket.decode(Span(t)).ticket, _lb([9]))

    var l = Location(String("u")).encode()
    l.extend(junk.copy())
    assert_equal(Location.decode(Span(l)).uri, String("u"))

    var e = FlightEndpoint(Ticket(_lb([9])), List[Location]()).encode()
    e.extend(junk.copy())
    assert_equal(FlightEndpoint.decode(Span(e)).ticket.ticket, _lb([9]))

    var f = FlightInfo(
        _lb([4]), FlightDescriptor(), List[FlightEndpoint](), Int64(3), Int64(5), True
    ).encode()
    f.extend(junk.copy())
    var fi = FlightInfo.decode(Span(f))
    assert_equal(fi.total_records, Int64(3))
    assert_equal(fi.total_bytes, Int64(5))
    assert_true(fi.ordered)

    var fd = FlightData(
        FlightDescriptor(), False, _lb([1]), _lb([2]), _lb([3])
    ).encode()
    fd.extend(junk.copy())
    var fdd = FlightData.decode(Span(fd))
    assert_equal(fdd.data_header, _lb([1]))
    assert_equal(fdd.app_metadata, _lb([2]))
    assert_equal(fdd.data_body, _lb([3]))

    var p = PutResult(_lb([5])).encode()
    p.extend(junk.copy())
    assert_equal(PutResult.decode(Span(p)).app_metadata, _lb([5]))

    var bt = BrokerTicket(String("t"), Int64(1), Int64(2)).encode()
    bt.extend(junk.copy())
    assert_equal(BrokerTicket.decode(Span(bt)).partition, Int64(2))
    print("    OK: an unknown field is skipped by every decoder")


def test_flight_info_defaults_and_unset_decode() raises:
    print("  test_flight_info_defaults_and_unset_decode...")
    # A default FlightInfo means "unknown" for the two counts (-1) on the way
    # out, and an empty message decodes to proto3's zeros.
    var info = FlightInfo()
    assert_equal(info.total_records, Int64(-1))
    assert_equal(info.total_bytes, Int64(-1))
    var empty = FlightInfo.decode(Span(List[UInt8]()))
    assert_equal(empty.total_records, Int64(0))
    assert_equal(empty.total_bytes, Int64(0))
    assert_true(not empty.ordered)
    # -1 is the 10-byte two's-complement varint, and decodes back to -1.
    var back = FlightInfo.decode(Span(info.encode()))
    assert_equal(back.total_records, Int64(-1))
    assert_equal(back.total_bytes, Int64(-1))
    print("    OK: -1 survives the wire; an empty message decodes to zeros")


def main() raises:
    print("== Arrow Flight message + payload suite ==")
    test_descriptor_roundtrip()
    test_ticket_roundtrip()
    test_flight_info_roundtrip()
    test_flight_data_roundtrip()
    test_put_result_roundtrip()
    test_record_batch_flight_data_roundtrip()
    test_wire_golden_field_numbers()
    test_flight_data_skips_unmodelled_fields()
    test_ticket_partition_back_compat()
    test_schema_header_is_bare_flatbuffer()
    test_prefixed_data_header_accepted_on_put()
    test_unknown_fields_skipped_in_every_message()
    test_flight_info_defaults_and_unset_decode()
    print("== Arrow Flight message + payload suite PASSED (13 tests) ==")
