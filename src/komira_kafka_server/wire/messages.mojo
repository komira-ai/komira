# =============================================================================
# src/komira_kafka_server/wire/messages.mojo — Kafka request header + ApiVersions +
#                                    Metadata message codec
# =============================================================================
#
# The handshake APIs on top of the wire primitives (wire.mojo).
# Encode/decode only; the TCP server is not part of this subpackage.
#
# Framing: every Kafka request and response on a connection is length-
# prefixed: INT32 message_size + payload (the size does NOT count itself).
#
# Request header (the client's framing of every request):
#   v1 (NON-flexible): api_key INT16, api_version INT16, correlation_id INT32,
#                      client_id NULLABLE_STRING
#   v2 (flexible):     same four fields + a trailing TAG_BUFFER. Note client_id
#                      stays a regular NULLABLE_STRING even in v2 (KIP-482
#                      kept the header's client_id non-compact for
#                      backward-compat).
#
# Response header:
#   v0: correlation_id INT32
#   v1: correlation_id INT32 + TAG_BUFFER  (flexible)
#
# THE ApiVersions SPECIAL CASE (KIP-482): the ApiVersions RESPONSE always uses
# response header v0 (bare INT32 correlation_id, NO tag buffer) even when the
# response BODY is flexible (v3+). The header length must not change so old
# clients can always parse the correlation_id + error_code to learn the
# broker's supported versions. We bake this in: encode_response_header_v0 for
# ApiVersions, flexible body controlled separately.
#
# Version set (non-flexible base forms are unambiguous; the flexible bodies
# are encoded where the spec is well-specified):
#   * ApiVersions (api_key 18): advertise v0..v3. Response encodable in BOTH
#     the v0 (non-flexible) and v3 (flexible body) shapes.
#   * Metadata (api_key 3): v1, v2..v4, v5..v8 (non-flexible) and v9
#     (flexible/compact) responses.
#   * Produce / Fetch / ListOffsets: advertised minimally in the base version
#     set; their message codecs are in produce_fetch.mojo.
#
# Encapsulation: ZERO UnsafePointer in any public signature. Inputs are
# `Span[UInt8, _]` (decode) / owned `List[UInt8]` (encode). All structs are
# stack values with POD / owned fields — none stored in a byte-slab (no
# pointer field).
# =============================================================================

from komira_kafka_server.wire.wire import KafkaEncoder, KafkaDecoder


# =============================================================================
# §0 — API keys + supported version constants.
# =============================================================================

comptime API_KEY_PRODUCE: Int16 = 0
comptime API_KEY_FETCH: Int16 = 1
comptime API_KEY_LIST_OFFSETS: Int16 = 2
comptime API_KEY_METADATA: Int16 = 3
comptime API_KEY_API_VERSIONS: Int16 = 18

comptime ERROR_NONE: Int16 = 0
comptime ERROR_UNSUPPORTED_VERSION: Int16 = 35

# The single-node placeholder broker id (the default leader when no per-partition
# map is supplied — the single-node path).
comptime PLACEHOLDER_NODE_ID: Int32 = 0

# Multi-node: the "no leader" sentinel for an UNASSIGNED partition (no
# live node owns it). A client that sees leader == -1 treats the partition as
# having no current leader and refreshes Metadata + backs off — the
# stale-Metadata self-correction. -1 is the canonical Kafka
# no-leader id (LeaderNotAvailable).
comptime NO_LEADER_NODE_ID: Int32 = -1


# =============================================================================
# §1 — Request header (parse) — the client's framing of every request.
# =============================================================================


struct RequestHeader(Movable, Deinitable):
    """A parsed Kafka request header.

    Fields are POD + one owned Optional[String] (client_id). Not stored in any
    byte-slab — a transient stack value handed to the per-API dispatcher.
    """

    var api_key: Int16
    var api_version: Int16
    var correlation_id: Int32
    var client_id: Optional[String]

    def __init__(
        out self,
        api_key: Int16,
        api_version: Int16,
        correlation_id: Int32,
        var client_id: Optional[String],
    ):
        self.api_key = api_key
        self.api_version = api_version
        self.correlation_id = correlation_id
        self.client_id = client_id^


