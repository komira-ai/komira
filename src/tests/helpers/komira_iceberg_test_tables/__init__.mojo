"""`komira_iceberg_test_tables`: version-2 Iceberg tables written to a local
directory the way Iceberg Java lays one out, for tests.

Test-only. `TestTable` (test_table.mojo) commits appends, position and
equality deletes and overwrites and writes the metadata, manifest lists,
manifests, data files and delete files; `orders_fixture.mojo` is the table
the Iceberg scan conformance reads. README.md says what is written and how.
"""
