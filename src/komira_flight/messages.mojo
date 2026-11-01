# =============================================================================
# messages.mojo: Arrow Flight protobuf wire messages.
# =============================================================================
#
# The Arrow Flight service messages, hand-written against the canonical
# `format/Flight.proto` of Apache Arrow (package `arrow.flight.protocol`). A
# wrong field number silently breaks interop with a Flight client, so each
# message carries its field-number table here, checked against the upstream
# proto:
#   FlightDescriptor { DescriptorType type=1, bytes cmd=2, repeated string path=3 }
#     DescriptorType: UNKNOWN=0, PATH=1, CMD=2
#   Ticket          { bytes ticket=1 }
#   Location        { string uri=1 }
#   FlightEndpoint  { Ticket ticket=1, repeated Location location=2,
#                     Timestamp expiration_time=3, bytes app_metadata=4 }
#   FlightInfo      { bytes schema=1, FlightDescriptor flight_descriptor=2,
#                     repeated FlightEndpoint endpoint=3, int64 total_records=4,
#                     int64 total_bytes=5, bool ordered=6, bytes app_metadata=7 }
#   FlightData      { FlightDescriptor flight_descriptor=1, bytes data_header=2,
#                     bytes app_metadata=3, bytes data_body=1000 }
#   PutResult       { bytes app_metadata=1 }
#
# Fields this file does not model (it skips them on decode and never emits
# them): FlightEndpoint.expiration_time (3) and app_metadata (4), and
# FlightInfo.app_metadata (7). The other Flight messages (Handshake, Criteria,
# Action, Result, PollInfo, SchemaResult and so on) are not here.
#
# This file needs only komira_protobuf. The Arrow IPC <-> FlightData payload
# bridge is flight_payload.mojo, the only file that touches the Arrow IPC codec.
#
# The public API exposes typed values only: small structs, scalars, String,
# List[UInt8], raised Error. Encode appends to an owned List[UInt8]; decode
# walks a Span[UInt8, _] through PbFieldCursor.
# =============================================================================

from komira_protobuf import (
    PbFieldCursor,
    pb_write_varint_field,
    pb_write_bool_field,
    pb_write_string_field,
    pb_write_bytes_field,
    pb_write_message_field,
)


# =============================================================================
# §1 — FlightDescriptor.
# =============================================================================

comptime DESCRIPTOR_TYPE_UNKNOWN: UInt64 = 0
comptime DESCRIPTOR_TYPE_PATH: UInt64 = 1
comptime DESCRIPTOR_TYPE_CMD: UInt64 = 2


struct FlightDescriptor(Copyable, Movable, Deinitable):
    """`FlightDescriptor { type=1, cmd=2, path=3 }`.

    For the broker, `path[0]` is the topic name (PATH descriptors). `cmd` is
    carried verbatim for CMD descriptors (unused by the broker v1 but decoded
    so a CMD client doesn't error)."""

    var type: UInt64
    """DescriptorType enum (UNKNOWN=0 / PATH=1 / CMD=2)."""
    var cmd: List[UInt8]
    """The opaque command bytes (CMD descriptors)."""
    var path: List[String]
    """The path segments (PATH descriptors). path[0] == topic for the broker."""

    def __init__(out self):
        self.type = DESCRIPTOR_TYPE_UNKNOWN
        self.cmd = List[UInt8]()
        self.path = List[String]()

    def __init__(out self, var type: UInt64, var cmd: List[UInt8], var path: List[String]):
        self.type = type
        self.cmd = cmd^
        self.path = path^

    @staticmethod
    def for_path(var topic: String) -> FlightDescriptor:
        """PATH descriptor with a single segment (the broker's topic shape)."""
        var p = List[String]()
        p.append(topic^)
        return FlightDescriptor(DESCRIPTOR_TYPE_PATH, List[UInt8](), p^)

    def encode(self) -> List[UInt8]:
        """Encode to the protobuf wire bytes."""
        var out = List[UInt8]()
        # proto3 omits a zero-valued enum; emit only when non-default.
        if self.type != DESCRIPTOR_TYPE_UNKNOWN:
            pb_write_varint_field(out, 1, self.type)
        if len(self.cmd) > 0:
            pb_write_bytes_field(out, 2, Span(self.cmd))
        for i in range(len(self.path)):
            pb_write_string_field(out, 3, self.path[i])
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> FlightDescriptor:
        var d = FlightDescriptor()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                d.type = cur.read_varint()
            elif tag.field_number == 2:
                d.cmd = cur.read_bytes()
            elif tag.field_number == 3:
                d.path.append(cur.read_string())
            else:
                cur.skip()
        return d^


# =============================================================================
# §2 — Ticket.
# =============================================================================


