# =============================================================================
# transcode.mojo: concat and transcode (Arrow-IPC live segments to Parquet)
# =============================================================================
#
# The format-bridging half of compaction. This is why the adapter package
# exists: it needs `decode_arrow_ipc_stream` (`komira_op_sources`) and
# `write_record_batches_to_parquet_bytes` (`komira_parquet_writer`), neither of
# which `komira_broker` may depend on.
#
#   live `.seg` Arrow-IPC stream bytes (N segments)
#     --decode_arrow_ipc_stream-->  N RecordBatches (one per segment)
#     --schema-divergence check-->  (raises if schemas differ)
#     --write_record_batches_to_parquet_bytes-->  ONE Parquet object's bytes
#
# TRANSCODE FIDELITY:
#   * Values are byte-faithful: every row's column data round-trips through
#     Arrow-IPC decode and Parquet encode unchanged (the cross-tier CRC test
#     checks this).
#   * Nullability and column order round-trip (the Parquet writer derives the
#     schema from the Arrow schema, honors per-column nullable and preserves
#     order).
#   * DICTIONARY columns are expanded to plain on the Parquet side:
#     `decode_arrow_ipc_stream` materializes dictionary-encoded columns to
#     their plain StringArray or values, and the Parquet writer encodes on its
#     own side (it may dictionary-encode per its cardinality heuristic, but the
#     dictionary encoding of the live segment is not preserved). The values
#     are preserved; only the on-wire dictionary encoding is lost.
#
# SCHEMA EVOLUTION: a single schema per topic is assumed. If two segments in
# one compaction round have divergent schemas (different column count, names,
# types or nullability), `transcode_segments_to_parquet` raises; it never
# merges them silently. Union-encoding across schema versions is not done.
#
# No UnsafePointer in any signature: the surface is List[UInt8], Slab,
# RecordBatch and plain values.
# =============================================================================

from komira_collections.slab import Slab
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream
from komira_parquet_writer.record_batch_writer import (
    write_record_batches_to_parquet_bytes,
)
from komira_parquet_api.types import CompressionCodec


# =============================================================================
# decode_segment_stream — one live `.seg` stream's bytes -> one RecordBatch.
# =============================================================================


def decode_segment_stream(var stream_bytes: List[UInt8]) raises -> RecordBatch:
    """Decode ONE live segment's Arrow-IPC stream bytes (footer already sliced
    off by `ConsumeCore.read_segment`) into a single RecordBatch.

    `decode_arrow_ipc_stream` concats the segment's N internal RecordBatch
    frames into one RecordBatch. DICTIONARY columns are materialized to their
    plain (expanded) values here."""
    return decode_arrow_ipc_stream(stream_bytes^)


# =============================================================================
# assert_uniform_schema: schema-divergence detection.
# =============================================================================


def assert_uniform_schema(batches: Slab[RecordBatch]) raises:
    """Raise if the batches do not all share one schema. A single schema per
    topic is assumed; a divergence is a hard error, never a silent mis-merge.

    Snapshots batch 0's schema shape (column count, names, arrow types,
    nullability — the dimensions Parquet round-trips) into plain `List`s ONCE,
    then compares each subsequent batch against those snapshots. Holding only
    ONE Slab ref at a time (never `batches[0]` and `batches[i]` simultaneously)
    keeps the borrows disjoint.
    """
    var n = len(batches)
    if n <= 1:
        return
    # Snapshot batch 0's schema shape into POD locals.
    var n_cols = batches[0].schema.num_columns()
    var names0 = List[String]()
    var types0 = List[Int]()
    var nullable0 = List[Bool]()
    for c in range(n_cols):
        names0.append(batches[0].schema.field_name(c))
        types0.append(Int(batches[0].schema.field_arrow_type(c).type_id))
        nullable0.append(batches[0].schema.field_nullable(c))

    for i in range(1, n):
        var ok = batches[i].schema.num_columns() == n_cols
        if ok:
            for c in range(n_cols):
                if batches[i].schema.field_name(c) != names0[c]:
                    ok = False
                    break
                if (
                    Int(batches[i].schema.field_arrow_type(c).type_id)
                    != types0[c]
                ):
                    ok = False
                    break
                if batches[i].schema.field_nullable(c) != nullable0[c]:
                    ok = False
                    break
        if not ok:
            raise Error(
                "transcode: SCHEMA DIVERGENCE between segment 0 and segment "
                + String(i)
                + " in one compaction round — a single schema per topic is"
                " assumed (union-encode across schema versions is not"
                " done). Refusing to mis-merge."
            )


# =============================================================================
# transcode_segments_to_parquet — N live segment streams -> ONE Parquet object.
# =============================================================================


def transcode_segments_to_parquet(
    var segment_streams: Slab[List[UInt8]],
    codec: CompressionCodec = CompressionCodec.SNAPPY,
) raises -> List[UInt8]:
    """Decode N live segment Arrow-IPC streams + transcode them into ONE
    Parquet object's bytes (see the fidelity notes at the top of this file).

    Steps:
      1. Decode each segment stream into a RecordBatch (one per segment, in the
         order given — which the caller passes in OFFSET order).
      2. Assert all segments share one schema (fail-loud on divergence).
      3. Write all RecordBatches into ONE Parquet object via the bytes entry
         (`write_record_batches_to_parquet_bytes`), with no local disk (the
         broker stores only in the object store). The writer concats the
         batches in order, so the Parquet object's row order == the
         concatenated live offset order.

    Returns the Parquet file bytes (PAR1 magic + pages + footer + trailer),
    ready to PUT to object storage.

    `segment_streams` is consumed (Movable-only `List[UInt8]` elements, so the
    container is `Slab`, not `List[List[UInt8]]`)."""
    var n = len(segment_streams)
    if n == 0:
        raise Error("transcode_segments_to_parquet: no segment streams")

    # 1. Decode each segment stream into a RecordBatch (offset order preserved).
    var batches = Slab[RecordBatch]()
    for i in range(n):
        var stream = segment_streams.take_slot_unchecked(i)
        batches.append(decode_segment_stream(stream^))
    segment_streams.set_len_unchecked(0)
    _ = segment_streams^

    # 2. Schema-divergence check (raises).
    assert_uniform_schema(batches)

    # 3. Transcode -> ONE Parquet object's bytes (no local disk).
    return write_record_batches_to_parquet_bytes(batches^, codec=codec)
