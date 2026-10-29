# The generated h2o-style tables as Parquet bytes and as files in a cache
# directory. The bytes are komira_parquet_writer's, from batches built row by
# row out of the seed (draw.mojo): the same seed, sizes, codec and batch size
# give the same bytes. `batch_rows` is part of the identity of the bytes, not
# only of the memory use, because the writer chooses its page encodings per
# row group and several batches that fit one row group are written without
# being joined first.

from std.os import makedirs, remove, stat
from std.os.path import exists
from std.pathlib import Path

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_crypto import sha256, hex_lower_array_32
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer import write_record_batches_to_parquet_bytes

from .h2o_groupby import h2o_groupby_batch
from .h2o_join import h2o_join_batch, h2o_join_table_names, h2o_join_table_rows
from .manifest import (
    DatasetManifest,
    h2o_groupby_manifest,
    h2o_join_manifest,
    validate_relative_path,
)

comptime H2O_BATCH_ROWS: Int = 1 << 20
"""Rows built at a time by default."""


def _require_batch_rows(batch_rows: Int) raises:
    if batch_rows < 1:
        raise Error("h2o: batch_rows must be at least 1, got " + String(batch_rows))


def h2o_groupby_parquet(
    rows: Int,
    groups: Int,
    seed: UInt64,
    codec: CompressionCodec = CompressionCodec.SNAPPY,
    batch_rows: Int = H2O_BATCH_ROWS,
) raises -> List[UInt8]:
    """The bytes of the group-by table of `rows` rows and `groups` groups.

    Raises:
        Error: sizes outside the manifest's limits, or `batch_rows` below 1.
    """
    _ = h2o_groupby_manifest(rows, groups, seed)
    _require_batch_rows(batch_rows)
    var batches = Slab[RecordBatch]()
    var start = 0
    while start < rows:
        var n = batch_rows if start + batch_rows <= rows else rows - start
        batches.append(h2o_groupby_batch(rows, groups, seed, start, n))
        start += n
    return write_record_batches_to_parquet_bytes(batches^, codec)


def h2o_join_parquet(
    table: String,
    rows: Int,
    seed: UInt64,
    codec: CompressionCodec = CompressionCodec.SNAPPY,
    batch_rows: Int = H2O_BATCH_ROWS,
) raises -> List[UInt8]:
    """The bytes of join table `table` (x, small, medium or big) for an x
    table of `rows` rows.

    Raises:
        Error: an unknown table, sizes outside the manifest's limits, or
            `batch_rows` below 1.
    """
    _ = h2o_join_manifest(rows, seed)
    _require_batch_rows(batch_rows)
    var total = h2o_join_table_rows(table, rows)
    var batches = Slab[RecordBatch]()
    var start = 0
    while start < total:
        var n = batch_rows if start + batch_rows <= total else total - start
        batches.append(h2o_join_batch(table, rows, seed, start, n))
        start += n
    return write_record_batches_to_parquet_bytes(batches^, codec)


def write_new_file(cache_dir: String, relative_path: String, bytes: List[UInt8]) raises:
    """Write `bytes` to `relative_path` under `cache_dir`, creating the
    directories above it. An existing file is never replaced: a dataset that is
    already there is verified, not regenerated. A write that fails, or that
    leaves a file of another size, removes what it wrote before it raises.

    Raises:
        Error: an invalid path, an empty `cache_dir`, a file already there, or
            a write that failed.
    """
    validate_relative_path(relative_path)
    if cache_dir.byte_length() == 0:
        raise Error("write_new_file: the cache directory is empty")
    var full = cache_dir + "/" + relative_path
    if exists(full):
        raise Error("write_new_file: " + full + " exists; it is never overwritten")
    var slash = relative_path.rfind("/")
    if slash > 0:
        makedirs(cache_dir + "/" + String(relative_path[byte=0:slash]), exist_ok=True)
    var failure = String()
    try:
        Path(full).write_bytes(Span(bytes))
        if Int(stat(full).st_size) != len(bytes):
            failure = String("the file holds ") + String(Int(stat(full).st_size)) + " of " + String(len(bytes)) + " bytes"
    except e:
        failure = String(e)
    if failure.byte_length() > 0:
        try:
            remove(full)
        except:
            pass
        raise Error("write_new_file: " + full + ": " + failure)


def _record_written(mut manifest: DatasetManifest, index: Int, bytes: List[UInt8]):
    """Record the size and sha256 of the bytes just written as the file's
    expectations, so that a file cut short later no longer verifies."""
    manifest.files[index].expected_bytes = len(bytes)
    manifest.files[index].expected_sha256 = hex_lower_array_32(sha256(Span(bytes)))


def generate_h2o_groupby_files(
    cache_dir: String, rows: Int, groups: Int, seed: UInt64
) raises -> DatasetManifest:
    """Write the group-by table where its manifest says and return the
    manifest with the size and sha256 of the bytes written filled in.

    Raises:
        Error: as `h2o_groupby_parquet` and `write_new_file`.
    """
    var manifest = h2o_groupby_manifest(rows, groups, seed)
    var bytes = h2o_groupby_parquet(rows, groups, seed)
    write_new_file(cache_dir, manifest.files[0].path, bytes)
    _record_written(manifest, 0, bytes)
    return manifest^


def generate_h2o_join_files(cache_dir: String, rows: Int, seed: UInt64) raises -> DatasetManifest:
    """Write the four join tables where their manifest says and return the
    manifest with each file's size and sha256 of the bytes written filled in.

    Raises:
        Error: as `h2o_join_parquet` and `write_new_file`.
    """
    var manifest = h2o_join_manifest(rows, seed)
    var tables = h2o_join_table_names()
    for i in range(len(tables)):
        var bytes = h2o_join_parquet(tables[i], rows, seed)
        write_new_file(cache_dir, manifest.files[i].path, bytes)
        _record_written(manifest, i, bytes)
    return manifest^
