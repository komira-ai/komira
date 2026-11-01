# komira_flight_server

Arrow Flight in front of the broker: a Flight client writes Arrow record
batches into a broker topic and reads them back with no transcoding. The wire
messages and the Arrow IPC bridge are `komira_flight`; this package puts them on
the broker cores.

- `FlightBrokerService` is the service. It conforms to the `GrpcDispatch` and
  `GrpcStreamDispatch` seams of `komira_http_core`, so it installs as
  `HttpServer[FlightBrokerService]` over h2 (TLS with ALPN). It serves
  - **GetFlightInfo** (unary): `FlightDescriptor(path=[topic])` gives a
    `FlightInfo` with the topic's schema, one endpoint per partition (each
    ticket names the topic and the partition) and `total_records`, the sum of
    the partitions' high watermarks.
  - **DoGet** (server stream): a ticket gives the schema message, then one
    `FlightData` per stored batch.
  - **DoPut** (client stream): the first message carries the descriptor and the
    schema, the rest one batch each; the answer is one empty `PutResult`. The
    descriptor path is `[topic]` or `[topic, partition]`; a topic that does not
    exist is created with `partition + 1` partitions.

  The other `FlightService` RPCs (Handshake, ListFlights, PollFlightInfo,
  GetSchema, DoExchange, DoAction, ListActions) are not served and answer
  `NOT_FOUND`. A request the client got wrong is `INVALID_ARGUMENT`: a
  partition that is not a decimal number from 0 to 1024 in a DoPut descriptor
  or a DoGet ticket, a partition past the end of an existing topic, a topic
  name that is empty or longer than 255 bytes (`MAX_TOPIC_NAME_BYTES`), a DoPut
  whose schema differs from the topic's, and a DoPut message that is not a
  valid record batch.

  A DoPut is validated as a whole before it changes anything: every batch is
  decoded, the partition and the schema are checked, and only then is the topic
  registered (when new) and the batches produced. A refused DoPut therefore
  registers no topic and stores no row. One limit remains: each batch is flushed
  to the object store as it is produced, so if the store itself fails part-way
  through a valid stream, the batches before the failure stay stored and the
  client gets an error. A flushed segment cannot be taken back, and this
  server does not group a stream into one flush, so a client that retries after such an error can store those
  batches twice.
- `FlightBrokerData` is the data plane: per topic and partition, one
  `BrokerCore` for produce (each DoPut batch is flushed before it is
  acknowledged) and one `ConsumeCore` for reads, over one in-memory
  conditional-write store. `read_batches` returns whole segments from the one
  holding the start offset: it does not trim rows below it.

DoPut is not lease-fenced: the service has no assignment relay, so produce runs
at the default lease epochs.

## Examples

The data plane on its own: a two-partition topic, one batch produced to
partition 1, and the batch read back from it:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_flight_server import FlightBrokerData

var data = FlightBrokerData(String("example"))
data.add_topic(String("events"), 2)

var schema = Schema(
    names=[String("v")],
    arrow_types=[ArrowType.INT64.type_id],
    dtypes=[DType.int64],
    nullables=[False],
)
var arr = PrimitiveArray[DType.int64].from_list([Int64(7), Int64(8)])
var batch = RecordBatch.from_typed_columns_1(
    schema^, Column.from_primitive[DType.int64](arr^)
)
var base = data.produce(String("events"), 1, batch^, Int64(0))
assert_equal(base, Int64(0))
assert_equal(data.high_watermark(String("events"), 1), Int64(2))
assert_equal(data.high_watermark(String("events"), 0), Int64(0))

var batches = data.read_batches(String("events"), 1, Int64(0))
assert_equal(len(batches), 1)
assert_equal(batches[0].column_as_primitive_int64(0).get(1), Int64(8))
```

The service answering GetFlightInfo for a registered topic: one endpoint per
partition, each ticket naming its partition:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_connect.codec_grpc import grpc_decode_unary, grpc_encode_unary
from komira_flight import BrokerTicket, FlightDescriptor, FlightInfo
from komira_flight_server import (
    FLIGHT_GET_INFO_PATH,
    FlightBrokerData,
    FlightBrokerService,
)

var svc = FlightBrokerService(
    FlightBrokerData(String("example")), String("grpc+tls://broker.example:8815")
)
svc.add_topic(String("events"), 3)

var request = FlightDescriptor.for_path(String("events")).encode()
var response = svc.dispatch_grpc(
    String(FLIGHT_GET_INFO_PATH),
    String("application/grpc+proto"),
    grpc_encode_unary(Span(request)),
)
assert_equal(Int(response.grpc_status), 0)
var info = FlightInfo.decode(grpc_decode_unary(Span(response.body)))
assert_equal(len(info.endpoint), 3)
var ticket = BrokerTicket.decode(Span(info.endpoint[2].ticket.ticket))
assert_equal(ticket.partition, Int64(2))
assert_equal(info.endpoint[0].location[0].uri, String("grpc+tls://broker.example:8815"))
```
