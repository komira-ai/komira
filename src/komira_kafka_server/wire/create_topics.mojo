# =============================================================================
# src/komira_kafka_server/wire/create_topics.mojo — Kafka CreateTopics (api_key 19)
# =============================================================================
#
# CreateTopics is the RPC a vanilla Kafka
# AdminClient / Kafka Streams / a CDC tool sends to create a topic AND set its
# per-topic configuration (`cleanup.policy`, `retention.ms`, `retention.bytes`,
# `delete.retention.ms`, ...) over the wire. Without it, topic config is only
# settable out-of-band (writing the `BrokerTopicConfig` JSON to the object store directly), so
# no stock client can configure a topic. This module is the WIRE EDGE: it
# decodes the request, and encodes the response. The server's handler maps the
# parsed config entries onto a `BrokerTopicConfig`
# and CAS-persists it (create-if-absent).
#
# Wire format (NON-flexible v0..v3 — kafka-python / the Java AdminClient
# negotiate down to our advertised max; v5+/flexible deferred):
#
#   Request:
#     v0:  topics ARRAY {
#            name                STRING
#            num_partitions      INT32
#            replication_factor  INT16
#            assignments ARRAY {            # we decode + SKIP (single-node)
#              partition_index   INT32
#              broker_ids ARRAY [ INT32 ]
#            }
#            config_entries ARRAY {
#              name              STRING
#              value             NULLABLE_STRING
#            }
#          }
#          timeout_ms            INT32
#     v1+: ... timeout_ms INT32, validate_only BOOLEAN   (after the topics array
#                                                          in v1, before in v0:
#                                                          see below — Kafka put
#                                                          timeout_ms FIRST from
#                                                          v0 onward; v1 ADDED a
#                                                          trailing validate_only)
#
#   NOTE on field order: the canonical Apache Kafka CreateTopics request is
#     v0:  [topics], timeout_ms
#     v1:  [topics], timeout_ms, validate_only
#     v2/v3: same as v1 (v3 only bumped the response throttle semantics).
#   We decode `validate_only` only at v1+, defaulting False at v0.
#
#   Response (per CreateTopicsResponse.json — ErrorMessage is "1+",
#             ThrottleTimeMs is "2+"):
#     v0:  topics ARRAY { name STRING, error_code INT16 }
#     v1:  topics ARRAY {
#            name STRING, error_code INT16, error_message NULLABLE_STRING }
#            (NO throttle_time_ms prefix at v1 — error_message added, throttle not)
#     v2/v3: throttle_time_ms INT32, topics ARRAY {
#            name STRING, error_code INT16, error_message NULLABLE_STRING }
#            (the config-echo + topic-config tagged fields are v5+ flexible —
#            out of scope; we emit the v2 body for v2..v3).
#
# Encapsulation: ZERO UnsafePointer in any signature — a pure wire edge like the
# rest of komira_kafka_server.wire (Span in / owned List[UInt8] out). All structs are stack
# values with POD / owned-List / owned-String fields — none stored in a
# byte-slab (no pointer field).
# =============================================================================

from komira_kafka_server.wire.wire import KafkaEncoder, KafkaDecoder
from komira_kafka_server.wire.messages import encode_response_header_v0


comptime API_KEY_CREATE_TOPICS: Int16 = 19

# Kafka canonical CreateTopics error codes.
comptime ERROR_CREATE_TOPICS_NONE: Int16 = 0
comptime ERROR_TOPIC_ALREADY_EXISTS: Int16 = 36
comptime ERROR_INVALID_CONFIG: Int16 = 40
comptime ERROR_INVALID_PARTITIONS: Int16 = 37


# =============================================================================
# §1 — Request structs.
# =============================================================================


struct CreatableTopicConfig(Movable, Copyable, Deinitable):
    """One `config_entries` entry: a `(name, value)` pair. `value` is a
    NULLABLE_STRING — a null value means "reset to the broker default" in Kafka;
    the handler treats a null value for a known key as "leave the default".

    POD-ish (two owned Strings/Optionals); a transient stack value (no pointer field)."""

    var name: String
    var value: Optional[String]

    def __init__(out self, var name: String, var value: Optional[String]):
        self.name = name^
        self.value = value^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.value.copy())


struct CreatableTopic(Movable, Copyable, Deinitable):
    """One topic to create: name + partition/replication request + its config
    entries. The `assignments` array (manual partition->broker placement) is
    decoded and DISCARDED — this is a single-node broker; placement is implicit.

    Owned String + owned List fields; a transient stack value (no pointer field)."""

    var name: String
    var num_partitions: Int32
    var replication_factor: Int16
    var configs: List[CreatableTopicConfig]

    def __init__(
        out self,
        var name: String,
        num_partitions: Int32,
        replication_factor: Int16,
        var configs: List[CreatableTopicConfig],
    ):
        self.name = name^
        self.num_partitions = num_partitions
        self.replication_factor = replication_factor
        self.configs = configs^

    def copy(self) -> Self:
        return Self(
            self.name.copy(),
            self.num_partitions,
            self.replication_factor,
            self.configs.copy(),
        )


