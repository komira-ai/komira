"""komira_flight_server: the Arrow Flight service adapter for the broker.

The server half of Arrow Flight, a second way into the broker that moves Arrow
without transcoding. `komira_flight` holds the pure wire messages and the Arrow
IPC payload bridge; this package wires those onto the broker cores (BrokerCore
and ConsumeCore over a ConditionalWriteStore) and exposes a
`FlightBrokerService` that conforms to the `GrpcDispatch` and
`GrpcStreamDispatch` seams of `komira_http_core`.

Install it via `HttpServer[FlightBrokerService]` over h2 (TLS with ALPN). It
serves three RPCs:
  GetFlightInfo  (unary)         FlightDescriptor(path=[topic]) -> FlightInfo
  DoGet          (server-stream) Ticket{topic,offset,partition} -> FlightData stream
  DoPut          (client-stream) FlightData stream -> PutResult

The other FlightService RPCs are not served and answer NOT_FOUND.

Dependency direction:
  komira_flight_server -> komira_flight       (messages and payload bridge)
  komira_flight_server -> komira_http_core    (the GrpcDispatch seams)
  komira_flight_server -> komira_connect      (gRPC envelope codec and status)
  komira_flight_server -> komira_broker, komira_arrow, komira_collections,
                          komira_objectstore, komira_op_sources (the data plane)

No pointer type appears in any signature. The data plane is owned by value; the
service is the `G` that HttpServer holds by value for its whole lifetime.
"""

from .flight_broker_data import FlightBrokerData

from .flight_service import (
    FLIGHT_DO_GET_PATH,
    FLIGHT_DO_PUT_PATH,
    FLIGHT_GET_INFO_PATH,
    FlightBrokerService,
)
