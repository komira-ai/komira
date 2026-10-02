"""komira_kafka_server.wire — the Kafka wire-protocol codec

Source of truth: the Apache Kafka binary protocol spec
(https://kafka.apache.org/protocol.html) — a fixed external spec.

This subpackage is a pure-bytes WIRE EDGE: framing + primitive types + the
request/response message schemas encode/decode. It is kept SEPARATE from the
broker cores (komira_broker) exactly like the [Format] codec edge — the codec
translates Kafka wire <-> Mojo values; the broker core operates on
RecordBatch + offset.

Dependency DAG: komira_kafka_server.wire imports nothing outside itself (pure
bytes). The
broker/server layer that wires it up sources a Metadata response's partition
count from BrokerTopicConfig.num_partitions (komira_broker) and hands it to
`encode_metadata_response_v1` as a plain Int — the codec never imports the
broker, so the wire edge stays decoupled.

Modules:
  * wire.mojo            — KafkaEncoder / KafkaDecoder + all primitive types
                           (INT8/16/32/64, BOOLEAN, STRING, NULLABLE_STRING,
                           BYTES, ARRAY, UNSIGNED_VARINT, COMPACT_STRING,
                           COMPACT_ARRAY, TAG_BUFFER) — big-endian,
                           encapsulated cursor.
  * messages.mojo        — request-header parse, response-header encode,
                           ApiVersions request/response, Metadata
                           request/response v1, and the INT32 length-prefix
                           framing.
  * crc32c.mojo          — CRC-32C (Castagnoli) over a byte span.
  * record_batch_v2.mojo — the Kafka v2 RecordBatch (KIP-98) codec +
                           zigzag varint/varlong.
  * produce_fetch.mojo   — Produce / Fetch / ListOffsets request+response
                           message schemas (non-flexible versions).
  * consumer_group.mojo, create_topics.mojo, init_producer_id.mojo,
    transaction.mojo     — the consumer-group, topic-admin, idempotent-producer
                           and transactional RPC codecs.
"""

from .wire import KafkaEncoder, KafkaDecoder, TaggedField

from .crc32c import crc32c_span, crc32c_list

from .record_batch_v2 import (
    KafkaHeader,
    KafkaRecord,
    DecodedRecordBatch,
    encode_record_batch_v2,
    encode_record_batch_v2_compressed,
    encode_record_array_plaintext,
    record_batch_first_timestamp,
    record_batch_max_timestamp,
    decode_record_batch_v2,
    decode_record_batches,
    put_varint,
    put_varlong,
    get_varint,
    get_varlong,
)

from .produce_fetch import (
    ProduceRequest,
    ProduceTopicData,
    ProducePartitionData,
    ProduceTopicResult,
    ProducePartitionResult,
    decode_produce_request,
    encode_produce_response_v7,
    FetchRequest,
    FetchTopicRequest,
    FetchPartitionRequest,
    FetchTopicResult,
    FetchPartitionResult,
    decode_fetch_request,
    encode_fetch_response_v6,
    ListOffsetsRequest,
    ListOffsetsTopicRequest,
    ListOffsetsPartitionRequest,
    ListOffsetsTopicResult,
    ListOffsetsPartitionResult,
    decode_list_offsets_request,
    encode_list_offsets_response_v2,
    LIST_OFFSETS_EARLIEST,
    LIST_OFFSETS_LATEST,
)

from .consumer_group import (
    # API keys
    API_KEY_OFFSET_COMMIT,
    API_KEY_OFFSET_FETCH,
    API_KEY_FIND_COORDINATOR,
    COORDINATOR_KEY_TYPE_GROUP,
    COORDINATOR_KEY_TYPE_TRANSACTION,
    ERROR_COORDINATOR_NOT_AVAILABLE,
    OFFSET_FETCH_NO_OFFSET,
    # FindCoordinator
    FindCoordinatorRequest,
    decode_find_coordinator_request,
    encode_find_coordinator_response,
    # OffsetCommit
    OffsetCommitRequest,
    OffsetCommitTopic,
    OffsetCommitPartition,
    OffsetCommitTopicResult,
    OffsetCommitPartitionResult,
    decode_offset_commit_request,
    encode_offset_commit_response_v2,
    # OffsetFetch
    OffsetFetchRequest,
    OffsetFetchTopicRequest,
    OffsetFetchTopicResult,
    OffsetFetchPartitionResult,
    decode_offset_fetch_request,
    encode_offset_fetch_response,
    # Auto-rebalance API keys + error codes
    API_KEY_JOIN_GROUP,
    API_KEY_HEARTBEAT,
    API_KEY_LEAVE_GROUP,
    API_KEY_SYNC_GROUP,
    ERROR_ILLEGAL_GENERATION,
    ERROR_UNKNOWN_MEMBER_ID,
    ERROR_REBALANCE_IN_PROGRESS,
    # JoinGroup
    JoinGroupProtocol,
    JoinGroupRequest,
    JoinGroupResponseMember,
    decode_join_group_request,
    encode_join_group_response,
    # SyncGroup
    SyncGroupAssignment,
    SyncGroupRequest,
    decode_sync_group_request,
    encode_sync_group_response,
    # Heartbeat
    HeartbeatRequest,
    decode_heartbeat_request,
    encode_heartbeat_response,
    # LeaveGroup
    LeaveGroupRequest,
    decode_leave_group_request,
    encode_leave_group_response,
    # ConsumerProtocol blobs + the RangeAssignor wire format
    CONSUMER_PROTOCOL_VERSION,
    ConsumerSubscription,
    decode_consumer_subscription,
    AssignedTopicPartitions,
    encode_consumer_assignment,
    decode_consumer_assignment,
)

from .messages import (
    # API keys + error/version constants
    API_KEY_PRODUCE,
    API_KEY_FETCH,
    API_KEY_LIST_OFFSETS,
    API_KEY_METADATA,
    API_KEY_API_VERSIONS,
    ERROR_NONE,
    ERROR_UNSUPPORTED_VERSION,
    PLACEHOLDER_NODE_ID,
    NO_LEADER_NODE_ID,
    # request header
    RequestHeader,
    parse_request_header,
    # response header
    encode_response_header_v0,
    encode_response_header_v1,
    # ApiVersions
    ApiVersionRange,
    ApiVersionsRequest,
    supported_api_versions,
    decode_api_versions_request_body,
    encode_api_versions_response,
    # Metadata
    MetadataRequest,
    MetadataBroker,
    MetadataTopic,
    decode_metadata_request_body,
    decode_metadata_request_body_v9,
    encode_metadata_response_v1,
    encode_metadata_response_v4,
    encode_metadata_response_v5_to_v8,
    encode_metadata_response_v9,
    # framing
    frame_message,
    FramedMessage,
    read_framed_message,
)