struct CreateTopicsRequest(Movable, Deinitable):
    """A decoded CreateTopics request (v0..v3). `timeout_ms` is honored loosely
    (single-shot in-process persist — no long-poll wait). `validate_only` (v1+)
    is decoded; the handler may dry-run when set (no persist).

    Owned List of topics; a transient stack value (no pointer field)."""

    var topics: List[CreatableTopic]
    var timeout_ms: Int32
    var validate_only: Bool

    def __init__(
        out self,
        var topics: List[CreatableTopic],
        timeout_ms: Int32,
        validate_only: Bool,
    ):
        self.topics = topics^
        self.timeout_ms = timeout_ms
        self.validate_only = validate_only


# =============================================================================
# §2 — Request decode (v0..v3, non-flexible).
# =============================================================================


def decode_create_topics_request[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], api_version: Int16
) raises -> CreateTopicsRequest:
    """Decode a CreateTopics request body (v0..v3, NON-flexible), positioned
    just after the request header.

    The topics array comes first (all versions), then `timeout_ms` (INT32), then
    `validate_only` (BOOLEAN) at v1+. The per-topic `assignments` array is
    decoded + skipped (single-node placement)."""
    var n_topics = dec.get_array_len()  # INT32 array length (-1 == null)
    var topics = List[CreatableTopic]()
    var ti = 0
    while ti < n_topics:
        var name = dec.get_string()
        var num_partitions = dec.get_int32()
        var replication_factor = dec.get_int16()

        # assignments ARRAY { partition_index INT32, broker_ids ARRAY[INT32] } —
        # decode and DISCARD (manual placement is moot on a single-node broker).
        var n_assign = dec.get_array_len()
        var ai = 0
        while ai < n_assign:
            _ = dec.get_int32()  # partition_index
            var n_brokers = dec.get_array_len()
            var bi = 0
            while bi < n_brokers:
                _ = dec.get_int32()  # broker_id
                bi += 1
            ai += 1

        # config_entries ARRAY { name STRING, value NULLABLE_STRING }
        var n_cfg = dec.get_array_len()
        var configs = List[CreatableTopicConfig]()
        var ci = 0
        while ci < n_cfg:
            var cname = dec.get_string()
            var cvalue = dec.get_nullable_string()
            configs.append(CreatableTopicConfig(cname^, cvalue^))
            ci += 1

        topics.append(
            CreatableTopic(
                name^, num_partitions, replication_factor, configs^
            )
        )
        ti += 1

    var timeout_ms = dec.get_int32()
    var validate_only = False
    if api_version >= Int16(1):
        validate_only = dec.get_bool()

    return CreateTopicsRequest(topics^, timeout_ms, validate_only)


# =============================================================================
# §3 — Response structs + encode (v0..v3, non-flexible).
# =============================================================================


struct CreateTopicsTopicResult(Movable, Copyable, Deinitable):
    """One per-topic result in a CreateTopics response: name + error_code, and
    (v1+) an optional human-readable error_message.

    Owned String + Optional; a transient stack value (no pointer field)."""

    var name: String
    var error_code: Int16
    var error_message: Optional[String]

    def __init__(
        out self,
        var name: String,
        error_code: Int16,
        var error_message: Optional[String] = Optional[String](),
    ):
        self.name = name^
        self.error_code = error_code
        self.error_message = error_message^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.error_code, self.error_message.copy())


def encode_create_topics_response(
    correlation_id: Int32,
    results: List[CreateTopicsTopicResult],
    api_version: Int16,
) -> List[UInt8]:
    """Encode a CreateTopics v0..v3 response (response header v0 + body).

    Per CreateTopicsResponse.json the two added fields have DIFFERENT version
    floors: `error_message` is v1+ but `throttle_time_ms` is v2+. So:
      v0: no throttle, no error_message.
      v1: per-topic error_message, but NO throttle_time_ms prefix.
      v2/v3: throttle_time_ms prefix + per-topic error_message.
    (The config-echo / tagged fields are v5+ flexible and out of scope.)"""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    if api_version >= Int16(2):
        enc.put_int32(Int32(0))  # throttle_time_ms  (v2+ per CreateTopicsResponse.json)
    enc.put_int32(Int32(len(results)))  # topics ARRAY length
    for i in range(len(results)):
        ref r = results[i]
        enc.put_string(r.name)
        enc.put_int16(r.error_code)
        if api_version >= Int16(1):
            enc.put_nullable_string(r.error_message)
    return enc.take_bytes()
