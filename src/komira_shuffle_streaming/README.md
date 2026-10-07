# komira_shuffle_streaming

The object-store shuffle as a streaming segment cut: `ShuffleWriteSink` (a
`StreamingMorselSink`) writes and seals one epoch per step through
`komira_shuffle`, and `ShuffleReadSource` (a `StreamingMorselSource`) polls a
reducer's partition of each sealed epoch, returning Idle (not Closed) while the
epoch is unsealed. Its position is an `EpochCursor` that round-trips through
8 little-endian bytes, and `backlog()` reports the sealed-but-unread epoch lag.

Rows are `(key, value)` pairs of Int64 columns; the codec both sides share is
`shuffle_streaming_codec`.