struct Ticket(Copyable, Movable, Deinitable):
    """`Ticket { ticket=1 }` — opaque bytes the server hands the client in a
    FlightInfo and the client passes back to DoGet. The broker encodes
    {topic, start_offset} INTO the ticket bytes (see flight_ticket.mojo)."""

    var ticket: List[UInt8]

    def __init__(out self):
        self.ticket = List[UInt8]()

    def __init__(out self, var ticket: List[UInt8]):
        self.ticket = ticket^

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        if len(self.ticket) > 0:
            pb_write_bytes_field(out, 1, Span(self.ticket))
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> Ticket:
        var t = Ticket()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                t.ticket = cur.read_bytes()
            else:
                cur.skip()
        return t^


# =============================================================================
# §3 — Location + FlightEndpoint.
# =============================================================================


struct Location(Copyable, Movable, Deinitable):
    """`Location { uri=1 }` — a server URI a client can DoGet from."""

    var uri: String

    def __init__(out self):
        self.uri = String("")

    def __init__(out self, var uri: String):
        self.uri = uri^

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        if len(self.uri.as_bytes()) > 0:
            pb_write_string_field(out, 1, self.uri)
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> Location:
        var loc = Location()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                loc.uri = cur.read_string()
            else:
                cur.skip()
        return loc^


struct FlightEndpoint(Copyable, Movable, Deinitable):
    """`FlightEndpoint { ticket=1, location=2 }`.

    expiration_time (3) + app_metadata (4) are skipped on decode (forward
    compat) and never emitted by the broker v1."""

    var ticket: Ticket
    var location: List[Location]

    def __init__(out self):
        self.ticket = Ticket()
        self.location = List[Location]()

    def __init__(out self, var ticket: Ticket, var location: List[Location]):
        self.ticket = ticket^
        self.location = location^

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        pb_write_message_field(out, 1, self.ticket.encode())
        for i in range(len(self.location)):
            pb_write_message_field(out, 2, self.location[i].encode())
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> FlightEndpoint:
        var ep = FlightEndpoint()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                var f = cur.read_len()
                ep.ticket = Ticket.decode(bytes[f.payload_start:f.payload_end])
            elif tag.field_number == 2:
                var f = cur.read_len()
                ep.location.append(
                    Location.decode(bytes[f.payload_start:f.payload_end])
                )
            else:
                cur.skip()
        return ep^


# =============================================================================
# §4 — FlightInfo.
# =============================================================================


struct FlightInfo(Copyable, Movable, Deinitable):
    """`FlightInfo { schema=1, flight_descriptor=2, endpoint=3,
    total_records=4, total_bytes=5, ordered=6, app_metadata=7 }`.

    `schema` is the topic's Arrow schema AS AN IPC SCHEMA MESSAGE (the bytes
    `pyarrow` parses with `pyarrow.ipc.read_schema`)."""

    var schema: List[UInt8]
    var flight_descriptor: FlightDescriptor
    var endpoint: List[FlightEndpoint]
    var total_records: Int64
    var total_bytes: Int64
    var ordered: Bool

    def __init__(out self):
        self.schema = List[UInt8]()
        self.flight_descriptor = FlightDescriptor()
        self.endpoint = List[FlightEndpoint]()
        self.total_records = Int64(-1)
        self.total_bytes = Int64(-1)
        self.ordered = False

    def __init__(
        out self,
        var schema: List[UInt8],
        var flight_descriptor: FlightDescriptor,
        var endpoint: List[FlightEndpoint],
        total_records: Int64,
        total_bytes: Int64,
        ordered: Bool,
    ):
        self.schema = schema^
        self.flight_descriptor = flight_descriptor^
        self.endpoint = endpoint^
        self.total_records = total_records
        self.total_bytes = total_bytes
        self.ordered = ordered

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        if len(self.schema) > 0:
            pb_write_bytes_field(out, 1, Span(self.schema))
        pb_write_message_field(out, 2, self.flight_descriptor.encode())
        for i in range(len(self.endpoint)):
            pb_write_message_field(out, 3, self.endpoint[i].encode())
        # int64 fields: emit as plain varints (proto int64 is VARINT wire,
        # NOT zigzag). -1 round-trips as a 10-byte varint (two's complement),
        # which is the canonical proto representation for a negative int64.
        if self.total_records != 0:
            pb_write_varint_field(out, 4, UInt64(self.total_records))
        if self.total_bytes != 0:
            pb_write_varint_field(out, 5, UInt64(self.total_bytes))
        if self.ordered:
            pb_write_bool_field(out, 6, self.ordered)
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> FlightInfo:
        var info = FlightInfo()
        # decode defaults: unset int64 -> 0 (proto3 default), not -1.
        info.total_records = Int64(0)
        info.total_bytes = Int64(0)
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                info.schema = cur.read_bytes()
            elif tag.field_number == 2:
                var f = cur.read_len()
                info.flight_descriptor = FlightDescriptor.decode(
                    bytes[f.payload_start:f.payload_end]
                )
            elif tag.field_number == 3:
                var f = cur.read_len()
                info.endpoint.append(
                    FlightEndpoint.decode(bytes[f.payload_start:f.payload_end])
                )
            elif tag.field_number == 4:
                info.total_records = Int64(cur.read_varint())
            elif tag.field_number == 5:
                info.total_bytes = Int64(cur.read_varint())
            elif tag.field_number == 6:
                info.ordered = cur.read_bool()
            else:
                cur.skip()
        return info^


