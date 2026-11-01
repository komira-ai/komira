"""komira_kafka_broker: the broker half of the Kafka server.

komira_kafka_server holds the Kafka wire codec (bytes in, values out) and has
no dependencies. This package is the layer above it, which turns those values
into broker state:

  * kafka_compression.mojo: decompression of a v2 RecordBatch records blob
    (gzip, snappy in the xerial framing, lz4 frame, zstd), and the
    compression-aware message-set decoders of the Produce path.
  * kafka_fetch_compress.mojo: the matching compression of a Fetch batch's
    Record* array.
  * group_offsets.mojo: committed consumer-group offsets as objects in a
    conditional-write object store.
  * envelope_bridge.mojo: Kafka records to and from an Arrow RecordBatch with
    the fixed five-column envelope schema.
  * group_coordinator.mojo: the consumer-group rebalance state machine
    (JoinGroup, SyncGroup, Heartbeat, LeaveGroup) over a conditional-write
    store. Its parts: group_state.mojo (the persisted group state and its JSON),
    group_membership.mojo (which members a round carries, whether an assignment
    is valid), group_assignor.mojo (the range assignor) and group_clock.mojo
    (the clock the coordinator reads and waits on).

No pointer type appears in any public signature.
"""

from .kafka_compression import (
    decompress_kafka_records,
    decode_record_batches_decompressing,
    decode_producer_batches_decompressing,
    DecodedProducerBatch,
    KAFKA_COMPRESSION_NONE,
    KAFKA_COMPRESSION_GZIP,
    KAFKA_COMPRESSION_SNAPPY,
    KAFKA_COMPRESSION_LZ4,
    KAFKA_COMPRESSION_ZSTD,
)

from .kafka_fetch_compress import (
    compress_kafka_records,
    fetch_compression_codec_name,
    FETCH_COMPRESSION_NONE,
    FETCH_COMPRESSION_GZIP,
    FETCH_COMPRESSION_SNAPPY,
    FETCH_COMPRESSION_LZ4,
    FETCH_COMPRESSION_ZSTD,
)

from .group_offsets import (
    GroupOffsetStore,
    CommittedOffset,
    FetchedOffset,
    encode_offset_json,
    decode_offset_json,
)

from .envelope_bridge import (
    ENVELOPE_KEY,
    ENVELOPE_VALUE,
    ENVELOPE_TIMESTAMP,
    ENVELOPE_OFFSET,
    ENVELOPE_HEADERS,
    envelope_schema,
    kafka_records_to_envelope,
    envelope_to_kafka_records,
)

from .group_clock import GroupClock, SystemGroupClock, ManualGroupClock

from .group_state import (
    GroupMember,
    GroupState,
    GROUP_STATE_EMPTY,
    GROUP_STATE_PREPARING,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_STABLE,
    DEFAULT_SESSION_TIMEOUT_MS,
    GHOST_STALE_GRACE_MS,
    encode_group_state_json,
    decode_group_state_json,
)

from .group_assignor import range_assign, pick_protocol_name

from .group_membership import reconcile_members, assignment_is_valid

from .group_coordinator import (
    GroupCoordinator,
    JoinResult,
    JOIN_POLL_INTERVAL_MS,
    JOIN_POLL_MAX_ITERS,
)
