# komira_flight

The Arrow Flight wire messages and the bridge between a `RecordBatch` and the
Flight `FlightData` stream. It is the message half of the Flight door into the
broker: the broker wiring is `komira_flight_server`, built on this package.

- `FlightDescriptor`, `Ticket`, `Location`, `FlightEndpoint`, `FlightInfo`,
  `FlightData` and `PutResult` are hand-written against Apache Arrow's
  `Flight.proto` (package `arrow.flight.protocol`). Each has `encode()` to the
  protobuf bytes and a static `decode(bytes)`. The field numbers are listed in
  `messages.mojo` and pinned by the tests. Not modelled, and skipped on decode:
  `FlightEndpoint.expiration_time` and `app_metadata`, `FlightInfo.app_metadata`.
- `BrokerTicket` is the broker's own ticket payload, carried inside a `Ticket`:
  topic, start offset and partition. A ticket without the partition field is
  partition 0.
- `encode_schema_flight_data` and `encode_batch_flight_data` produce the DoGet
  stream: the schema first (the IPC schema message in `data_header`), then one
  `FlightData` per batch (IPC message metadata in `data_header`, IPC body in
  `data_body`). The headers are bare flatbuffers, without the IPC
  continuation-marker and length prefix, as Flight clients expect.
  `flight_data_to_record_batch` is the DoPut direction: it reassembles one
  batch from the schema header, a batch header and its body, and accepts a
  header with or without the prefix.

## Examples

A topic descriptor and the ticket the broker hands back for partition 2 of it,
each through its wire bytes:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_flight import BrokerTicket, FlightDescriptor, Ticket, DESCRIPTOR_TYPE_PATH

var d = FlightDescriptor.decode(Span(FlightDescriptor.for_path(String("orders")).encode()))
assert_equal(d.type, DESCRIPTOR_TYPE_PATH)
assert_equal(d.path[0], String("orders"))

var ticket = Ticket(BrokerTicket(String("orders"), Int64(10), Int64(2)).encode())
var back = BrokerTicket.decode(Span(Ticket.decode(Span(ticket.encode())).ticket))
assert_equal(back.topic, String("orders"))
assert_equal(back.start_offset, Int64(10))
assert_equal(back.partition, Int64(2))
```

A `FlightInfo` that points a client at one endpoint, and a `FlightData` that
carries a descriptor, a header and a body (`data_body` is field 1000):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_flight import (
    FlightData,
    FlightDescriptor,
    FlightEndpoint,
    FlightInfo,
    Location,
    PutResult,
    Ticket,
)

var endpoints = List[FlightEndpoint]()
var locations = List[Location]()
locations.append(Location(String("grpc+tls://broker:8815")))
endpoints.append(FlightEndpoint(Ticket(List[UInt8](length=1, fill=9)), locations^))
var info = FlightInfo(
    List[UInt8](),
    FlightDescriptor.for_path(String("orders")),
    endpoints^,
    Int64(42),
    Int64(-1),
    False,
)
var info_back = FlightInfo.decode(Span(info.encode()))
assert_equal(info_back.total_records, Int64(42))
assert_equal(info_back.endpoint[0].location[0].uri, String("grpc+tls://broker:8815"))

var fd = FlightData.batch_message(List[UInt8](length=2, fill=1), List[UInt8](length=3, fill=2))
var fd_back = FlightData.decode(Span(fd.encode()))
assert_equal(len(fd_back.data_header), 2)
assert_equal(len(fd_back.data_body), 3)
assert_equal(len(PutResult().encode()), 0)
```

A batch through the DoGet encoding and back out of the DoPut decoding:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_flight import (
    FlightData,
    encode_batch_flight_data,
    encode_schema_flight_data,
    flight_data_to_record_batch,
)

var schema = Schema(
    names=[String("v")],
    arrow_types=[ArrowType.INT64.type_id],
    dtypes=[DType.int64],
    nullables=[False],
)
var arr = PrimitiveArray[DType.int64].from_list([Int64(10), Int64(11), Int64(12)])
var batch = RecordBatch.from_typed_columns_1(
    schema.copy(), Column.from_primitive[DType.int64](arr^)
)

var schema_fd = FlightData.decode(Span(encode_schema_flight_data(schema^)))
var batch_fd = FlightData.decode(Span(encode_batch_flight_data(batch^)))
var rt = flight_data_to_record_batch(
    schema_fd.data_header.copy(),
    batch_fd.data_header.copy(),
    batch_fd.data_body.copy(),
)
assert_equal(rt.num_rows(), 3)
assert_equal(rt.column_as_primitive_int64(0).get(2), Int64(12))
```