def parse_request_header[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], header_is_flexible: Bool
) raises -> RequestHeader:
    """Parse a request header off `dec`. The header version (v1 vs v2-flexible)
    is determined by the API + api_version of the request; the caller passes
    `header_is_flexible` because the header version is API-version-dependent
    (e.g. ApiVersions v3+ and Metadata v9+ use the flexible header v2).

    Wire order (both versions): api_key, api_version, correlation_id,
    client_id (NULLABLE_STRING — regular, not compact, in BOTH versions),
    then a TAG_BUFFER iff flexible.
    """
    var api_key = dec.get_int16()
    var api_version = dec.get_int16()
    var correlation_id = dec.get_int32()
    var client_id = dec.get_nullable_string()
    if header_is_flexible:
        dec.skip_tag_buffer()
    return RequestHeader(
        api_key, api_version, correlation_id, client_id^
    )


# =============================================================================
# §2 — Response header (encode).
# =============================================================================


def encode_response_header_v0(mut enc: KafkaEncoder, correlation_id: Int32):
    """Response header v0: bare INT32 correlation_id. Used by NON-flexible
    responses AND — the special case — by the ApiVersions response at EVERY
    version (its header never gets a tag buffer)."""
    enc.put_int32(correlation_id)


def encode_response_header_v1(mut enc: KafkaEncoder, correlation_id: Int32):
    """Response header v1 (flexible): INT32 correlation_id + empty TAG_BUFFER.
    Used by flexible responses OTHER than ApiVersions (e.g. Metadata v9+)."""
    enc.put_int32(correlation_id)
    enc.put_empty_tag_buffer()


# =============================================================================
# §3 — ApiVersions API (api_key 18) — the client's FIRST request.
# =============================================================================


struct ApiVersionRange(Copyable, Movable, Deinitable):
    """One advertised API: its key + the [min, max] version range we support."""

    var api_key: Int16
    var min_version: Int16
    var max_version: Int16

    def __init__(
        out self, api_key: Int16, min_version: Int16, max_version: Int16
    ):
        self.api_key = api_key
        self.min_version = min_version
        self.max_version = max_version


def supported_api_versions() -> List[ApiVersionRange]:
    """The base version set advertised in an ApiVersions response.

    ApiVersions + Metadata are CODEC-backed here. Produce / Fetch /
    ListOffsets are advertised at a conservative v0..v0 in this base set so a
    client doesn't assume a newer wire shape than the caller serves.
    """
    var out = List[ApiVersionRange]()
    out.append(ApiVersionRange(API_KEY_API_VERSIONS, 0, 3))
    out.append(ApiVersionRange(API_KEY_METADATA, 0, 9))
    # The data path — advertise minimally in the base set.
    out.append(ApiVersionRange(API_KEY_PRODUCE, 0, 0))
    out.append(ApiVersionRange(API_KEY_FETCH, 0, 0))
    out.append(ApiVersionRange(API_KEY_LIST_OFFSETS, 0, 0))
    return out^


struct ApiVersionsRequest(Movable, Deinitable):
    """The decoded ApiVersions request body.

    v0/v1: empty body. v3+: client_software_name + client_software_version
    (COMPACT_STRING) + TAG_BUFFER (KIP-511). v2 is empty body but the v3 header
    is flexible — we key the body shape on api_version.
    """

    var client_software_name: Optional[String]
    var client_software_version: Optional[String]

    def __init__(
        out self,
        var client_software_name: Optional[String],
        var client_software_version: Optional[String],
    ):
        self.client_software_name = client_software_name^
        self.client_software_version = client_software_version^


def decode_api_versions_request_body[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin], api_version: Int16) raises -> ApiVersionsRequest:
    """Decode the ApiVersions request body (after the header is parsed).

    v0..v2: empty body. v3+: two COMPACT_STRINGs (client software name +
    version) + a body TAG_BUFFER (KIP-511)."""
    if api_version >= 3:
        var name = dec.get_compact_string()
        var version = dec.get_compact_string()
        dec.skip_tag_buffer()
        return ApiVersionsRequest(
            Optional(name^), Optional(version^)
        )
    return ApiVersionsRequest(Optional[String](), Optional[String]())


