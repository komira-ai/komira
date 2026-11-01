"""`komira_comms_index` — comms metadata and query-index substrate.

A per-collection CAS-manifest DELTA-LOG of immutable index chunks plus a
mutable `_HEAD` CAS pointer, compacted into immutable base chunks, all on an
object store with no always-on database. The mutable hot path (flip a \\Seen
bit, advance a read cursor) is the CAS-manifest create-CAS plus the `_HEAD`
compare-swap, not an immutable file format.

This package is the substrate only: it wires no comms server. Each server plugs
its own KeyedDelta body in:
  * mail flags        — key = UID bytes, value = flag bitset; TOMBSTONE = EXPUNGE.
  * calendar sync     — key = item-leaf, value = (etag, dtstart, dtend);
                        TOMBSTONE = REMOVE; chunk_seq = durable sync-token.
  * chat event-log    — key = event-id, value = (ciphertext_leaf, sender, ts);
                        append-only (no TOMBSTONE); chunk_seq = timeline order.

It reuses the CAS-manifest substrate and the conditional store from
`komira_objectstore`. What it adds is (1) the chunk-body codecs
(comms_chunk_codec), (2) the read-fold (CommsIndex.read_state), (3) the
compaction body (CommsIndex.compact).

Public surface (re-exported here for `from komira_comms_index import ...`):
  * CommsIndex[Store]   — the generic mechanism (put_delta / read_state /
                          compact + head_seq / log_start_seq introspection).
  * CommsState          — the materialized merged state (read_state's return).
  * KeyedDelta          — the one generic last-writer-wins delta record.
  * DELTA_OP_PUT / DELTA_OP_TOMBSTONE — the op discriminants.
  * key_bytes / bytes_equal — pure key-byte helpers.
  * encode_keyed_delta / decode_keyed_delta — the body codec (for callers that
                          need the round-trip directly).
"""

from komira_comms_index.comms_chunk_codec import (
    KeyedDelta,
    DELTA_OP_PUT,
    DELTA_OP_TOMBSTONE,
    delta_op_name,
    bytes_equal,
    key_bytes,
    encode_keyed_delta,
    decode_keyed_delta,
    encode_compacted_base,
    decode_compacted_base,
    COMMS_BASE_VERSION,
)
from komira_comms_index.comms_index import (
    CommsIndex,
    CommsState,
    CommsDelta,
)
