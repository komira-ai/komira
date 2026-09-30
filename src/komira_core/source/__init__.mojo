# =============================================================================
# komira_core.source — abstract source identity for LogicalPlan Scan nodes
# =============================================================================
#
# Every concrete source (ParquetSource, InMemorySource, CSVSource,
# JSONSource, ...) implements the `SourceLike` trait with three methods:
#   - schema()        -> Schema
#   - estimate_rows() -> Int
#   - fingerprint()   -> UInt64
#
# `to_dataframe()` is INTENTIONALLY NOT part of the trait — cyclic type
# dependency (DataFrame -> ScanPlan -> SourceVariant -> SourceLike). Each
# concrete source declares its own `def to_dataframe(var self) -> DataFrame`
# inline (~3 LOC).
#
# Trait definition lives in `source_like.mojo`.
# =============================================================================

from .source_like import SourceLike
from .parquet_source import ParquetSource
from .in_memory_source import InMemorySource
from .json_source import JsonSource
from .csv_source import CsvSource
from .orc_source import OrcSource
from .sink import Sink, InMemorySink, InMemBuf
from .source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_JSON,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_ORC,
)
from .column_stats import (
    ColumnStats,
    HyperLogLog,
    compute_column_stats,
    HLL_P,
    HLL_REGISTERS,
    EXACT_NDV_THRESHOLD,
    BLOOM_NDV_CAP,
    BLOOM_FPP,
    COLSTATS_KIND_PRIMITIVE,
    COLSTATS_KIND_LIST,
    COLSTATS_KIND_STRUCT,
)