# =============================================================================
# §5 — FlightData.
# =============================================================================


struct FlightData(Copyable, Movable, Deinitable):
    """`FlightData { flight_descriptor=1, data_header=2, app_metadata=3,
    data_body=1000 }`.

    The DoGet/DoPut stream message. `data_header` is the Arrow-IPC message
    METADATA as a bare flatbuffer (no continuation marker or size prefix, which
    is the Flight convention; flight_payload.mojo also accepts a prefixed
    one on DoPut); `data_body` is
    the Arrow-IPC message BODY bytes. `flight_descriptor` rides only the first
    DoPut message (carries the destination topic).

    NOTE: data_body is field 1000, as in Flight.proto. A varint
    tag for field 1000 is `(1000 << 3) | 2 = 8002` which is a 2-byte varint;
    the wire writer handles this transparently."""

    var flight_descriptor: FlightDescriptor
    var has_descriptor: Bool
    var data_header: List[UInt8]
    var app_metadata: List[UInt8]
    var data_body: List[UInt8]

    def __init__(out self):
        self.flight_descriptor = FlightDescriptor()
        self.has_descriptor = False
        self.data_header = List[UInt8]()
        self.app_metadata = List[UInt8]()
        self.data_body = List[UInt8]()

    def __init__(
        out self,
        var flight_descriptor: FlightDescriptor,
        has_descriptor: Bool,
        var data_header: List[UInt8],
        var app_metadata: List[UInt8],
        var data_body: List[UInt8],
    ):
        self.flight_descriptor = flight_descriptor^
        self.has_descriptor = has_descriptor
        self.data_header = data_header^
        self.app_metadata = app_metadata^
        self.data_body = data_body^

    @staticmethod
    def schema_message(var data_header: List[UInt8]) -> FlightData:
        """The DoGet stream's FIRST message: schema only (IPC schema message
        in data_header, empty body, no descriptor)."""
        return FlightData(
            FlightDescriptor(), False, data_header^, List[UInt8](), List[UInt8]()
        )

    @staticmethod
    def batch_message(
        var data_header: List[UInt8], var data_body: List[UInt8]
    ) -> FlightData:
        """A DoGet stream RecordBatch message: IPC message header in
        data_header, IPC body bytes in data_body."""
        return FlightData(
            FlightDescriptor(), False, data_header^, List[UInt8](), data_body^
        )

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        if self.has_descriptor:
            pb_write_message_field(out, 1, self.flight_descriptor.encode())
        if len(self.data_header) > 0:
            pb_write_bytes_field(out, 2, Span(self.data_header))
        if len(self.app_metadata) > 0:
            pb_write_bytes_field(out, 3, Span(self.app_metadata))
        if len(self.data_body) > 0:
            pb_write_bytes_field(out, 1000, Span(self.data_body))
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> FlightData:
        var fd = FlightData()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                var f = cur.read_len()
                fd.flight_descriptor = FlightDescriptor.decode(
                    bytes[f.payload_start:f.payload_end]
                )
                fd.has_descriptor = True
            elif tag.field_number == 2:
                fd.data_header = cur.read_bytes()
            elif tag.field_number == 3:
                fd.app_metadata = cur.read_bytes()
            elif tag.field_number == 1000:
                fd.data_body = cur.read_bytes()
            else:
                cur.skip()
        return fd^


# =============================================================================
# §6 — PutResult.
# =============================================================================


struct PutResult(Copyable, Movable, Deinitable):
    """`PutResult { app_metadata=1 }` — the single DoPut response message."""

    var app_metadata: List[UInt8]

    def __init__(out self):
        self.app_metadata = List[UInt8]()

    def __init__(out self, var app_metadata: List[UInt8]):
        self.app_metadata = app_metadata^

    def encode(self) -> List[UInt8]:
        var out = List[UInt8]()
        if len(self.app_metadata) > 0:
            pb_write_bytes_field(out, 1, Span(self.app_metadata))
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> PutResult:
        var pr = PutResult()
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                pr.app_metadata = cur.read_bytes()
            else:
                cur.skip()
        return pr^