def encode_api_versions_response(
    correlation_id: Int32,
    api_version: Int16,
    error_code: Int16,
    apis: List[ApiVersionRange],
    throttle_time_ms: Int32,
) -> List[UInt8]:
    """Encode a full ApiVersions response message (NO length prefix — wrap
    with `frame_message` for the wire).

    Header: ALWAYS response header v0 (bare correlation_id) — the ApiVersions
    special case (the header never carries a tag buffer, at any version).

    Body shape keyed on api_version:
      v0:    error_code, ARRAY of {api_key, min, max}
      v1/v2: error_code, ARRAY of {api_key, min, max}, throttle_time_ms
      v3+:   error_code, COMPACT_ARRAY of {api_key, min, max, TAG_BUFFER},
             throttle_time_ms, TAG_BUFFER  (flexible body)
    """
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int16(error_code)

    var flexible = api_version >= 3
    if flexible:
        enc.put_compact_array_len(len(apis))
        for i in range(len(apis)):
            enc.put_int16(apis[i].api_key)
            enc.put_int16(apis[i].min_version)
            enc.put_int16(apis[i].max_version)
            enc.put_empty_tag_buffer()
        enc.put_int32(throttle_time_ms)
        enc.put_empty_tag_buffer()
    else:
        enc.put_array_len(len(apis))
        for i in range(len(apis)):
            enc.put_int16(apis[i].api_key)
            enc.put_int16(apis[i].min_version)
            enc.put_int16(apis[i].max_version)
        if api_version >= 1:
            enc.put_int32(throttle_time_ms)
    return enc.take_bytes()


# =============================================================================
# §4 — Metadata API (api_key 3) — topic / partition discovery.
# =============================================================================


struct MetadataRequest(Movable, Deinitable):
    """The decoded Metadata request: a list of topic names, or null == ALL
    topics. (v1 non-flexible form: ARRAY of STRING topic names.)"""

    var topics: Optional[List[String]]

    def __init__(out self, var topics: Optional[List[String]]):
        self.topics = topics^


