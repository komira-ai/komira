# =============================================================================
# src/komira/komira_kafka/consumer_group.mojo — FindCoordinator / OffsetCommit /
#                                          OffsetFetch wire codecs
# =============================================================================
#
# The three consumer-group coordination APIs a simple (manual-assignment)
# consumer needs to persist its progress:
#   * FindCoordinator (api_key 10) — locate the group coordinator.
#   * OffsetCommit    (api_key 8)  — commit per-(topic,partition) offsets.
#   * OffsetFetch     (api_key 9)  — read back committed offsets.
#
# Versions (NON-flexible / non-compact — chosen so a kafka-python client
# negotiates a shape this codec fully encodes/decodes WITHOUT the v8+/v6+/v3+
# flexible (tagged-field) forms):
#   * FindCoordinator  v0   (request header v1; flexible at v3+)
#   * OffsetCommit     v2   (request header v1; flexible at v8+)
#   * OffsetFetch      v1..v3 (request header v1; flexible at v6+)
#
# Pure bytes, ZERO first-party deps — same wire-edge firewall as the rest of
# komira_kafka. The S3 group-offset persistence lives in
# komira_kafka_server.group_offsets (it imports the store); this module is the
# wire codec only.
#
# Encapsulation: ZERO UnsafePointer in any signature. Decode borrows
# `Span[UInt8, origin]` via KafkaDecoder; encode appends to an owned List. All
# structs are transient stack values (POD + owned String/List) — none stored in
# a byte-slab, so no pointer can go stale across destroy and recreate.
# =============================================================================


from komira_kafka.messages import encode_response_header_v0
from komira_kafka.wire import KafkaDecoder, KafkaEncoder


comptime API_KEY_OFFSET_COMMIT: Int16 = 8
comptime API_KEY_OFFSET_FETCH: Int16 = 9
comptime API_KEY_FIND_COORDINATOR: Int16 = 10
comptime API_KEY_JOIN_GROUP: Int16 = 11
comptime API_KEY_HEARTBEAT: Int16 = 12
comptime API_KEY_LEAVE_GROUP: Int16 = 13
comptime API_KEY_SYNC_GROUP: Int16 = 14

# Rebalance-related Kafka error codes (the auto-rebalance state machine).
#   REBALANCE_IN_PROGRESS (27): a rebalance is underway — the member must
#     rejoin (Heartbeat/SyncGroup returns this so the client re-issues
#     JoinGroup).
#   UNKNOWN_MEMBER_ID (25): the member_id is not a member of the group's
#     current generation (e.g. it was evicted / the group was reset).
#   ILLEGAL_GENERATION (22): the member's generation_id does not match the
#     group's current generation.
comptime ERROR_ILLEGAL_GENERATION: Int16 = 22
comptime ERROR_UNKNOWN_MEMBER_ID: Int16 = 25
comptime ERROR_REBALANCE_IN_PROGRESS: Int16 = 27

comptime ERROR_NONE_CG: Int16 = 0
# Returned for OffsetFetch on a partition with no committed offset — paired with
# the -1 sentinel offset so the client falls back to auto.offset.reset.
comptime ERROR_NONE_NO_OFFSET: Int16 = 0
# FindCoordinator key_type discriminants.
comptime COORDINATOR_KEY_TYPE_GROUP: Int8 = 0
comptime COORDINATOR_KEY_TYPE_TRANSACTION: Int8 = 1
# COORDINATOR_NOT_AVAILABLE (15) — returned for a key_type the broker does not
# coordinate.
comptime ERROR_COORDINATOR_NOT_AVAILABLE: Int16 = 15
# The "no committed offset" sentinel offset (standard Kafka): the client treats
# -1 as "never committed" and applies auto.offset.reset.
comptime OFFSET_FETCH_NO_OFFSET: Int64 = -1


