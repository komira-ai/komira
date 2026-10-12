# =============================================================================
# komira_test_parquet_file — small flat Parquet files for reader tests
# =============================================================================
#
# A test builds `TestColumn`s (INT32, INT64, DOUBLE or UTF8 BYTE_ARRAY;
# REQUIRED or OPTIONAL; PLAIN or dictionary-encoded) and writes them with
# `write_parquet_file(path, columns, layout)`, cut into row groups and pages
# as the `TestFileLayout` says, with an optional page index. Test-only: a
# library names it in `test_deps`. See parquet_file.mojo.
# =============================================================================

from .parquet_file import (
    PT_BYTE_ARRAY,
    PT_DOUBLE,
    PT_INT32,
    PT_INT64,
    TestColumn,
    TestFileLayout,
    parquet_file_bytes,
    write_parquet_file,
)
