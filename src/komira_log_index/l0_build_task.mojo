# =============================================================================
# komira_log_index.l0_build_task: the small run-to-completion L0 build task.
# =============================================================================
#
# This is a SpawnableTask: a caller spawns it and a per-core worker runs it
# type-erased through the spawner's task-entry trampoline. The task body lives
# entirely on the producer side of the type-erasure boundary, so komira_async
# runs the L0 build through a function pointer without importing
# komira_log_index.
#
# WHAT THE TASK DOES (small by design: it bounds the per-task build time to
# about 50us, roughly 16 to 24 documents, below one reactor-poll starvation
# window):
#   1. transpose the OWNED `List[LogRecordView]` batch into the typed log-index
#      RecordBatch (`log_views_to_record_batch`);
#   2. build the cheap L0 posting split (`L0SegmentBuilder`: the unsorted
#      posting, the reused doc store and the reused fast-field region, in a
#      SPLIT_VERSION=1 additive-footer container);
#   3. publish the L0 split into the CAS-sharded sub-lineage: the split PUT
#      first (an idempotent orphan if the process dies before the next step),
#      then the metastore CAS-append (the linearization point that makes the
#      split searchable). The same two-step order any publisher over the
#      catalog follows, generic over the store type.
#
# RUN TO COMPLETION (not resumable): `run()` does the whole build and publish
# in one shot. That is safe only because the L0 build is cheap and small.
#
# This module has no UnsafePointer in any signature. The views are an owned
# `List[LogRecordView]` (never a byte-slab element); the store and the
# metastore are owned by value; the split bytes are an owned List. The only
# type erasure is the spawner's task-entry function pointer, which the spawner
# owns.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_search_catalog import (
    SearchMetastore,
    make_split_summary,
)

from komira_async.spawner.spawner import SpawnableTask

from komira_log import LogRecordView
from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    log_index_schema,
    log_views_to_record_batch,
)
from komira_log_index.l0_index import L0SegmentBuilder


# -----------------------------------------------------------------------------
# L0BuildResult — the plain result `run()` returns (the SpawnableTask associated
# type must be Copyable, ImplicitlyCopyable, Movable and Deinitable). It carries
# the observable outcome: docs published, a published flag and a failure flag. A
# failed build or publish is surfaced, never swallowed.
# -----------------------------------------------------------------------------


@fieldwise_init
struct L0BuildResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """The outcome of one L0 build task. `published` is True iff the split
    landed in the CAS lineage (searchable); `failed` is True iff the build or
    publish raised (the docs are lost, at most once). `docs` is the batch size;
    `bytes` is the serialized split size (0 on failure)."""

    var published: Bool
    var failed: Bool
    var docs: Int64
    var bytes: Int64

    @staticmethod
    def empty() -> L0BuildResult:
        return L0BuildResult(False, False, Int64(0), Int64(0))


# -----------------------------------------------------------------------------
# _object_key_for_uuid — the object key of an L0 split:
# `<key_prefix>/<index>/splits/<uuid_hex>.split`, byte-identical to
# SearchSink.object_key(). The publish PUTs to this key and the metastore
# CAS-appends the summary pointing at it. A free function because Mojo has no
# String byte-index operator.
# -----------------------------------------------------------------------------


def _object_key_for_uuid(
    key_prefix: String, index: String, uuid: InlineArray[UInt8, 16]
) -> String:
    var hexdigits = "0123456789abcdef"
    var hb = hexdigits.as_bytes()
    var uuid_hex = String("")
    for i in range(16):
        var b = Int(uuid[i])
        uuid_hex += chr(Int(hb[(b >> 4) & 0xF]))
        uuid_hex += chr(Int(hb[b & 0xF]))
    # Strip a single trailing '/' from the prefix (byte-level).
    var pb = key_prefix.as_bytes()
    var plen = len(pb)
    if plen > 0 and pb[plen - 1] == UInt8(47):  # '/'
        plen -= 1
    var prefix_buf = List[UInt8]()
    for i in range(plen):
        prefix_buf.append(pb[i])
    var prefix = String(StringSlice(unsafe_from_utf8=Span(prefix_buf)))
    return prefix + "/" + index + "/splits/" + uuid_hex + ".split"