# =============================================================================
# §1 — FindCoordinator (api_key 10) — v0 request + v0/v1 response.
# =============================================================================
#
#   request v0:  Key STRING
#   request v1:  Key STRING, KeyType INT8
#
#   response v0: ErrorCode INT16, NodeId INT32, Host STRING, Port INT32
#   response v1: ThrottleTimeMs INT32, ErrorCode INT16, ErrorMessage
#                NULLABLE_STRING, NodeId INT32, Host STRING, Port INT32


struct FindCoordinatorRequest(Movable, Deinitable):
    """A decoded FindCoordinator request (v0/v1).

    `key` is the group_id (for key_type GROUP) or transactional_id (for
    key_type TRANSACTION). `key_type` is 0 (GROUP) for v0 (the field is absent
    on the wire at v0; we default it to GROUP)."""

    var key: String
    var key_type: Int8

    def __init__(out self, var key: String, key_type: Int8):
        self.key = key^
        self.key_type = key_type


def decode_find_coordinator_request[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], api_version: Int16
) raises -> FindCoordinatorRequest:
    """Decode a FindCoordinator request body (v0/v1), positioned just after the
    request header. v0 has no KeyType field — default it to GROUP."""
    var key = dec.get_string()
    var key_type = Int8(COORDINATOR_KEY_TYPE_GROUP)
    if api_version >= 1:
        key_type = dec.get_int8()
    return FindCoordinatorRequest(key^, key_type)


def encode_find_coordinator_response(
    correlation_id: Int32,
    api_version: Int16,
    error_code: Int16,
    node_id: Int32,
    host: String,
    port: Int32,
) -> List[UInt8]:
    """Encode a FindCoordinator v0/v1 response (response header v0 + body).

    v0: error_code, node_id, host, port.
    v1: throttle_time_ms, error_code, error_message(null), node_id, host, port.
    """
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 1:
        enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_int16(error_code)
    if api_version >= 1:
        enc.put_nullable_string(Optional[String]())  # error_message = null
    enc.put_int32(node_id)
    enc.put_string(host)
    enc.put_int32(port)
    return enc.take_bytes()


# =============================================================================
# §2 — OffsetCommit (api_key 8) — v2 request + v2 response.
# =============================================================================
#
#   request v2:
#     GroupId STRING
#     GenerationId INT32
#     MemberId STRING
#     RetentionTimeMs INT64
#     Topics ARRAY of {
#         Name STRING
#         Partitions ARRAY of {
#             PartitionIndex INT32
#             CommittedOffset INT64
#             CommittedMetadata NULLABLE_STRING
#         }
#     }
#
#   response v2:
#     Topics ARRAY of {
#         Name STRING
#         Partitions ARRAY of { PartitionIndex INT32, ErrorCode INT16 }
#     }
#   (NB: throttle_time_ms is v3+, so v2 has NO throttle prefix.)


struct OffsetCommitPartition(Copyable, Movable, Deinitable):
    """One (partition, committed_offset, metadata) tuple in an OffsetCommit
    request."""

    var partition_index: Int32
    var committed_offset: Int64
    var metadata: Optional[String]

    def __init__(
        out self,
        partition_index: Int32,
        committed_offset: Int64,
        var metadata: Optional[String],
    ):
        self.partition_index = partition_index
        self.committed_offset = committed_offset
        self.metadata = metadata^

    def copy(self) -> Self:
        return Self(
            self.partition_index, self.committed_offset, self.metadata.copy()
        )


