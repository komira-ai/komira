"""komira_iceberg: a file-based Apache Iceberg v2 table writer and reader.

A set of Parquet data files becomes a table any Iceberg engine (pyiceberg,
DuckDB, Spark, Trino) reads by pointing at the object store, with no catalog
service. A commit is atomic through the object store's conditional writes.

What the package emits (format-version 2):
  * table metadata.json: schema with stable field ids, partition spec,
    snapshots, current-snapshot-id, sequence numbers.
  * manifest list and manifest files (Avro) listing the data files with
    per-file statistics (record count, lower and upper bounds, null counts).
  * the version-hint.text pointer to the latest metadata version.

This part holds the data leg and the reader: Parquet data files, the Avro delete
files and the merge-on-read table reader, on top of the metadata layer and the
table model. The table writer follows.
"""

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_SEQ_INHERIT,
    iceberg_type_name,
    IcebergField,
    IcebergSchema,
    evolve_add_column,
    ColumnBound,
    DataFileInfo,
    json_escape_string,
)

from .iceberg_bounds import (
    serialize_boolean,
    serialize_int32,
    serialize_int64,
    serialize_float32,
    serialize_float64,
    serialize_string,
    serialize_bytes,
    bound_int32,
    bound_int64,
    bound_float32,
    bound_float64,
    bound_boolean,
    bound_string,
    bound_bytes,
)

from .iceberg_partition import (
    ICE_TRANSFORM_IDENTITY,
    ICE_TRANSFORM_BUCKET,
    ICE_PARTITION_FIELD_ID_BASE,
    PartitionField,
    PartitionSpec,
    PartitionedDataFile,
    transform_name,
    murmur3_x86_32,
    iceberg_bucket_of,
    partition_value_of,
    partition_value_type_tags,
    partition_key_string,
    encode_partition_values,
    route_rows_to_partitions,
)

from .iceberg_metadata_json import (
    SnapshotInfo,
    SummaryKV,
    schema_json,
    unpartitioned_spec_json,
    partition_spec_json,
    partition_spec_fields_json,
    delete_spec_of,
    unsorted_order_json,
    name_mapping_json,
    snapshot_json,
    build_table_metadata_json,
)

from .iceberg_summary import (
    read_current_snapshot_summary,
    summary_value_for,
    parse_summary_object,
)

from .iceberg_version import (
    metadata_dir,
    pointer_key,
    metadata_json_key,
    read_hint_version,
    version_exists,
    current_version,
)

from .iceberg_avro_manifest import (
    ICE_CONTENT_DATA,
    ICE_CONTENT_POSITION_DELETES,
    ICE_CONTENT_EQUALITY_DELETES,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
    ICE_STATUS_EXISTING,
    ICE_STATUS_ADDED,
    ICE_STATUS_DELETED,
    ICE_FILE_FORMAT_PARQUET,
    ICE_FILE_FORMAT_AVRO,
    manifest_entry_schema_json,
    manifest_file_schema_json,
    ManifestFileEntry,
    encode_manifest_entry,
    encode_manifest_file_record,
    build_manifest_file,
    build_manifest_list,
)

from .iceberg_avro_manifest_read import (
    ManifestEntry,
    read_manifest_list,
    read_manifest_entries,
)

from .iceberg_row_value import (
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    reconcile_cell_type,
    encode_cell,
    decode_cell,
    encode_row,
    decode_row,
    rows_equal,
    decode_partition_cell,
    col_types_of,
    build_data_file,
    read_data_file,
)

from .iceberg_parquet_data import (
    build_parquet_data_file,
    read_parquet_data_file,
)

from .iceberg_delete_writer import (
    ICE_POS_DELETE_FILE_PATH_ID,
    ICE_POS_DELETE_POS_ID,
    PositionDeleteEntry,
    build_equality_delete_file,
    read_equality_delete_file,
    build_position_delete_file,
    read_position_delete_file,
)

from .iceberg_reader import (
    IcebergTableReader,
    read_partition_values_from_manifest,
    parse_partition_spec_from_metadata,
)
