"""The datasets of the komira benchmarks: what each is, how to check a cache
directory against it, a lock that records the fingerprint a run used, and a
seeded generator for the h2o-style tables. No data is shipped or committed.
See README.md.

| name | what it is |
|---|---|
| `DatasetManifest`, `DatasetFile` | a dataset at a scale: its files with expected size, sha256 and row count (any of them may be unrecorded) |
| `tpch_manifest`, `clickbench_manifest`, `h2o_groupby_manifest`, `h2o_join_manifest`, `supported_manifests`, `find_manifest` | the supported datasets |
| `verify_dataset`, `VerifyReport`, `FileCheck`, `sha256_of_file` | check a cache directory against a manifest |
| `DatasetLock`, `lock_from_report`, `encode_lock`, `decode_lock`, `write_lock_file`, `read_lock_file`, `lock_file_path`, `verify_against_lock` | the lock file: one fingerprint per dataset a run used, one file per dataset and scale, and a check of a cache directory against it |
| `h2o_groupby_parquet`, `h2o_join_parquet`, `generate_h2o_groupby_files`, `generate_h2o_join_files`, `write_new_file` | the seeded h2o-style generator, as Parquet bytes and as files |
| `h2o_groupby_batch`, `h2o_join_batch` | the same tables as Arrow batches, any row range |
| `generate_tpch`, `render_stage`, `check_extension_file`, `run_stage`, `recorded_files`, `recorded_line` | staging: TPC-H generated through the pinned DuckDB's tpch extension, the report with the lines to record, and the `komira-bench-stage` command line |
"""

from .draw import Bijection, draw, draw_range, draw_score, mix64
from .h2o_files import (
    H2O_BATCH_ROWS,
    generate_h2o_groupby_files,
    generate_h2o_join_files,
    h2o_groupby_parquet,
    h2o_join_parquet,
    write_new_file,
)
from .h2o_groupby import h2o_groupby_batch
from .h2o_join import h2o_join_batch, h2o_join_table_names, h2o_join_table_rows
from .lock import (
    DatasetLock,
    LOCK_DIR_NAME,
    LOCK_FILE_SUFFIX,
    LOCK_FORMAT,
    LockEntry,
    decode_lock,
    encode_lock,
    lock_file_path,
    lock_from_report,
    read_lock_file,
    verify_against_lock,
    write_lock_file,
)
from .manifest import (
    DatasetFile,
    DatasetManifest,
    H2O_DEFAULT_GROUPS,
    H2O_DEFAULT_ROWS,
    H2O_DEFAULT_SEED,
    H2O_GENERATOR_VERSION,
    RecordedFile,
    UNRECORDED_BYTES,
    UNRECORDED_ROWS,
    apply_recorded,
    clickbench_manifest,
    find_manifest,
    h2o_groupby_manifest,
    h2o_join_manifest,
    is_sha256_hex,
    is_token,
    recorded_files,
    recorded_line,
    supported_manifests,
    tpch_manifest,
    validate_relative_path,
)
from .stage import (
    DEFAULT_EXTENSION_PLATFORM,
    EXT_GZIPPED,
    EXT_MISMATCH,
    EXT_PINNED,
    EXT_UNRECORDED,
    ExtensionCheck,
    ExtensionPin,
    Generated,
    STAGE_COMPRESSION,
    STAGE_ROW_GROUP_ROWS,
    STAGE_THREADS,
    STAGE_VERSION,
    TPCH_ABSENT,
    TPCH_PARTIAL,
    TPCH_PRESENT,
    check_extension_bytes,
    check_extension_file,
    copy_statement,
    count_statement,
    dbgen_statement,
    describe_generation,
    extension_pin_line,
    generate_tpch,
    load_statement,
    render_stage,
    sql_literal,
    tpch_extension_pins,
    tpch_state,
    tpch_table_names,
)
from .stage_cli import Flags, parse_flags, parse_positive, run_stage
from .verify import (
    FILE_MISSING,
    FILE_SHA_MISMATCH,
    FILE_SIZE_MISMATCH,
    FILE_UNRECORDED,
    FILE_VERIFIED,
    FileCheck,
    VerifyReport,
    file_status_name,
    sha256_of_file,
    verify_dataset,
)
