# dispatch_scan

Scan support for the engine dispatcher: whole-file decompression of compressed CSV and JSONL text, hive partition path parsing, the CSV read options of a row scan, scalar extraction from a one-column batch, plan predicates for lowering, the row-to-column re-route policy and its scan-leaf walkers, the cross-query scan dedup cache, and the UDF routing and refusal predicates.

The package has no root re-exports; import each name from its module, such as
`dispatch_scan.hive_partition_parser`.

A scan of Hive-style paths reads the `key=value` directories as partition
columns. This example parses three paths: the column types are inferred from
all of a column's values (`year` is a 64-bit integer, `day` is a date), the
values stay as raw text per path, and the file name is never read as a
partition.

```mojo
from std.testing import assert_equal, assert_true, assert_false
from arrow.arrow_types import ArrowType
from dispatch_scan.hive_partition_parser import parse_hive_partitions

var paths = List[String]()
paths.append(String("d/year=2030/day=2030-01-02/p0.parquet"))
paths.append(String("d/year=2030/day=2030-02-03/p1.parquet"))
paths.append(String("d/year=2031/day=2031-01-04/p2.parquet"))

var layout = parse_hive_partitions(paths)
assert_equal(layout.num_cols(), 2)
assert_equal(layout.cols[0].name, String("year"))
assert_true(layout.cols[0].arrow_type == ArrowType.INT64)
assert_equal(layout.cols[1].name, String("day"))
assert_true(layout.cols[1].arrow_type == ArrowType.DATE32)
assert_false(layout.cols[0].nullable)
assert_equal(len(layout.values), 3)
assert_equal(layout.values[2][0], String("2031"))
assert_equal(layout.values[1][1], String("2030-02-03"))
```
