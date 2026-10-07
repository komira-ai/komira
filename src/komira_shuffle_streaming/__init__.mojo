"""`komira_shuffle_streaming`: the object-store shuffle as a streaming segment
cut.

A multi-segment streaming pipeline is cut at shuffle boundaries. Segment N's
output is a `ShuffleWriteSink` (a `komira_morsel` `StreamingMorselSink`) and
segment N+1's input is a `ShuffleReadSource` (a `StreamingMorselSource`), both
over the same `shuffle_id` namespace of a `komira_objectstore` conditional-write
store. They are plumbing over the per-epoch shuffle functions of
`komira_shuffle` (`sink_shuffle_write`, `seal_step`, `read_shuffle_partition`);
epoch == step id.

    shuffle_streaming_codec    the 8-byte LE key/value row codec both sides use
    shuffle_streaming_sink     ShuffleWriteSink: buffer, write, seal per epoch
    shuffle_streaming_source   ShuffleReadSource and its EpochCursor position

Import from the modules (`komira_shuffle_streaming.shuffle_streaming_sink`,
`komira_shuffle_streaming.shuffle_streaming_source`); this file re-exports
nothing.
"""
