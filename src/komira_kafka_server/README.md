# komira_kafka_server

The Kafka wire protocol in pure Mojo, as specified at
https://kafka.apache.org/protocol.html. Today the package is its codec, the
`wire` subpackage (`komira_kafka_server.wire`); the server that handles
connections and dispatches requests will live next to it in this package.

`wire` holds:

- `KafkaEncoder` and `KafkaDecoder`: every primitive type of the protocol
  (big-endian `INT8` to `INT64`, `BOOLEAN`, `STRING`, `NULLABLE_STRING`,
  `BYTES`, `UNSIGNED_VARINT`, the compact forms, tagged fields);
- request header parsing, response headers and the `INT32` length-prefix
  framing;
- the v2 `RecordBatch` with its CRC-32C;
- the request and response schemas of ApiVersions, Metadata, Produce, Fetch,
  ListOffsets, the consumer-group APIs, CreateTopics, InitProducerId and the
  transactional APIs.

`wire` works on bytes only: it opens no socket and depends on nothing outside
the Mojo standard library. A decoder refuses truncated or inconsistent input
by raising.

Next to it, `produce_error_for` (in `komira_kafka_server.produce_error`) maps
the error a partition append raised to its Produce error code. A win in a
reaped manifest slot, a fenced writer and exhausted append retries are
`NOT_LEADER_OR_FOLLOWER` (nothing was written; retry); an append whose outcome
is unknown is `REQUEST_TIMED_OUT`. It matches the fixed tokens of the object
store's error texts (`slot_reaped:` and `log_start_unread:` as the leading
token, `lease_fenced` anywhere, `(retryable)` with `exhausted`) by its own
copies, so the package has no dependencies; the test
`tests/kafka_produce_error_tokens` holds the copies equal to
`komira_objectstore`'s.

Every example below runs as a test when the package is built, so it cannot
go stale.

## A Produce error code

```mojo
from komira_kafka_server.produce_error import produce_error_for
from komira_kafka_server.wire.produce_fetch import ERROR_NOT_LEADER_OR_FOLLOWER, ERROR_REQUEST_TIMED_OUT, ERROR_UNKNOWN_SERVER_ERROR
from std.testing import assert_equal

# Nothing was committed: the client retries.
assert_equal(produce_error_for("slot_reaped: CasManifestStore.append (retryable): ..."), ERROR_NOT_LEADER_OR_FOLLOWER)
# The outcome is unknown, whatever the cause spells.
assert_equal(produce_error_for("log_start_unread: ... cause: slot_reaped lease_fenced"), ERROR_REQUEST_TIMED_OUT)
# A sentinel counts only as the leading token.
assert_equal(produce_error_for("segment PUT failed: slot_reaped: ..."), ERROR_UNKNOWN_SERVER_ERROR)
```

## Primitives and framing

```mojo
from komira_kafka_server.wire import KafkaDecoder, KafkaEncoder, frame_message, read_framed_message
from std.testing import assert_equal, assert_false

var enc = KafkaEncoder()
enc.put_int32(Int32(42))
enc.put_string("kafka")
enc.put_nullable_string(Optional[String]())
enc.put_unsigned_varint(UInt32(300))
var body = enc.take_bytes()
assert_equal(len(body), 4 + 2 + 5 + 2 + 2)

var framed = frame_message(Span(body))
assert_equal(len(framed), 4 + len(body))  # an INT32 size, then the body

var msg = read_framed_message(Span(framed))
assert_equal(msg.size, len(body))
var dec = KafkaDecoder(Span(msg.payload))
assert_equal(dec.get_int32(), Int32(42))
assert_equal(dec.get_string(), "kafka")
assert_false(Bool(dec.get_nullable_string()))  # null is a length of -1
assert_equal(dec.get_unsigned_varint(), UInt32(300))
assert_equal(dec.remaining(), 0)
```

## A request header

```mojo
from komira_kafka_server.wire import API_KEY_METADATA, KafkaDecoder, KafkaEncoder, parse_request_header
from std.testing import assert_equal

var enc = KafkaEncoder()
enc.put_int16(API_KEY_METADATA)
enc.put_int16(Int16(9))
enc.put_int32(Int32(7))  # correlation id
enc.put_nullable_string(Optional(String("client-1")))
enc.put_empty_tag_buffer()  # header v2 is flexible
var bytes = enc.take_bytes()

var dec = KafkaDecoder(Span(bytes))
var header = parse_request_header(dec, header_is_flexible=True)
assert_equal(header.api_key, API_KEY_METADATA)
assert_equal(header.api_version, Int16(9))
assert_equal(header.correlation_id, Int32(7))
assert_equal(header.client_id.value(), "client-1")
```

## Record batches

`encode_record_batch_v2` writes one uncompressed v2 batch, numbering the
records from the base offset; `decode_record_batches` reads one or more
batches back, checking each batch's CRC-32C.

```mojo
from komira_kafka_server.wire import KafkaHeader, KafkaRecord, crc32c_list, decode_record_batches, encode_record_batch_v2
from std.testing import assert_equal, assert_raises, assert_true


def utf8(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


var records = List[KafkaRecord]()
records.append(KafkaRecord(Optional(utf8("k1")), Optional(utf8("hello")), List[KafkaHeader](), Int64(1000), Int64(0)))
var headers = List[KafkaHeader]()
headers.append(KafkaHeader(utf8("trace"), Optional(utf8("abc"))))
records.append(KafkaRecord(Optional[List[UInt8]](), Optional(utf8("world")), headers^, Int64(1005), Int64(0)))

var batch = encode_record_batch_v2(records, Int64(100))
var back = decode_record_batches(Span(batch))
assert_equal(len(back), 2)
assert_equal(back[0].offset, Int64(100))
assert_equal(back[1].offset, Int64(101))
assert_equal(back[1].timestamp, Int64(1005))
assert_true(not back[1].key)
assert_equal(back[1].value.value(), utf8("world"))
assert_equal(back[1].headers[0].key, utf8("trace"))

# One flipped byte fails the CRC-32C, and the batch is refused.
batch[len(batch) - 1] ^= 0xFF
with assert_raises():
    _ = decode_record_batches(Span(batch))

# The checksum itself, on the standard check input.
assert_equal(crc32c_list(utf8("123456789")), UInt32(0xE3069283))
```
