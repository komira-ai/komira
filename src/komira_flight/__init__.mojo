"""komira_flight: Arrow Flight protobuf messages and the Arrow IPC payload bridge.

The pure-message half of the Arrow Flight service, a second way into the
broker that moves Arrow without transcoding. `komira_flight` holds the wire
messages and the Arrow IPC <-> FlightData payload bridge; the broker wiring is
in the `komira_flight_server` package.

  - messages.mojo       : FlightDescriptor / Ticket / Location /
                          FlightEndpoint / FlightInfo / FlightData /
                          PutResult, hand-written against the canonical
                          Flight.proto (field numbers listed in the file).
  - flight_ticket.mojo  : the broker's internal {topic, start_offset,
                          partition} ticket payload codec.
  - flight_payload.mojo : the DoGet schema-first FlightData encoder and the
                          DoPut FlightData -> RecordBatch decoder (the only
                          file that touches the Arrow IPC codec).

Dependency direction:
  komira_flight -> komira_protobuf (wire codec)
  komira_flight -> komira_arrow, komira_arrow_ipc, komira_buffer,
                   komira_op_sources (the IPC payload)

The public API exposes only typed values: small structs, scalars, String, List,
RecordBatch, raised Error. No pointer crosses any boundary; encode appends to
an owned List[UInt8]; decode walks Span views through PbFieldCursor.
"""

from .messages import (
    DESCRIPTOR_TYPE_UNKNOWN,
    DESCRIPTOR_TYPE_PATH,
    DESCRIPTOR_TYPE_CMD,
    FlightDescriptor,
    Ticket,
    Location,
    FlightEndpoint,
    FlightInfo,
    FlightData,
    PutResult,
)

from .flight_ticket import BrokerTicket

from .flight_payload import (
    encode_schema_flight_data,
    encode_batch_flight_data,
    flight_data_to_record_batch,
)