def decode_metadata_request_body[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> MetadataRequest:
    """Decode a Metadata v1 request body: an ARRAY of topic-name STRINGs.
    A -1 (null) array means "all topics"."""
    var n = dec.get_array_len()
    if n < 0:
        return MetadataRequest(Optional[List[String]]())
    var names = List[String]()
    for _ in range(n):
        names.append(dec.get_string())
    return MetadataRequest(Optional(names^))


struct MetadataBroker(Copyable, Movable, Deinitable):
    """One broker node in the Metadata response."""

    var node_id: Int32
    var host: String
    var port: Int32

    def __init__(out self, node_id: Int32, var host: String, port: Int32):
        self.node_id = node_id
        self.host = host^
        self.port = port

    def copy(self) -> Self:
        return Self(self.node_id, self.host.copy(), self.port)


struct MetadataTopic(Copyable, Movable, Deinitable):
    """One topic in the Metadata response: its name + partition count. The
    partition count is sourced from the persisted BrokerTopicConfig
    (`num_partitions`) by the caller — the codec itself stays decoupled from
    the broker (it's a wire edge).

    Multi-node: `partition_leaders` is the PER-PARTITION leader node_id map.
    When empty (the single-node path) every partition reports the encoder's
    `leader_node_id` fallback. When non-empty (multi-node assignment), partition `pi`
    reports `partition_leaders[pi]` as its leader (and replica/isr = [that
    leader]). A pid whose owner is UNASSIGNED (no live node) is encoded as
    leader `-1` (= NO_LEADER), which a client reads as
    NOT_LEADER_OR_FOLLOWER-equivalent and refreshes Metadata on (stale-Metadata
    self-correction). The list length, when non-empty, MUST equal
    `num_partitions`.
    """

    var name: String
    var num_partitions: Int
    var is_internal: Bool
    var partition_leaders: List[Int32]

    def __init__(
        out self, var name: String, num_partitions: Int, is_internal: Bool
    ):
        """Single-node ctor: no per-partition leader map (every
        partition uses the encoder's `leader_node_id` fallback)."""
        self.name = name^
        self.num_partitions = num_partitions
        self.is_internal = is_internal
        self.partition_leaders = List[Int32]()

    def __init__(
        out self,
        var name: String,
        num_partitions: Int,
        is_internal: Bool,
        var partition_leaders: List[Int32],
    ):
        """Multi-node ctor with an explicit per-partition leader map (length must
        equal `num_partitions`)."""
        self.name = name^
        self.num_partitions = num_partitions
        self.is_internal = is_internal
        self.partition_leaders = partition_leaders^

    def copy(self) -> Self:
        return Self(
            self.name.copy(),
            self.num_partitions,
            self.is_internal,
            self.partition_leaders.copy(),
        )

    @always_inline
    def leader_for(self, pi: Int, fallback: Int32) -> Int32:
        """The leader node_id for partition index `pi`: the per-partition map
        entry when present (multi-node), else the `fallback` (single-node).
        Out-of-range / empty -> fallback (defensive)."""
        if pi >= 0 and pi < len(self.partition_leaders):
            return self.partition_leaders[pi]
        return fallback


def encode_metadata_response_v1(
    correlation_id: Int32,
    brokers: List[MetadataBroker],
    controller_id: Int32,
    topics: List[MetadataTopic],
    leader_node_id: Int32,
) -> List[UInt8]:
    """Encode a Metadata v1 response message (NON-flexible; NO length prefix —
    wrap with `frame_message`).

    Header: response header v0 (bare correlation_id).

    Body (v1):
      brokers ARRAY of {node_id INT32, host STRING, port INT32,
                        rack NULLABLE_STRING}
      controller_id INT32
      topics ARRAY of {error_code INT16, name STRING, is_internal BOOLEAN,
        partitions ARRAY of {error_code INT16, partition_index INT32,
          leader_id INT32, replica_nodes ARRAY(INT32),
          isr_nodes ARRAY(INT32)}}

    Every partition reports `leader_node_id` as leader + the single-node
    replica/isr set [leader_node_id] (single-node placeholder).
    """
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)

    # brokers
    enc.put_array_len(len(brokers))
    for i in range(len(brokers)):
        enc.put_int32(brokers[i].node_id)
        enc.put_string(brokers[i].host)
        enc.put_int32(brokers[i].port)
        enc.put_nullable_string(Optional[String]())  # rack = null

    # controller_id
    enc.put_int32(controller_id)

    # topics
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        enc.put_int16(ERROR_NONE)
        enc.put_string(topics[ti].name)
        enc.put_bool(topics[ti].is_internal)
        # partitions — one entry per partition index. Per-partition leader
        # from the topic's leader map (fallback = `leader_node_id`).
        var np = topics[ti].num_partitions
        enc.put_array_len(np)
        for pi in range(np):
            var pleader = topics[ti].leader_for(pi, leader_node_id)
            enc.put_int16(ERROR_NONE)
            enc.put_int32(Int32(pi))  # partition_index
            enc.put_int32(pleader)  # leader_id
            # replica_nodes = [leader]
            enc.put_array_len(1)
            enc.put_int32(pleader)
            # isr_nodes = [leader]
            enc.put_array_len(1)
            enc.put_int32(pleader)
    return enc.take_bytes()


