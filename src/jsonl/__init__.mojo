"""`jsonl` — JSON and JSONL for the engine.

Record-level codec:

  1. `JsonCompatible` trait — the instance-form serde contract, the JSON
     counterpart of `ArrowCompatible`. The trait carries no default impl
     bodies; each conformer writes a hand-keyed `to_json` / `from_json`
     body that drives the per-field cascade from
     `reflect[Self]().field_names()` / `reflect[Self]().field_types()`.

  2. `encode.write_record[T: JsonCompatible](out buf: List[UInt8], rec: T)`
     — JSONL encoder. Appends `rec.to_json() + "\\n"` to `buf`. Newline-
     delimited JSON (JSONL / ndjson): one record per line, trailing `\\n`
     on every line including the last (yyjson / DuckDB convention).

  3. `decode.parse_record[T: JsonCompatible](bytes: Span[UInt8, _]) -> T`
     — per-line parser. The structural-character scan uses the
     `hadd_u8x16` primitive (`simd_ops.horizontal_add`, a direct
     `llvm.aarch64.neon.uaddv` intrinsic).

Columnar reading and writing: key dispatch, typed value parsers, schema
inference, the JSONL materializer (serial and parallel), the streaming JSONL
source, and the JSON / JSONL writers (`json_writer`). The SIMD structural
index and the `json_extract` kernel live in `json_index`.

Dependency direction (cycle-free):
  jsonl -> the core packages (Arrow types, SIMD primitives, sources)
  jsonl -> json_index (structural index, input limits, string unescaper)
  jsonl -> async_rt (parallel fork-join for JSONL parse)
  jsonl -> row_format (row-format output for the row-native writer)
"""

from jsonl.json_compatible import JsonCompatible
from jsonl.encode import write_record
from jsonl.decode import parse_record
from jsonl.schema_inference import infer_jsonl_schema

# streaming primitives for files >100MB.
from jsonl.line_splitter import (
    LineSplitResult,
    split_lines_in_buffer,
    split_lines_in_buffer_with_state,
    next_newline_outside_string,
)
from jsonl.streaming_source import (
    DEFAULT_CHUNK_BYTES,
    STREAMING_FILE_SIZE_THRESHOLD_BYTES,
    read_jsonl_streamed_to_batches,
    read_jsonl_streamed_to_one_batch,
)