# -----------------------------------------------------------------------------
# L0BuildTask[Storage] — the SpawnableTask. It captures, as fields, the owned
# views batch, the publish config and the store and metastore (owned by value,
# moved into the task at spawn time). One task builds one L0 split.
# -----------------------------------------------------------------------------


struct L0BuildTask[Storage: ConditionalWriteStore](
    SpawnableTask, Movable, Deinitable
):
    """The small run-to-completion L0 build and publish task. Spawned with an
    owned batch of drained views and the publish target; run by a per-core
    worker, type-erased. `[Storage]` selects the store backend (the in-memory
    conditional store in tests, any `ConditionalWriteStore` in production).

    Move-only (it owns a List[LogRecordView] and a SearchMetastore, both
    Movable). The views are consumed by run() (one shot)."""

    comptime T = L0BuildResult

    var _views: List[LogRecordView]
    var _store: Self.Storage
    var _metastore: SearchMetastore[Self.Storage]
    var _key_prefix: String
    var _index: String
    var _split_uuid: InlineArray[UInt8, 16]

    def __init__(
        out self,
        var views: List[LogRecordView],
        var store: Self.Storage,
        var metastore: SearchMetastore[Self.Storage],
        var key_prefix: String,
        var index: String,
        split_uuid: InlineArray[UInt8, 16],
    ):
        self._views = views^
        self._store = store^
        self._metastore = metastore^
        self._key_prefix = key_prefix^
        self._index = index^
        self._split_uuid = split_uuid.copy()

    def run(mut self) -> Self.T:
        """Build and publish the L0 split for the captured batch, run to
        completion.

        Failure is surfaced, not swallowed: a build or publish error is caught
        and returned as `failed=True` in the result (the docs are the at-most-once
        loss the caller accounts against a loud counter), and run() does not
        re-raise (one task's failure must not crash the worker's drain loop)."""
        var n = Int64(len(self._views))
        if n == Int64(0):
            return L0BuildResult(False, False, Int64(0), Int64(0))
        try:
            # (1) transpose the OWNED views -> the typed log-index batch.
            var batch = log_views_to_record_batch(self._views)

            # (2) build the cheap L0 posting split.
            var schema = log_index_schema()
            var seg = L0SegmentBuilder(schema^)
            seg.add_batch(batch^)
            var split_bytes = seg.serialize_split_bytes(
                LOG_INDEX_TEXT_FIELD, self._split_uuid
            )
            var blen = Int64(len(split_bytes))

            # (3) PUBLISH: the split PUT first (content-addressed and
            #     idempotent, a harmless orphan on a crash before the CAS),
            #     then the metastore CAS-append (the linearization point that
            #     makes it searchable).
            var object_key = _object_key_for_uuid(
                self._key_prefix, self._index, self._split_uuid
            )
            _ = self._store.put(Path.parse(object_key), split_bytes)
            var summary = make_split_summary(
                self._split_uuid.copy(),
                n,
                blen,
                Int64(0),  # min_doc_id (per-split base 0)
                n - Int64(1),  # max_doc_id
                self._index,
                LOG_INDEX_TEXT_FIELD,
                object_key,
            )
            _ = self._metastore.publish(summary^)
            return L0BuildResult(True, False, n, blen)
        except e:
            # Surface the loss (the caller logs and counts it). Do not
            # re-raise: one task failure must not kill the worker loop.
            print(
                "ERROR L0BuildTask: build/publish failed (at-most-once loss of",
                Int(n),
                "docs):",
                String(e),
            )
            return L0BuildResult(False, True, n, Int64(0))
