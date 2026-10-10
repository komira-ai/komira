"""`komira_formats_e2e` -- one dataset, four file formats, one Hive tree on the
local disk, read back through discovery and projection; the same dataset as an
Arrow IPC File and Stream.

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

`ipc_assembly.mojo` strings komira_arrow_ipc's message encoders into an
Arrow IPC File or Stream (`IpcAssembly`, `write_ipc`): komira ships the
encoders and framing pieces, not a file or stream writer.

The numeric edge fixture is separate: `edge_numerics.mojo` (integer limits
and IEEE-754 edge values, each float given by its bit pattern, with the
expected text spelled by hand) and `edge_checks.mojo` (collect-every-
mismatch checks and byte builders for the edge tests).
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
from .ipc_assembly import IpcAssembly, write_ipc
from .hive_tree import (
    format_exts,
    partition_dir,
    file_path,
    write_file_bytes,
    write_hive_tree,
)
from .edge_numerics import (
    NUM_INT_EDGE_ROWS,
    NUM_FLOAT_EDGE_ROWS,
    F_NEG_ZERO,
    F_POS_INF,
    F_NEG_INF,
    F_NAN,
    F_NAN_PAYLOAD,
    F_NEG_NAN,
    int64_edges,
    int32_edges,
    int64_edge_text,
    int32_edge_text,
    float_edge_bits,
    float_edge_text,
    is_finite_row,
    f64_of,
    bits_of,
    int_edge_batch,
    float_batch_of_bits,
    float_edge_batch,
)
from .edge_checks import (
    Mismatches,
    hex_u64,
    hex_of,
    le_bytes,
    be_bytes,
    hex_bytes,
    same_bytes,
    check_bytes,
    is_nan_bits,
    column_index,
    check_int_column,
    check_float_column_bits,
)