def encode_metadata_response_v4(
    correlation_id: Int32,
    brokers: List[MetadataBroker],
    controller_id: Int32,
    topics: List[MetadataTopic],
    leader_node_id: Int32,
) -> List[UInt8]:
    """Encode a Metadata v2/v3/v4 response message (NON-flexible; NO length
    prefix — wrap with `frame_message`).

    The same wire shape covers v2..v4 (v4 only changed the REQUEST, adding
    `allow_auto_topic_creation`). Advertising Metadata max_version >= 4 makes
    kafka-python infer the broker as >= 0.11.0 and use the v2 RecordBatch
    (magic=2) message format on Produce/Fetch — which is the format this
    broker's data codec speaks. That inference (kafka-python's conn.py
    `_infer_broker_version_from_api_versions`: `((0,11), MetadataRequest[4])`)
    is why the data path advertises Metadata up to v4.

    Body (v2..v4):
      throttle_time_ms INT32        (v3+)
      brokers ARRAY of {node_id INT32, host STRING, port INT32,
                        rack NULLABLE_STRING}
      cluster_id NULLABLE_STRING    (v2+)
      controller_id INT32
      topics ARRAY of {error_code INT16, name STRING, is_internal BOOLEAN,
        partitions ARRAY of {error_code INT16, partition_index INT32,
          leader_id INT32, replica_nodes ARRAY(INT32),
          isr_nodes ARRAY(INT32)}}
    """
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)

    enc.put_int32(Int32(0))  # throttle_time_ms (v3+)

    # brokers
    enc.put_array_len(len(brokers))
    for i in range(len(brokers)):
        enc.put_int32(brokers[i].node_id)
        enc.put_string(brokers[i].host)
        enc.put_int32(brokers[i].port)
        enc.put_nullable_string(Optional[String]())  # rack = null

    enc.put_nullable_string(Optional[String]())  # cluster_id = null (v2+)
    enc.put_int32(controller_id)

    # topics
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        enc.put_int16(ERROR_NONE)
        enc.put_string(topics[ti].name)
        enc.put_bool(topics[ti].is_internal)
        var np = topics[ti].num_partitions
        enc.put_array_len(np)
        for pi in range(np):
            var pleader = topics[ti].leader_for(pi, leader_node_id)
            enc.put_int16(ERROR_NONE)
            enc.put_int32(Int32(pi))  # partition_index
            enc.put_int32(pleader)  # leader_id (per-partition)
            enc.put_array_len(1)  # replica_nodes = [leader]
            enc.put_int32(pleader)
            enc.put_array_len(1)  # isr_nodes = [leader]
            enc.put_int32(pleader)
    return enc.take_bytes()


