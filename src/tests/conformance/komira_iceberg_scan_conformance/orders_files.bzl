"""The files of the table `orders` and the cases run over it.

`ORDERS_FILES` are the paths the fixture writes under its root
(komira_iceberg_test_tables, orders_fixture.mojo: `orders_files()`, which its
welded test holds equal to the files written; a path listed here that the
program does not write fails the `:orders_table` action, and one the parity
test finds in `orders_files()` but not staged fails that test);
`ORDERS_OUTPUTS` names each as a
sub-target of `:orders_table` (flat names: no `/` or `=`), and `ORDERS_INPUTS`
stages each at `orders/<path>` for an oracle or a test. `CASES` are the
`COPY` lines of oracle/cases.sql, each writing `<case>.tsv`.
"""

ORDERS_FILES = [
    "metadata/v1.metadata.json",
    "metadata/v2.metadata.json",
    "metadata/v3.metadata.json",
    "metadata/v4.metadata.json",
    "metadata/v5.metadata.json",
    "metadata/v6.metadata.json",
    "metadata/version-hint.text",
    "metadata/snap-6000000001-1-a1b2c3d4-0000-4000-8000-000000000101.avro",
    "metadata/snap-6000000002-1-a1b2c3d4-0000-4000-8000-000000000102.avro",
    "metadata/snap-6000000003-1-a1b2c3d4-0000-4000-8000-000000000103.avro",
    "metadata/snap-6000000004-1-a1b2c3d4-0000-4000-8000-000000000104.avro",
    "metadata/snap-6000000005-1-a1b2c3d4-0000-4000-8000-000000000105.avro",
    "metadata/snap-6000000006-1-a1b2c3d4-0000-4000-8000-000000000106.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000001-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000002-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000003-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000004-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000005-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000006-m0.avro",
    "metadata/a1b2c3d4-0000-4000-8000-000000000007-m0.avro",
    "data/region=east/a1.parquet",
    "data/region=west/b1.parquet",
    "data/region=north/n1.parquet",
    "data/region=east/a2.parquet",
    "data/region=east/pos_del_1.parquet",
    "data/region=east/eq_del_1.parquet",
    "data/region=east/a3.parquet",
    "data/region=west/b2.parquet",
]

def _flat(path):
    return path.replace("/", "__").replace("=", "-")

ORDERS_OUTPUTS = {_flat(f): "orders/" + f for f in ORDERS_FILES}

ORDERS_INPUTS = {"orders/" + f: ":orders_table[" + _flat(f) + "]" for f in ORDERS_FILES}

CASES = [
    "full_scan",
    "projection",
    "count_all",
    "partition_equals",
    "partition_no_match",
    "bound_greater",
    "bound_range",
    "date_range",
    "is_null",
    "is_not_null",
    "double_nan_greater",
    "double_range",
    "boolean_equals",
    "aggregate_by_region",
    "aggregate_total",
    "snapshot_two",
    "snapshot_one_west",
    "snapshot_three_ids",
    "snapshot_five_by_region",
]
