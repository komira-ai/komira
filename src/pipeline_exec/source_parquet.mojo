# =============================================================================
# source_parquet -- SOURCE_PARQUET, the builder from a SourceSpecPod
# =============================================================================
#
# `build_parquet_source_on` turns the Parquet arm of a segment's
# `SourceSpecPod` into a `parquet_scan.ParquetSource` over the file system it
# is given; `build_parquet_source` is that over the local file system, for a
# spec whose store (`parquet_fs`) is the local one, and refuses any other
# with `SCAN_FS_UNSERVED` rather than read a local file of the same name.
# The spec names either a path (a file, a directory or a glob) or a list of
# files with the constant partition columns each file carries
# (`parquet_paths`), the columns to read and a filter the decode applies; the
# builder
#
#   * refuses a spec that is not total (`parquet_spec_is_total`): the spec
#     would then stand for a scan with more in it than the three fields say
#     (more files, a window, a partition predicate), and reading it would
#     silently read file 0 of N;
#   * lists the files: a spec with `parquet_paths` reads exactly those files,
#     in that order, and the source appends the partition columns after the
#     data columns with each file's constants; any other local spec lists its
#     path, and any other remote spec reads its path as one object key (a
#     remote spec is cut from a scan's resolved files, never a glob);
#   * resolves the projection names to leaf indices through the footer of the
#     first file (every file of a table has the same schema), read through the
#     file system into the run's footer cache under the file system's key
#     prefix, where the source's readers find it;
#   * registers the filter's conjuncts in the caller's expression pool as the
#     decode filter (every conjunct is applied, rows that fail it never leave
#     the scan, an UNKNOWN row fails) and the whole filter as the pushed
#     predicate that row-group statistics are checked against;
#   * applies the segment's morsel size.
#
# A decode filter may leave a morsel's batch carrying a deferred selection
# mask; the operators and the sink after the scan honour it.
#
# The source borrows the footer cache and the expression pool; both belong to
# the caller and must outlive every pull. The three origins are parameters so
# the borrow is visible in the type and no wildcard origin is needed.

from std.memory import Pointer

from arrow.schema import Field

from async_rt.ops.waker_sink import NoopSink
from fs.column_set import ColumnSet
from fs.explicit_file_discovery import ExplicitFileDiscovery
from fs.file_system import FileSystem
from fs.local_fs import LocalFs
from fs.scan_fs import ScanFsOpener, scan_fs_unserved
from morsel.dynamic_join_filter import DynamicJoinFilter
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_scan.parquet_reader_factory import ParquetReaderFactory
from parquet_scan.parquet_source import ParquetSource
from parquet_scan.parquet_source_options import (
    resolve_projection_indices_via_fs,
)
from physical_plan.physical_plan import SourceSpecPod
from plan_expr.expr_helpers import flatten_and_conjuncts
from plan_expr.fs_descriptor_pod import FsDescriptorPod
from plan_expr.expr_id import ExprId
from plan_expr.expr_pool import ExprPool
from scan_planning.source_capability_config import (
    SourceCapabilityConfig,
)

comptime LocalScanFs = LocalFs[NoopSink]
"""The file system of the first Parquet source row."""

comptime LocalParquetSource[
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
] = ParquetSource[
    LocalScanFs, ExplicitFileDiscovery, cache_o, pool_o, filter_o
]
"""The Parquet source over the local file system, borrowing the footer cache
(`cache_o`), the expression pool (`pool_o`) and, when a join filter is
installed, that filter (`filter_o`; this builder installs none)."""

comptime ParquetSourceOn[
    FS: FileSystem,
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
] = ParquetSource[FS, ExplicitFileDiscovery, cache_o, pool_o, filter_o]
"""The Parquet source over the file system `FS` (a remote store's), with the
borrows of `LocalParquetSource`."""


struct LocalOnlyScanFs(ScanFsOpener):
    """The opener of a run that reads the local file system only: it opens
    no remote store, so a scan of one is refused with `SCAN_FS_UNSERVED`.
    `RealBuilder`'s default."""

    comptime FS = LocalScanFs

    def __init__(out self):
        pass

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        raise scan_fs_unserved(
            FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
        )


