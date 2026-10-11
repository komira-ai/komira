# Kafka wire goldens: provenance

The reference bytes in the `test_kafka_golden_*.mojo` files are written by
hand, one schema field per line, from the Apache Kafka protocol message
schemas. No byte was produced by the codec under test, and none was captured
from a Kafka client or broker.

- Upstream: the `apache/kafka` repository, release tag `3.9.0`, directory
  `clients/src/main/resources/common/message/`.
- Files read: `RequestHeader.json`, `ResponseHeader.json`,
  `FindCoordinatorRequest.json`, `FindCoordinatorResponse.json`,
  `OffsetCommitRequest.json`, `OffsetCommitResponse.json`,
  `OffsetFetchRequest.json`, `OffsetFetchResponse.json`,
  `JoinGroupRequest.json`, `JoinGroupResponse.json`,
  `SyncGroupRequest.json`, `SyncGroupResponse.json`,
  `HeartbeatRequest.json`, `HeartbeatResponse.json`,
  `LeaveGroupRequest.json`, `LeaveGroupResponse.json`,
  `ConsumerProtocolSubscription.json`, `ConsumerProtocolAssignment.json`,
  `CreateTopicsRequest.json`, `CreateTopicsResponse.json`,
  `InitProducerIdRequest.json`, `InitProducerIdResponse.json`,
  `AddPartitionsToTxnRequest.json`, `AddPartitionsToTxnResponse.json`,
  `AddOffsetsToTxnRequest.json`, `AddOffsetsToTxnResponse.json`,
  `EndTxnRequest.json`, `EndTxnResponse.json`,
  `TxnOffsetCommitRequest.json`, `TxnOffsetCommitResponse.json`,
  `ApiVersionsRequest.json`, `ApiVersionsResponse.json`,
  `MetadataRequest.json`, `MetadataResponse.json`,
  `ProduceRequest.json`, `FetchRequest.json`, `FetchResponse.json`,
  `ListOffsetsRequest.json`.
- License: those schema files are Apache License 2.0, copyright the Apache
  Software Foundation. They are not vendored here; the tests contain only
  example messages laid out as the schemas describe.
- Tag 3.9.0 is used because it still defines the old non-flexible versions
  this codec serves (Kafka 4.0 removed several of them).

What each golden test checks, per reference message:

- Request: the reference is the request header plus the body (header v1 for
  a non-flexible version, header v2 for a flexible one, as in InitProducerId
  v2+). The test parses the header, decodes the body at the header's version,
  asserts every decoded field, checks the decoder consumed the message exactly, and checks that
  every strict prefix is refused with the decoder's short-read error.
- Response: the codec has encoders only, so the test encodes the reference's
  field values and asserts byte equality with the reference.
- ConsumerProtocol assignment: decoded, then re-encoded to the same bytes.

Known disagreements between the codec and the schemas are marked
`TODO(kafka-goldens)` in the test that holds the reference, with the case
excluded from `main()`.
