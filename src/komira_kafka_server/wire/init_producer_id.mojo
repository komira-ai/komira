# =============================================================================
# src/komira_kafka_server/wire/init_producer_id.mojo — Kafka InitProducerId (api_key 22)
# =============================================================================
#
# The idempotent producer. InitProducerId is the RPC a producer with
# `enable.idempotence=true` (or a transactional id) sends first: the broker
# allocates a producer_id + a producer_epoch (the identity the producer then
# stamps on every RecordBatch). KIP-98.
#
# Versions: this codec serves v0..v5, the "validVersions": "0-5" of
# InitProducerIdRequest.json and InitProducerIdResponse.json in apache/kafka
# (tag 3.9.0, clients/src/main/resources/common/message/). Any other version
# is refused by both the decoder and the encoder. (Kafka trunk adds v6 for
# KIP-939 two-phase commit, marked "latestVersionUnstable"; not served here.)
#
# Version facts from those schemas:
#   * v1 is the same as v0 (the response comment: from v1 on, a broker sends
#     the response before throttling; the bytes do not change).
#   * v2 is the first flexible version ("flexibleVersions": "2+", KIP-482):
#     request header v2 (client_id stays a non-compact NULLABLE_STRING, then a
#     TAG_BUFFER), response header v1 (correlation_id + TAG_BUFFER), strings
#     COMPACT, and a TAG_BUFFER closing each body. Trunk states the header
#     mapping explicitly ("headerVersions": request "0-1": "1", "2+": "2";
#     response "0-1": "0", "2+": "1").
#   * v3 adds the request fields ProducerId and ProducerEpoch ("versions":
#     "3+", default -1); the response v3 is the same as v2.
#   * v4 (PRODUCER_FENCED) and v5 (TRANSACTION_ABORTABLE, KIP-890) add error
#     codes only; their bytes are the v3 bytes.
#
#   Request:
#     transactional_id        v0-1 NULLABLE_STRING, v2+ COMPACT_NULLABLE_STRING
#                             ("nullableVersions": "0+": null for a
#                             non-transactional idempotent producer)
#     transaction_timeout_ms  INT32
#     producer_id             INT64   (v3+)
#     producer_epoch          INT16   (v3+)
#     TAG_BUFFER                      (v2+)
#
#   Response:
#     throttle_time_ms        INT32
#     error_code              INT16
#     producer_id             INT64
#     producer_epoch          INT16
#     TAG_BUFFER                      (v2+)
#
# The caller parses the request header with
# `parse_request_header(dec, init_producer_id_is_flexible(api_version))`
# and then decodes the body at that version.
#
# Encapsulation: ZERO UnsafePointer in any signature — a pure wire edge like
# the rest of komira_kafka_server.wire (Span in / owned List[UInt8] out).
# =============================================================================

from komira_kafka_server.wire.wire import KafkaEncoder, KafkaDecoder
from komira_kafka_server.wire.messages import (
    encode_response_header_v0,
    encode_response_header_v1,
)


comptime API_KEY_INIT_PRODUCER_ID: Int16 = 22

# The version range this codec serves (validVersions "0-5").
comptime INIT_PRODUCER_ID_MIN_VERSION: Int16 = 0
comptime INIT_PRODUCER_ID_MAX_VERSION: Int16 = 5

# Kafka canonical error codes for the idempotent/transactional path.
comptime ERROR_OUT_OF_ORDER_SEQUENCE_NUMBER: Int16 = 45
comptime ERROR_DUPLICATE_SEQUENCE_NUMBER: Int16 = 46
comptime ERROR_INVALID_PRODUCER_EPOCH: Int16 = 47
comptime ERROR_INVALID_PRODUCER_ID_MAPPING: Int16 = 49


def init_producer_id_is_flexible(api_version: Int16) -> Bool:
    """True when InitProducerId `api_version` uses the flexible encoding
    (request header v2, response header v1, compact strings, tag buffers):
    "flexibleVersions": "2+"."""
    return api_version >= Int16(2)


def _check_version(api_version: Int16) raises:
    if (
        api_version < INIT_PRODUCER_ID_MIN_VERSION
        or api_version > INIT_PRODUCER_ID_MAX_VERSION
    ):
        raise Error(
            "komira_kafka_server.wire: InitProducerId version "
            + String(api_version)
            + " is not supported (this codec serves v0..v5)"
        )


struct InitProducerIdRequest(Movable, Deinitable):
    """A decoded InitProducerId request (v0..v5).

    `transactional_id` is null for a plain idempotent producer.
    `producer_id` / `producer_epoch` are on the wire at v3+; below v3 they
    hold the schema default -1. POD + one owned Optional[String]; a transient
    stack value (no pointer field)."""

    var transactional_id: Optional[String]
    var transaction_timeout_ms: Int32
    var producer_id: Int64
    var producer_epoch: Int16

    def __init__(
        out self,
        var transactional_id: Optional[String],
        transaction_timeout_ms: Int32,
        producer_id: Int64,
        producer_epoch: Int16,
    ):
        self.transactional_id = transactional_id^
        self.transaction_timeout_ms = transaction_timeout_ms
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch


def decode_init_producer_id_request[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], api_version: Int16
) raises -> InitProducerIdRequest:
    """Decode an InitProducerId request body at `api_version` (v0..v5),
    positioned just after the request header. Refuses any other version."""
    _check_version(api_version)
    var flexible = init_producer_id_is_flexible(api_version)
    var txn_id: Optional[String]
    if flexible:
        txn_id = dec.get_compact_nullable_string()
    else:
        txn_id = dec.get_nullable_string()
    var timeout = dec.get_int32()
    var producer_id = Int64(-1)
    var producer_epoch = Int16(-1)
    if api_version >= Int16(3):
        producer_id = dec.get_int64()
        producer_epoch = dec.get_int16()
    if flexible:
        dec.skip_tag_buffer()
    return InitProducerIdRequest(
        txn_id^, timeout, producer_id, producer_epoch
    )


def encode_init_producer_id_response(
    correlation_id: Int32,
    api_version: Int16,
    error_code: Int16,
    producer_id: Int64,
    producer_epoch: Int16,
) raises -> List[UInt8]:
    """Encode an InitProducerId response at `api_version` (v0..v5): response
    header v0 + body below v2, response header v1 + body + empty TAG_BUFFER
    at v2+. Refuses any other version."""
    _check_version(api_version)
    var flexible = init_producer_id_is_flexible(api_version)
    var enc = KafkaEncoder()
    if flexible:
        encode_response_header_v1(enc, correlation_id)
    else:
        encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_int16(error_code)
    enc.put_int64(producer_id)
    enc.put_int16(producer_epoch)
    if flexible:
        enc.put_empty_tag_buffer()
    return enc.take_bytes()