def build_parquet_source[
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
](
    ref spec: SourceSpecPod,
    morsel_rows: Int,
    num_workers: Int,
    ref [cache_o] cache: ParquetMetadataCache,
    ref [pool_o] pool: ExprPool,
    preserve_dict: Bool = False,
) raises -> LocalParquetSource[cache_o, pool_o, filter_o]:
    """`build_parquet_source_on` over the local file system.

    Raises:
        `SCAN_FS_UNSERVED` when the spec's store is not the local file
        system, and what `build_parquet_source_on` raises.
    """
    if not spec.parquet_fs.is_local():
        raise scan_fs_unserved(spec.parquet_fs.url_prefix())
    return build_parquet_source_on[LocalScanFs, cache_o, pool_o, filter_o](
        spec,
        LocalScanFs.new(),
        morsel_rows,
        num_workers,
        cache,
        pool,
        preserve_dict,
    )


def build_parquet_source_on[
    FS: FileSystem,
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
](
    ref spec: SourceSpecPod,
    var fs: FS,
    morsel_rows: Int,
    num_workers: Int,
    ref [cache_o] cache: ParquetMetadataCache,
    ref [pool_o] pool: ExprPool,
    preserve_dict: Bool = False,
) raises -> ParquetSourceOn[FS, cache_o, pool_o, filter_o]:
    """The Parquet source `spec` describes, read through `fs`, for
    `num_workers` workers.

    `morsel_rows` is the segment's morsel size (0: a row group per morsel).
    `preserve_dict` keeps the string columns the file stores dictionary
    encoded as DICTIONARY columns (the DICT_ENCODED string sink reads them by
    code); the default decodes them to STRING.

    Raises:
        If the spec is not total, names no path, names a column the file lacks,
        or the source cannot open its files.
    """
    if not spec.parquet_spec_is_total:
        raise Error(
            "pipeline_exec: the Parquet spec of path '"
            + spec.parquet_path
            + "' is not total, so it stands for a scan with more in it than"
            " its path, projection and filter; reading it would read the"
            " first file only"
        )
    if spec.parquet_path.byte_length() == 0:
        raise Error("pipeline_exec: a Parquet source names no path")
    # A local path may be a glob or a directory: the columns are named
    # against the footer of the first file it lists, the one the source's
    # union schema starts from. A spec that lists its files hands them over
    # as they are, and a remote spec's one path is one object key.
    var discovery: ExplicitFileDiscovery
    if len(spec.parquet_paths) > 0:
        discovery = ExplicitFileDiscovery.from_files(
            spec.parquet_paths,
            spec.parquet_partition_cols,
            spec.parquet_partition_values,
        )
    elif spec.parquet_fs.is_local():
        discovery = ExplicitFileDiscovery.open(fs, spec.parquet_path)
    else:
        var one = List[String]()
        one.append(spec.parquet_path)
        discovery = ExplicitFileDiscovery.from_files(
            one, List[Field](), List[List[String]]()
        )
    var projection = ColumnSet.all()
    if spec.parquet_projection:
        projection = resolve_projection_indices_via_fs(
            cache, discovery.path_at(0), fs, spec.parquet_projection.value()
        )
    var caps = SourceCapabilityConfig.default()
    caps.morsel_rows = morsel_rows
    if spec.parquet_filter:
        ref filter = spec.parquet_filter.value()
        var stages = List[ExprId]()
        var conjuncts = flatten_and_conjuncts(filter)
        for i in range(len(conjuncts)):
            stages.append(pool.register(conjuncts[i].copy()))
        caps.decode_filter_stages = Optional(stages^)
        caps.pushed_predicate = Optional(pool.register(filter.copy()))
    return ParquetSourceOn[FS, cache_o, pool_o, filter_o](
        fs^,
        discovery^,
        ParquetReaderFactory[cache_o, FS].new(Pointer(to=cache)),
        projection^,
        Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, filter_o]](None),
        num_workers,
        preserve_dict=preserve_dict,
        caps=caps^,
    )
