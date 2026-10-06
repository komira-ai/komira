"""`komira_formats_e2e` -- one dataset, four file formats, one Hive tree on the
local disk, read back through discovery and projection.

This package exists for its tests. Its sources are the shared fixture:

- `dataset.mojo`: the source dataset, ten rows of `id` (INT64), `score`
  (FLOAT64), `name` (STRING) and `flag` (BOOL), every column nullable with a
  NULL at known rows, `name` holding 2-, 3- and 4-byte UTF-8, an empty
  string, and each CSV quoting trigger (comma, leading quote, LF, CR) alone
  in one value plus a CRLF inside a field; each row's `city` partition
  (`Zürich` or `Oslo`); and `batch_for_city`, the rows of one partition as a
  `RecordBatch`.
- `hive_tree.mojo`: `write_hive_tree(root)`, which writes each partition's
  batch through the four writers (ORC `write_orc_file`, Avro OCF
  `write_avro_file`, JSONL `write_batch_jsonl_direct`, CSV `CsvSink`) into
  `<root>/city=<value>/part-0.<ext>`, the partition value spelled as raw UTF-8
  bytes in the directory name, the way Spark and Hive write it.

The tests (`tests/`) discover the tree over the real `LocalFs` with
`EagerGlobDiscovery` and `PrunedHiveDiscovery`, read every file back with a
projection in a different column order, comparing values, NULLs and the
partition value with the dataset above, and pin the writers' bytes against
literals spelled from the format specs (the oracle a writer/reader
self-round-trip lacks). Nothing here is shipped (`conda = False`).
"""

from .dataset import (
    NUM_ROWS,
    city_zurich,
    city_oslo,
    cities,
    row_city,
    rows_of,
    id_at,
    score_at,
    name_at,
    flag_at,
    batch_for_city,
)
from .hive_tree import (
    format_exts,
    partition_dir,
    file_path,
    write_file_bytes,
    write_hive_tree,
)