struct OffsetCommitTopic(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[OffsetCommitPartition]

    def __init__(
        out self, var name: String, var partitions: List[OffsetCommitPartition]
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


struct OffsetCommitRequest(Movable, Deinitable):
    var group_id: String
    var generation_id: Int32
    var member_id: String
    var retention_time_ms: Int64
    var topics: List[OffsetCommitTopic]

    def __init__(
        out self,
        var group_id: String,
        generation_id: Int32,
        var member_id: String,
        retention_time_ms: Int64,
        var topics: List[OffsetCommitTopic],
    ):
        self.group_id = group_id^
        self.generation_id = generation_id
        self.member_id = member_id^
        self.retention_time_ms = retention_time_ms
        self.topics = topics^


def decode_offset_commit_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> OffsetCommitRequest:
    """Decode an OffsetCommit v2 request body, positioned just after the request
    header. generation_id/member_id are parsed but NOT validated here
    (simple-consumer mode sends generation -1 / empty member)."""
    var group_id = dec.get_string()
    var generation_id = dec.get_int32()
    var member_id = dec.get_string()
    var retention = dec.get_int64()
    var n_topics = dec.get_array_len()
    var topics = List[OffsetCommitTopic]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[OffsetCommitPartition]()
        for _ in range(n_parts):
            var idx = dec.get_int32()
            var committed = dec.get_int64()
            var meta = dec.get_nullable_string()
            parts.append(OffsetCommitPartition(idx, committed, meta^))
        topics.append(OffsetCommitTopic(name^, parts^))
    return OffsetCommitRequest(
        group_id^, generation_id, member_id^, retention, topics^
    )


struct OffsetCommitPartitionResult(Copyable, Movable, Deinitable):
    var partition_index: Int32
    var error_code: Int16

    def __init__(out self, partition_index: Int32, error_code: Int16):
        self.partition_index = partition_index
        self.error_code = error_code


struct OffsetCommitTopicResult(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[OffsetCommitPartitionResult]

    def __init__(
        out self,
        var name: String,
        var partitions: List[OffsetCommitPartitionResult],
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


def encode_offset_commit_response_v2(
    correlation_id: Int32, topics: List[OffsetCommitTopicResult]
) -> List[UInt8]:
    """Encode an OffsetCommit v2 response (response header v0 + body). v2 has NO
    throttle_time_ms (that field is v3+)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.name)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.partition_index)
            enc.put_int16(p.error_code)
    return enc.take_bytes()


# =============================================================================
# §3 — OffsetFetch (api_key 9) — v1..v3 request + v1..v3 response.
# =============================================================================
#
#   request v1..v3:
#     GroupId STRING
#     Topics ARRAY of { Name STRING, PartitionIndexes ARRAY(INT32) }
#       (a NULL Topics array, v2+, means "all topics for the group")
#
#   response:
#     v3+ only: ThrottleTimeMs INT32
#     Topics ARRAY of {
#         Name STRING
#         Partitions ARRAY of {
#             PartitionIndex INT32
#             CommittedOffset INT64
#             Metadata NULLABLE_STRING
#             ErrorCode INT16
#         }
#     }
#     v2+ only: ErrorCode INT16   (top-level)


struct OffsetFetchTopicRequest(Copyable, Movable, Deinitable):
    var name: String
    var partition_indexes: List[Int32]

    def __init__(
        out self, var name: String, var partition_indexes: List[Int32]
    ):
        self.name = name^
        self.partition_indexes = partition_indexes^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partition_indexes.copy())


struct OffsetFetchRequest(Movable, Deinitable):
    """A decoded OffsetFetch request (v1..v3). `topics` is None for the v2+ null
    array ("all topics for this group")."""

    var group_id: String
    var topics: Optional[List[OffsetFetchTopicRequest]]

    def __init__(
        out self,
        var group_id: String,
        var topics: Optional[List[OffsetFetchTopicRequest]],
    ):
        self.group_id = group_id^
        self.topics = topics^


def decode_offset_fetch_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> OffsetFetchRequest:
    """Decode an OffsetFetch v1..v3 request body, positioned just after the
    request header. A -1 (null) Topics array (v2+) means "all topics"."""
    var group_id = dec.get_string()
    var n_topics = dec.get_array_len()
    if n_topics < 0:
        return OffsetFetchRequest(
            group_id^, Optional[List[OffsetFetchTopicRequest]]()
        )
    var topics = List[OffsetFetchTopicRequest]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var idxs = List[Int32]()
        for _ in range(n_parts):
            idxs.append(dec.get_int32())
        topics.append(OffsetFetchTopicRequest(name^, idxs^))
    return OffsetFetchRequest(group_id^, Optional(topics^))


struct OffsetFetchPartitionResult(Copyable, Movable, Deinitable):
    var partition_index: Int32
    var committed_offset: Int64
    var metadata: Optional[String]
    var error_code: Int16

    def __init__(
        out self,
        partition_index: Int32,
        committed_offset: Int64,
        var metadata: Optional[String],
        error_code: Int16,
    ):
        self.partition_index = partition_index
        self.committed_offset = committed_offset
        self.metadata = metadata^
        self.error_code = error_code

    def copy(self) -> Self:
        return Self(
            self.partition_index,
            self.committed_offset,
            self.metadata.copy(),
            self.error_code,
        )


struct OffsetFetchTopicResult(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[OffsetFetchPartitionResult]

    def __init__(
        out self,
        var name: String,
        var partitions: List[OffsetFetchPartitionResult],
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


def encode_offset_fetch_response(
    correlation_id: Int32,
    api_version: Int16,
    topics: List[OffsetFetchTopicResult],
    top_level_error_code: Int16,
) -> List[UInt8]:
    """Encode an OffsetFetch v1..v3 response (response header v0 + body).

    v3+ prepends throttle_time_ms; v2+ appends a top-level error_code.
    """
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 3:
        enc.put_int32(Int32(0))  # throttle_time_ms (v3+)
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.name)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.partition_index)
            enc.put_int64(p.committed_offset)
            enc.put_nullable_string(p.metadata)
            enc.put_int16(p.error_code)
    if api_version >= 2:
        enc.put_int16(top_level_error_code)  # top-level error_code (v2+)
    return enc.take_bytes()


# =============================================================================
# §4 — JoinGroup (api_key 11) — v2..v4 request + v2..v4 response (non-flexible;
#      JoinGroup is flexible at v6+).
# =============================================================================
#
#   request v2..v4:
#     GroupId STRING
#     SessionTimeoutMs INT32
#     RebalanceTimeoutMs INT32      (v1+)
#     MemberId STRING               (empty on first join)
#     ProtocolType STRING           ("consumer")
#     Protocols ARRAY of {
#         Name STRING               (assignor name, e.g. "range")
#         Metadata BYTES            (the ConsumerProtocolSubscription blob)
#     }
#
#   response v2..v4:
#     ThrottleTimeMs INT32          (v2+)
#     ErrorCode INT16
#     GenerationId INT32
#     ProtocolName STRING           (the chosen assignor)
#     Leader STRING                 (leader member_id)
#     MemberId STRING               (this member's id)
#     Members ARRAY of {
#         MemberId STRING
#         Metadata BYTES            (that member's subscription blob)
#     }
#   (leader gets the full Members list; followers get an empty Members list.)


struct JoinGroupProtocol(Copyable, Movable, Deinitable):
    """One (assignor name, subscription metadata) the joining member offers."""

    var name: String
    var metadata: List[UInt8]

    def __init__(out self, var name: String, var metadata: List[UInt8]):
        self.name = name^
        self.metadata = metadata^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.metadata.copy())


struct JoinGroupRequest(Movable, Deinitable):
    var group_id: String
    var session_timeout_ms: Int32
    var rebalance_timeout_ms: Int32
    var member_id: String
    var protocol_type: String
    var protocols: List[JoinGroupProtocol]

    def __init__(
        out self,
        var group_id: String,
        session_timeout_ms: Int32,
        rebalance_timeout_ms: Int32,
        var member_id: String,
        var protocol_type: String,
        var protocols: List[JoinGroupProtocol],
    ):
        self.group_id = group_id^
        self.session_timeout_ms = session_timeout_ms
        self.rebalance_timeout_ms = rebalance_timeout_ms
        self.member_id = member_id^
        self.protocol_type = protocol_type^
        self.protocols = protocols^


def decode_join_group_request[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], api_version: Int16
) raises -> JoinGroupRequest:
    """Decode a JoinGroup v2..v4 request body (non-flexible), positioned just
    after the request header."""
    var group_id = dec.get_string()
    var session_timeout = dec.get_int32()
    var rebalance_timeout = Int32(-1)
    if api_version >= 1:
        rebalance_timeout = dec.get_int32()
    var member_id = dec.get_string()
    var protocol_type = dec.get_string()
    var n = dec.get_array_len()
    var protocols = List[JoinGroupProtocol]()
    for _ in range(n):
        var name = dec.get_string()
        var metadata = dec.get_bytes()
        protocols.append(JoinGroupProtocol(name^, metadata^))
    return JoinGroupRequest(
        group_id^,
        session_timeout,
        rebalance_timeout,
        member_id^,
        protocol_type^,
        protocols^,
    )


struct JoinGroupResponseMember(Copyable, Movable, Deinitable):
    """One member returned in the JoinGroup response (leader only): the
    member_id + that member's subscription metadata blob (so the leader can
    compute the assignment)."""

    var member_id: String
    var metadata: List[UInt8]

    def __init__(out self, var member_id: String, var metadata: List[UInt8]):
        self.member_id = member_id^
        self.metadata = metadata^

    def copy(self) -> Self:
        return Self(self.member_id.copy(), self.metadata.copy())


def encode_join_group_response(
    correlation_id: Int32,
    api_version: Int16,
    error_code: Int16,
    generation_id: Int32,
    protocol_name: String,
    leader_id: String,
    member_id: String,
    members: List[JoinGroupResponseMember],
) -> List[UInt8]:
    """Encode a JoinGroup v2..v4 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 2:
        enc.put_int32(Int32(0))  # throttle_time_ms (v2+)
    enc.put_int16(error_code)
    enc.put_int32(generation_id)
    enc.put_string(protocol_name)
    enc.put_string(leader_id)
    enc.put_string(member_id)
    enc.put_array_len(len(members))
    for i in range(len(members)):
        ref m = members[i]
        enc.put_string(m.member_id)
        enc.put_bytes(Span(m.metadata))
    return enc.take_bytes()


# =============================================================================
# §5 — SyncGroup (api_key 14) — v1..v3 request + v1..v3 response (non-flexible;
#      SyncGroup is flexible at v4+).
# =============================================================================
#
#   request v1..v3:
#     GroupId STRING
#     GenerationId INT32
#     MemberId STRING
#     GroupInstanceId NULLABLE_STRING   (v3+)
#     Assignments ARRAY of {
#         MemberId STRING
#         Assignment BYTES              (the ConsumerProtocolAssignment blob)
#     }
#   (the leader sends the per-member assignments; followers send an empty
#    array.)
#
#   response v1..v3:
#     ThrottleTimeMs INT32              (v1+)
#     ErrorCode INT16
#     Assignment BYTES                  (THIS member's assignment blob)


struct SyncGroupAssignment(Copyable, Movable, Deinitable):
    """One (member_id, assignment bytes) the leader computed."""

    var member_id: String
    var assignment: List[UInt8]

    def __init__(out self, var member_id: String, var assignment: List[UInt8]):
        self.member_id = member_id^
        self.assignment = assignment^

    def copy(self) -> Self:
        return Self(self.member_id.copy(), self.assignment.copy())


struct SyncGroupRequest(Movable, Deinitable):
    var group_id: String
    var generation_id: Int32
    var member_id: String
    var assignments: List[SyncGroupAssignment]

    def __init__(
        out self,
        var group_id: String,
        generation_id: Int32,
        var member_id: String,
        var assignments: List[SyncGroupAssignment],
    ):
        self.group_id = group_id^
        self.generation_id = generation_id
        self.member_id = member_id^
        self.assignments = assignments^


def decode_sync_group_request[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], api_version: Int16
) raises -> SyncGroupRequest:
    """Decode a SyncGroup v1..v3 request body (non-flexible), positioned just
    after the request header. v3 adds a nullable GroupInstanceId (parsed +
    discarded)."""
    var group_id = dec.get_string()
    var generation_id = dec.get_int32()
    var member_id = dec.get_string()
    if api_version >= 3:
        _ = dec.get_nullable_string()  # group_instance_id (v3+), discarded
    var n = dec.get_array_len()
    var assignments = List[SyncGroupAssignment]()
    for _ in range(n):
        var mid = dec.get_string()
        var asg = dec.get_bytes()
        assignments.append(SyncGroupAssignment(mid^, asg^))
    return SyncGroupRequest(group_id^, generation_id, member_id^, assignments^)


def encode_sync_group_response(
    correlation_id: Int32,
    api_version: Int16,
    error_code: Int16,
    assignment: List[UInt8],
) -> List[UInt8]:
    """Encode a SyncGroup v1..v3 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 1:
        enc.put_int32(Int32(0))  # throttle_time_ms (v1+)
    enc.put_int16(error_code)
    enc.put_bytes(Span(assignment))
    return enc.take_bytes()


# =============================================================================
# §6 — Heartbeat (api_key 12) — v1..v2 request + v1..v2 response (non-flexible;
#      Heartbeat is flexible at v4+).
# =============================================================================
#
#   request v1..v2:
#     GroupId STRING
#     GenerationId INT32
#     MemberId STRING
#   response v1..v2:
#     ThrottleTimeMs INT32   (v1+)
#     ErrorCode INT16


struct HeartbeatRequest(Movable, Deinitable):
    var group_id: String
    var generation_id: Int32
    var member_id: String

    def __init__(
        out self,
        var group_id: String,
        generation_id: Int32,
        var member_id: String,
    ):
        self.group_id = group_id^
        self.generation_id = generation_id
        self.member_id = member_id^


def decode_heartbeat_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> HeartbeatRequest:
    """Decode a Heartbeat v1..v2 request body (non-flexible), positioned just
    after the request header."""
    var group_id = dec.get_string()
    var generation_id = dec.get_int32()
    var member_id = dec.get_string()
    return HeartbeatRequest(group_id^, generation_id, member_id^)


def encode_heartbeat_response(
    correlation_id: Int32, api_version: Int16, error_code: Int16
) -> List[UInt8]:
    """Encode a Heartbeat v1..v2 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 1:
        enc.put_int32(Int32(0))  # throttle_time_ms (v1+)
    enc.put_int16(error_code)
    return enc.take_bytes()


# =============================================================================
# §7 — LeaveGroup (api_key 13) — v1..v2 request + v1..v2 response (non-flexible;
#      LeaveGroup is flexible at v4+).
# =============================================================================
#
#   request v1..v2:
#     GroupId STRING
#     MemberId STRING        (TOP-LEVEL at v1/v2; the Members array is v3+)
#   response v1..v2:
#     ThrottleTimeMs INT32   (v1+)
#     ErrorCode INT16


struct LeaveGroupRequest(Movable, Deinitable):
    var group_id: String
    var member_id: String

    def __init__(out self, var group_id: String, var member_id: String):
        self.group_id = group_id^
        self.member_id = member_id^


def decode_leave_group_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> LeaveGroupRequest:
    """Decode a LeaveGroup v1..v2 request body (non-flexible), positioned just
    after the request header. v1/v2 carry a TOP-LEVEL member_id (the Members
    array form is v3+)."""
    var group_id = dec.get_string()
    var member_id = dec.get_string()
    return LeaveGroupRequest(group_id^, member_id^)


def encode_leave_group_response(
    correlation_id: Int32, api_version: Int16, error_code: Int16
) -> List[UInt8]:
    """Encode a LeaveGroup v1..v2 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= 1:
        enc.put_int32(Int32(0))  # throttle_time_ms (v1+)
    enc.put_int16(error_code)
    return enc.take_bytes()


# =============================================================================
# §8 — ConsumerProtocol blobs — the Subscription (inside JoinGroup protocol
#      Metadata) + the Assignment (inside SyncGroup Assignment bytes).
# =============================================================================
#
# These are NOT Kafka request/response messages — they are the opaque blobs the
# consumer client puts inside JoinGroup.Protocols[].Metadata and reads back from
# SyncGroup.Assignment. The standard `RangeAssignor` (and every stock client)
# uses the `ConsumerProtocol` format below (both schemas are NON-flexible — no
# tagged fields):
#
#   Subscription (v0):  Version INT16, Topics ARRAY(STRING), UserData
#                       NULLABLE_BYTES [, v1+ OwnedPartitions ... (ignored)]
#   Assignment   (v0):  Version INT16, AssignedPartitions ARRAY of {
#                           Topic STRING, Partitions ARRAY(INT32) },
#                       UserData NULLABLE_BYTES
#
# We PARSE the subscription's Topics (to know what each member subscribes to)
# and ENCODE the assignment (the partitions each member owns). The version is
# echoed; UserData is null/empty.

comptime CONSUMER_PROTOCOL_VERSION: Int16 = 0


struct ConsumerSubscription(Movable, Deinitable):
    """The decoded ConsumerProtocolSubscription: the list of topics the member
    subscribed to (the only field the RangeAssignor needs)."""

    var version: Int16
    var topics: List[String]

    def __init__(out self, version: Int16, var topics: List[String]):
        self.version = version
        self.topics = topics^

    def copy(self) -> Self:
        return Self(self.version, self.topics.copy())


def decode_consumer_subscription(
    metadata: List[UInt8]
) raises -> ConsumerSubscription:
    """Parse a ConsumerProtocolSubscription blob: Version INT16 + Topics
    ARRAY(STRING) (later fields — UserData, OwnedPartitions — are ignored)."""
    var dec = KafkaDecoder(Span(metadata))
    var version = dec.get_int16()
    var n = dec.get_array_len()
    var topics = List[String]()
    for _ in range(n):
        topics.append(dec.get_string())
    return ConsumerSubscription(version, topics^)


struct AssignedTopicPartitions(Copyable, Movable, Deinitable):
    """One (topic, [partition...]) the assignor gave a member."""

    var topic: String
    var partitions: List[Int32]

    def __init__(out self, var topic: String, var partitions: List[Int32]):
        self.topic = topic^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.topic.copy(), self.partitions.copy())


def encode_consumer_assignment(
    assigned: List[AssignedTopicPartitions]
) -> List[UInt8]:
    """Encode a ConsumerProtocolAssignment blob: Version INT16 +
    AssignedPartitions ARRAY of {Topic STRING, Partitions ARRAY(INT32)} +
    UserData NULLABLE_BYTES(null). This is what each member receives as its
    SyncGroup Assignment."""
    var enc = KafkaEncoder()
    enc.put_int16(CONSUMER_PROTOCOL_VERSION)
    enc.put_array_len(len(assigned))
    for i in range(len(assigned)):
        ref a = assigned[i]
        enc.put_string(a.topic)
        enc.put_array_len(len(a.partitions))
        for pi in range(len(a.partitions)):
            enc.put_int32(a.partitions[pi])
    enc.put_int32(Int32(-1))  # UserData = null (NULLABLE_BYTES)
    return enc.take_bytes()


def decode_consumer_assignment(
    blob: List[UInt8]
) raises -> List[AssignedTopicPartitions]:
    """Parse a ConsumerProtocolAssignment blob back to its assigned
    (topic, [partition...]) list. Used by the unit test to confirm the
    encode round-trips; the live client decodes this internally."""
    var dec = KafkaDecoder(Span(blob))
    _ = dec.get_int16()  # version
    var n = dec.get_array_len()
    var out = List[AssignedTopicPartitions]()
    for _ in range(n):
        var topic = dec.get_string()
        var np = dec.get_array_len()
        var parts = List[Int32]()
        for _ in range(np):
            parts.append(dec.get_int32())
        out.append(AssignedTopicPartitions(topic^, parts^))
    return out^
