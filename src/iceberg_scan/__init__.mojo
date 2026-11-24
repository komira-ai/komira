"""iceberg_scan: reads Apache Iceberg tables (format versions 1 and 2) written by any engine.

`iceberg_scan('<path>')` in SQL and `register_iceberg_table` in the SDK read a
table's current snapshot, or one named by `snapshot_from_id`, from local files.
This package holds everything under those two entry points that reads a byte of
a table:

  * `avro_datum`: any Avro object container file, decoded by the schema its
    header carries (the manifest list and the manifests);
  * `table_metadata`: the `metadata.json` of any writer;
  * `table_ref`: a path (a `*.metadata.json` file or a table directory with a
    `version-hint.text`) resolved to a table pinned to one snapshot and schema,
    its columns as Arrow fields, its `komira.iceberg.table` scan binding, and the
    local path of every path the table stores;
  * `manifests`: the manifest list and the manifest entries, with their column
    metrics and partition values;
  * `prune`: which files a filter can skip, by partition value and column bounds;
  * `scan_planner`: the data files worth reading and the delete files that
    apply to them, as the `IcebergScanSpec` a physical plan carries;
  * `scan_reader`: the rows of those files, with position and equality deletes
    applied and each column bound by field id or name;
  * `table_fixture`: builders of metadata and manifest bytes for tests.

Errors are `TOKEN: detail` strings: ICEBERG_TABLE_VERSION_UNKNOWN,
ICEBERG_METADATA_INVALID, ICEBERG_SNAPSHOT_NOT_FOUND, ICEBERG_TYPE_UNSUPPORTED,
ICEBERG_PATH_UNSUPPORTED, ICEBERG_MANIFEST_INVALID, ICEBERG_DATA_FILE_MISMATCH
and OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED.

It reads local files only and has no object store, clock or network.
"""

from .avro_datum import (
    AvroDatum,
    AvroDatums,
    read_avro_datums,
    ICEBERG_MANIFEST_INVALID,
)
from .manifests import (
    IcebergFileEntry,
    IcebergManifestFile,
    IcebergPartitionSummary,
    read_manifest,
    read_manifest_list,
)
from .prune import (
    IcebergPrunePredicate,
    entry_may_match,
    manifest_may_match,
    prune_predicates_of,
)
from .scan_planner import (
    IcebergPlanCounts,
    IcebergPlannedScan,
    plan_iceberg_scan,
)
from .scan_reader import ICEBERG_DATA_FILE_MISMATCH, read_iceberg_scan
from .table_metadata import (
    ICEBERG_METADATA_INVALID,
    ICEBERG_SNAPSHOT_NOT_FOUND,
    OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED,
    IcebergField,
    IcebergPartitionField,
    IcebergPartitionSpecDef,
    IcebergSchemaDef,
    IcebergSnapshotDef,
    IcebergTableMetadata,
    parse_iceberg_metadata,
)
from .table_ref import (
    ICEBERG_PATH_UNSUPPORTED,
    ICEBERG_SCAN_KIND_NAME,
    ICEBERG_TABLE_VERSION_UNKNOWN,
    ICEBERG_TYPE_UNSUPPORTED,
    IcebergTableRef,
    iceberg_arrow_type,
    iceberg_scan_binding,
    iceberg_table_ref_of,
    is_iceberg_binding,
    local_path_of,
    resolve_iceberg_table,
)
