# shuffle_streaming

The object-store shuffle as a streaming segment cut: `ShuffleWriteSink` (a
`StreamingMorselSink`) writes and seals one epoch per step through
`shuffle`, and `ShuffleReadSource` (a `StreamingMorselSource`) polls a
reducer's partition of each sealed epoch, returning Idle (not Closed) while the
epoch is unsealed. Its position is an `EpochCursor` that round-trips through
8 little-endian bytes, and `backlog()` reports the sealed-but-unread epoch lag.

Rows are `(key, value)` pairs of Int64 columns; the codec both sides share is
`shuffle_streaming_codec`.

## Examples

A row's key and value are each 8 little-endian bytes. The key bytes drive the
partitioner; the value bytes are what the reader decodes, and a payload shorter
than 8 bytes raises:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from shuffle_streaming.shuffle_streaming_codec import decode_value_payload, encode_key_bytes, encode_value_payload

var key = encode_key_bytes(Int64(0x0102030405060708))
assert_equal(len(key), 8)
for i in range(8):
    assert_equal(Int(key[i]), 8 - i)

var payload = encode_value_payload(Int64(-2))
assert_equal(Int(payload[0]), 0xFE)
assert_equal(Int(payload[7]), 0xFF)
assert_equal(decode_value_payload(payload), Int64(-2))

_ = payload.pop()
with assert_raises(contains="payload too short"):
    _ = decode_value_payload(payload)
```

The reader's position is an `EpochCursor`: the next epoch to poll, written as 8
little-endian bytes so the engine can keep it in its checkpoint and hand it back
to `seek`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from shuffle_streaming.shuffle_streaming_source import EpochCursor

assert_equal(EpochCursor().epoch, Int64(0))

var cursor = EpochCursor(Int64(0x0102030405060708))
var buf = cursor.to_checkpoint_bytes()
assert_equal(buf.length(), 8)
for i in range(8):
    assert_equal(Int(buf.read_byte()), 8 - i)

var back = EpochCursor.from_checkpoint_bytes(cursor.to_checkpoint_bytes())
assert_equal(back.epoch, cursor.epoch)

var negative = EpochCursor(Int64(-5))
var restored = EpochCursor.from_checkpoint_bytes(negative.to_checkpoint_bytes())
assert_equal(restored.epoch, Int64(-5))
```
