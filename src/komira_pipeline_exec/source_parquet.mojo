# =============================================================================
# source_parquet -- SOURCE_PARQUET, the builder from a SourceSpecPod
# =============================================================================
#
# `build_parquet_source` turns the Parquet arm of a segment's `SourceSpecPod`
# into a `komira_parquet_scan.ParquetSource` on the local file system. The
# spec names a path (a file, a directory or a glob), the columns to read and a
# filter the decode applies; the builder
#
#   * refuses a spec that is not total (`parquet_spec_is_total`): the spec
#     would then stand for a scan with more in it than the three fields say
#     (more files, a window, a partition predicate), and reading it would
#     silently read file 0 of N;
#   * resolves the projection names to leaf indices through the footer;
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

from komira_async.ops.waker_sink import NoopSink
from komira_fs.column_set import ColumnSet
from komira_fs.file_discovery import EagerGlobDiscovery
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_parquet_scan.parquet_source import ParquetSource
from komira_parquet_scan.parquet_source_options import (
    resolve_projection_indices,
)
from komira_physical_plan.physical_plan import SourceSpecPod
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_scan_planning.source_capability_config import (
    SourceCapabilityConfig,
)

comptime LocalScanFs = LocalFs[NoopSink]
"""The file system of the first Parquet source row."""

comptime LocalParquetSource[
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
] = ParquetSource[
    LocalScanFs, EagerGlobDiscovery, cache_o, pool_o, filter_o
]
"""The Parquet source over the local file system, borrowing the footer cache
(`cache_o`), the expression pool (`pool_o`) and, when a join filter is
installed, that filter (`filter_o`; this builder installs none)."""


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
    """The Parquet source `spec` describes, for `num_workers` workers.

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
            "komira_pipeline_exec: the Parquet spec of path '"
            + spec.parquet_path
            + "' is not total, so it stands for a scan with more in it than"
            " its path, projection and filter; reading it would read the"
            " first file only"
        )
    if spec.parquet_path.byte_length() == 0:
        raise Error("komira_pipeline_exec: a Parquet source names no path")
    # The path may be a glob or a directory: the columns are named against the
    # footer of the first file it lists, the one the source's union schema
    # starts from.
    var fs = LocalScanFs.new()
    var discovery = EagerGlobDiscovery.open(fs, spec.parquet_path)
    var projection = ColumnSet.all()
    if spec.parquet_projection:
        projection = resolve_projection_indices(
            cache, discovery.path_at(0), spec.parquet_projection.value()
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
    return LocalParquetSource[cache_o, pool_o, filter_o](
        fs^,
        discovery^,
        ParquetReaderFactory[cache_o, LocalScanFs].new(Pointer(to=cache)),
        projection^,
        Optional(Pointer(to=pool)),
        Optional[Pointer[DynamicJoinFilter, filter_o]](None),
        num_workers,
        preserve_dict=preserve_dict,
        caps=caps^,
    )
