# Arrow IPC fixtures

Every `.arrow` and `.tensor` file here was written by pyarrow 24.0.0 with the
script next to it, and is committed byte for byte as that script wrote it. Do
not edit or regenerate one in place: a test that compares against a third-party
producer is only worth something while the bytes are the producer's.

| files | script | format |
|---|---|---|
| `interop_*.arrow` (12 files) | `gen_pyarrow_interop_fixtures.py` | Arrow IPC File (`ARROW1` magic, Footer) |
| `schema_only.arrow`, `schema_record_batch.arrow`, `view_types_*.arrow`, `primitives_int_float.arrow`, `temporal_batch.arrow`, `decimal128_batch.arrow`, `dict_delta_stream.arrow`, `dict_replacement_stream.arrow` | `gen_fixtures.py` | Arrow IPC stream (Schema first, EOS last) |
| `arrow_file.arrow` | `gen_fixtures.py` | Arrow IPC File |
| `tensor_1d_int64.tensor` | `gen_fixtures.py` | one Tensor message (needs numpy) |

To regenerate, run the script from this directory with pyarrow installed
(`python3 gen_fixtures.py [name ...]`, `python3 gen_pyarrow_interop_fixtures.py`).
Both are deterministic. A regenerated file that differs from the committed one
means the producer changed; review the diff before replacing it.

`dict_replacement_stream.arrow` holds no replacement DictionaryBatch: its two
batches carry equal dictionaries, so pyarrow writes one isDelta=false
DictionaryBatch and does not re-emit it. Replacement semantics are exercised
only on a komira-written stream (`test_ipc_file_e2e_write.mojo`).

The tests that read these files spell the expected values out independently,
from the closed forms in the scripts, never from komira's own decode:
`test_arrow_ipc_pyarrow_parity.mojo`, `test_ipc_encoder_dispatch.mojo` and the
`test_ipc_file_e2e_*.mojo` files.