def encode_metadata_response_v5_to_v8(
    correlation_id: Int32,
    api_version: Int16,
    brokers: List[MetadataBroker],
    controller_id: Int32,
    topics: List[MetadataTopic],
    leader_node_id: Int32,
) -> List[UInt8]:
    """Encode a Metadata v5..v8 response message (NON-flexible; NO length
    prefix — wrap with `frame_message`).

    These are the non-flexible versions between the v4 shape and the v9 flexible
    shape. Relative to v4 they add (field order verified against apache/kafka
    3.7.0 MetadataResponse.json):
      * partition.leader_epoch INT32           — v7+
      * partition.offline_replicas ARRAY(INT32) — v5+
      * topic.topic_authorized_operations INT32 — v8
      * top-level cluster_authorized_operations INT32 — v8 (range 8-10)

    Header: response header v0 (non-flexible).

    Single-node placement: leader = `leader_node_id`; replicas/isr =
    [leader_node_id]; offline_replicas empty; leader_epoch 0;
    authorized_operations INT32_MIN ("not requested")."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)

    enc.put_int32(Int32(0))  # throttle_time_ms

    # brokers
    enc.put_array_len(len(brokers))
    for i in range(len(brokers)):
        enc.put_int32(brokers[i].node_id)
        enc.put_string(brokers[i].host)
        enc.put_int32(brokers[i].port)
        enc.put_nullable_string(Optional[String]())  # rack = null

    enc.put_nullable_string(Optional[String]())  # cluster_id = null (v2+)
    enc.put_int32(controller_id)

    var has_leader_epoch = api_version >= Int16(7)
    var has_auth_ops = api_version >= Int16(8)

    # topics
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        enc.put_int16(ERROR_NONE)
        enc.put_string(topics[ti].name)
        enc.put_bool(topics[ti].is_internal)
        var np = topics[ti].num_partitions
        enc.put_array_len(np)
        for pi in range(np):
            var pleader = topics[ti].leader_for(pi, leader_node_id)
            enc.put_int16(ERROR_NONE)
            enc.put_int32(Int32(pi))  # partition_index
            enc.put_int32(pleader)  # leader_id (per-partition)
            if has_leader_epoch:
                enc.put_int32(Int32(0))  # leader_epoch (v7+)
            enc.put_array_len(1)  # replica_nodes = [leader]
            enc.put_int32(pleader)
            enc.put_array_len(1)  # isr_nodes = [leader]
            enc.put_int32(pleader)
            enc.put_array_len(0)  # offline_replicas = [] (v5+)
        if has_auth_ops:
            enc.put_int32(Int32(-2147483648))  # topic_authorized_operations (v8)
    if has_auth_ops:
        enc.put_int32(Int32(-2147483648))  # cluster_authorized_operations (v8)
    return enc.take_bytes()


def encode_metadata_response_v9(
    correlation_id: Int32,
    brokers: List[MetadataBroker],
    controller_id: Int32,
    topics: List[MetadataTopic],
    leader_node_id: Int32,
) -> List[UInt8]:
    """Encode a Metadata v9 response message (FLEXIBLE / compact; NO length
    prefix — wrap with `frame_message`).

    v9 is the first FLEXIBLE Metadata version (KIP-482): the RESPONSE header is
    the flexible header v1 (correlation_id + TAG_BUFFER), strings are
    COMPACT_STRING, arrays are COMPACT_ARRAY, and every struct ends with a
    TAG_BUFFER. (Distinct from the ApiVersions special case, whose response
    header stays v0 even when flexible.)

    Body (v9), field order verified against apache/kafka 3.7.0
    MetadataResponse.json:
      throttle_time_ms INT32
      brokers COMPACT_ARRAY of {node_id INT32, host COMPACT_STRING, port INT32,
                                rack COMPACT_NULLABLE_STRING, TAG_BUFFER}
      cluster_id COMPACT_NULLABLE_STRING
      controller_id INT32
      topics COMPACT_ARRAY of {error_code INT16, name COMPACT_STRING,
        is_internal BOOLEAN,
        partitions COMPACT_ARRAY of {error_code INT16, partition_index INT32,
          leader_id INT32, leader_epoch INT32 (v7+),
          replica_nodes COMPACT_ARRAY(INT32), isr_nodes COMPACT_ARRAY(INT32),
          offline_replicas COMPACT_ARRAY(INT32) (v5+), TAG_BUFFER},
        topic_authorized_operations INT32 (v8+), TAG_BUFFER}
      cluster_authorized_operations INT32 (v8-10)
      TAG_BUFFER

    Single-node placement: every partition reports `leader_node_id` as leader +
    the single-node replica/isr set [leader_node_id]; offline_replicas empty;
    leader_epoch 0; authorized_operations -2147483648 (INT32_MIN ==
    "not requested", the value a real broker returns when the client did not
    set include*AuthorizedOperations)."""
    var enc = KafkaEncoder()
    encode_response_header_v1(enc, correlation_id)  # flexible header

    enc.put_int32(Int32(0))  # throttle_time_ms

    # brokers (COMPACT_ARRAY)
    enc.put_compact_array_len(len(brokers))
    for i in range(len(brokers)):
        enc.put_int32(brokers[i].node_id)
        enc.put_compact_string(brokers[i].host)
        enc.put_int32(brokers[i].port)
        enc.put_compact_nullable_string(Optional[String]())  # rack = null
        enc.put_empty_tag_buffer()

    enc.put_compact_nullable_string(Optional[String]())  # cluster_id = null
    enc.put_int32(controller_id)

    # topics (COMPACT_ARRAY)
    enc.put_compact_array_len(len(topics))
    for ti in range(len(topics)):
        enc.put_int16(ERROR_NONE)
        enc.put_compact_string(topics[ti].name)
        enc.put_bool(topics[ti].is_internal)
        var np = topics[ti].num_partitions
        enc.put_compact_array_len(np)
        for pi in range(np):
            var pleader = topics[ti].leader_for(pi, leader_node_id)
            enc.put_int16(ERROR_NONE)
            enc.put_int32(Int32(pi))  # partition_index
            enc.put_int32(pleader)  # leader_id (per-partition)
            enc.put_int32(Int32(0))  # leader_epoch (v7+)
            enc.put_compact_array_len(1)  # replica_nodes = [leader]
            enc.put_int32(pleader)
            enc.put_compact_array_len(1)  # isr_nodes = [leader]
            enc.put_int32(pleader)
            enc.put_compact_array_len(0)  # offline_replicas = [] (v5+)
            enc.put_empty_tag_buffer()  # partition tag buffer
        # topic_authorized_operations (v8+): INT32_MIN = "not requested".
        enc.put_int32(Int32(-2147483648))
        enc.put_empty_tag_buffer()  # topic tag buffer

    # cluster_authorized_operations (v8-10): INT32_MIN = "not requested".
    enc.put_int32(Int32(-2147483648))
    enc.put_empty_tag_buffer()  # top-level tag buffer
    return enc.take_bytes()


def decode_metadata_request_body_v9[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> MetadataRequest:
    """Decode a Metadata v9 (FLEXIBLE) request body.

    v9 request body (apache/kafka MetadataRequest.json):
      topics COMPACT_ARRAY of {name COMPACT_STRING, TAG_BUFFER}
        (a null array == all topics)
      allow_auto_topic_creation BOOLEAN
      include_cluster_authorized_operations BOOLEAN
      include_topic_authorized_operations BOOLEAN
      TAG_BUFFER

    The topic_id UUID arrives at v10, and the name becomes nullable only at
    v10 (Name "nullableVersions": "10+"), so a null name at v9 is refused.
    We read the topic names (a null array => all topics) and skip the
    trailing booleans + tag buffers — the response is the single-node
    placement regardless of the auth-operations flags.

    Raises: a truncated body, or a null topic name."""
    var n = dec.get_compact_array_len()
    if n < 0:
        # Null array == all topics. Skip the trailing fields + tag buffer.
        _ = dec.get_bool()  # allow_auto_topic_creation
        _ = dec.get_bool()  # include_cluster_authorized_operations
        _ = dec.get_bool()  # include_topic_authorized_operations
        dec.skip_tag_buffer()
        return MetadataRequest(Optional[List[String]]())
    var names = List[String]()
    for _ in range(n):
        # v9 topic entry: name COMPACT_STRING (null refused) + TAG_BUFFER.
        names.append(dec.get_compact_string())
        dec.skip_tag_buffer()  # per-topic tag buffer
    _ = dec.get_bool()  # allow_auto_topic_creation
    _ = dec.get_bool()  # include_cluster_authorized_operations
    _ = dec.get_bool()  # include_topic_authorized_operations
    dec.skip_tag_buffer()  # top-level tag buffer
    return MetadataRequest(Optional(names^))


# =============================================================================
# §5 — Framing — the INT32 length-prefix that wraps every message on the wire.
# =============================================================================


def frame_message(payload: Span[UInt8, _]) -> List[UInt8]:
    """Wrap a response payload with its Kafka length prefix: INT32
    message_size (the size of the payload, NOT counting the 4 size bytes) +
    the payload bytes. This is the on-wire form a server writes to the
    socket."""
    var enc = KafkaEncoder()
    enc.put_int32(Int32(len(payload)))
    var header = enc.take_bytes()
    var out = List[UInt8]()
    for i in range(len(header)):
        out.append(header[i])
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


struct FramedMessage(Movable, Deinitable):
    """A complete framed message peeled off the wire: the declared size + the
    payload bytes (the size prefix is stripped)."""

    var size: Int
    var payload: List[UInt8]

    def __init__(out self, size: Int, var payload: List[UInt8]):
        self.size = size
        self.payload = payload^


def read_framed_message[
    origin: Origin[mut=False]
](data: Span[UInt8, origin]) raises -> FramedMessage:
    """Read one length-prefixed message off `data`: INT32 size + that many
    payload bytes. Raises if the buffer is short. (The streaming/partial-frame
    accumulator belongs to the TCP server; this decodes one complete
    in-memory frame for the codec unit tests.)"""
    var dec = KafkaDecoder(data)
    var size = Int(dec.get_int32())
    if size < 0:
        raise Error(
            "komira_kafka_server.wire: negative message_size " + String(size)
        )
    var payload = List[UInt8]()
    for _ in range(size):
        payload.append(dec.get_int8().cast[DType.uint8]())
    return FramedMessage(size, payload^)
