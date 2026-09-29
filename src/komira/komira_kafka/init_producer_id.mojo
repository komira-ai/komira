# =============================================================================
# src/komira/komira_kafka/init_producer_id.mojo — Kafka InitProducerId (api_key 22)
# =============================================================================
#
# The idempotent producer. InitProducerId is the
# RPC a producer with `enable.idempotence=true` sends FIRST: the broker
# allocates a producer_id + a producer_epoch (the idempotence identity the
# producer then stamps on every RecordBatch). KIP-98.
#
# Wire format (NON-flexible v1..v2 — kafka-python negotiates these):
#
#   Request:
#     transactional_id        NULLABLE_STRING  (null for a non-transactional
#                                               idempotent producer; set for a
#                                               transactional one)
#     transaction_timeout_ms  INT32
#
#   Response:
#     throttle_time_ms        INT32
#     error_code              INT16
#     producer_id             INT64
#     producer_epoch          INT16
#
# (v3 adds request producer_id/producer_epoch for epoch-bump-on-restart and
# v4 is flexible — neither is decoded here. v1/v2 share this body shape; v0 had
# no transaction_timeout_ms but predates the idempotent producer.)
#
# Encapsulation: ZERO UnsafePointer in any signature — a pure wire edge like
# the rest of komira_kafka (Span in / owned List[UInt8] out).
# =============================================================================

from komira_kafka.wire import KafkaEncoder, KafkaDecoder
from komira_kafka.messages import encode_response_header_v0


comptime API_KEY_INIT_PRODUCER_ID: Int16 = 22

# Kafka canonical error codes for the idempotent/transactional path.
comptime ERROR_OUT_OF_ORDER_SEQUENCE_NUMBER: Int16 = 45
comptime ERROR_DUPLICATE_SEQUENCE_NUMBER: Int16 = 46
comptime ERROR_INVALID_PRODUCER_EPOCH: Int16 = 47
comptime ERROR_INVALID_PRODUCER_ID_MAPPING: Int16 = 49


struct InitProducerIdRequest(Movable, Deinitable):
    """A decoded InitProducerId request (v1..v2).

    `transactional_id` is null for a plain idempotent producer. POD +
    one owned Optional[String]; a transient stack value (no pointer field)."""

    var transactional_id: Optional[String]
    var transaction_timeout_ms: Int32

    def __init__(
        out self,
        var transactional_id: Optional[String],
        transaction_timeout_ms: Int32,
    ):
        self.transactional_id = transactional_id^
        self.transaction_timeout_ms = transaction_timeout_ms


def decode_init_producer_id_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> InitProducerIdRequest:
    """Decode an InitProducerId request body (v1..v2), positioned just after
    the request header."""
    var txn_id = dec.get_nullable_string()
    var timeout = dec.get_int32()
    return InitProducerIdRequest(txn_id^, timeout)


def encode_init_producer_id_response(
    correlation_id: Int32,
    error_code: Int16,
    producer_id: Int64,
    producer_epoch: Int16,
) -> List[UInt8]:
    """Encode an InitProducerId v1..v2 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_int16(error_code)
    enc.put_int64(producer_id)
    enc.put_int16(producer_epoch)
    return enc.take_bytes()
