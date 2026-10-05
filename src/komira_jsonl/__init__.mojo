"""`komira_jsonl` — JSON and JSONL for the engine.

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
     `hadd_u8x16` primitive (`komira_simd.horizontal_add`, a direct
     `llvm.aarch64.neon.uaddv` intrinsic).

Columnar reading and writing: the SIMD structural index
(`structural_index`), key dispatch, typed value parsers, schema inference,
the JSONL materializer (serial and parallel), the streaming JSONL source,
the `json_extract` kernel, and the JSON / JSONL writers (`json_writer`).

Dependency direction (cycle-free):
  komira_jsonl -> the core packages (Arrow types, SIMD primitives, sources)
  komira_jsonl -> komira_async (parallel fork-join for JSONL parse)
  komira_jsonl -> komira_row_format (row-format output for the row-native writer)
"""

from komira_jsonl.json_compatible import JsonCompatible
from komira_jsonl.encode import write_record
from komira_jsonl.decode import parse_record
from komira_jsonl.schema_inference import infer_jsonl_schema

# streaming primitives for files >100MB.
from komira_jsonl.line_splitter import (
    LineSplitResult,
    split_lines_in_buffer,
    split_lines_in_buffer_with_state,
    next_newline_outside_string,
)
from komira_jsonl.streaming_source import (
    DEFAULT_CHUNK_BYTES,
    STREAMING_FILE_SIZE_THRESHOLD_BYTES,
    read_jsonl_streamed_to_batches,
    read_jsonl_streamed_to_one_batch,
)
