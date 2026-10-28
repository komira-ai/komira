"""`komira_so` -- the C ABI of komira's one shared library, `libkomira`.

- `status.mojo`: the status codes every fallible call returns (`KOMIRA_OK`
  and the five negative `KOMIRA_ERR_*` codes), the ABI version
  (`abi_version`, `ABI_MAJOR`, `ABI_MINOR`), `buffer_status`, the test the
  two-call output protocol applies to a caller's buffer, and
  `input_length_status`, the bound on a byte input (`KOMIRA_MAX_INPUT_BYTES`).
- `session.mojo`: `Session`, the state behind a context handle: the text of
  the last error and the catalog of registered tables.
- `sources.mojo`: what the source and render exports do on values:
  `register_parquet`, `parquet_schema_bytes`, `csv_binding_bytes`,
  `json_binding_bytes` and `plan_render_text`.

`_c_abi.mojo` is the library's C surface (`komira_abi_version`,
`komira_ctx_new`, `komira_ctx_free`, `komira_last_error` and the source and
render calls). It is the one file that holds pointers and is not part of this
Mojo package; `libkomira` is built from it by the `libkomira` target.
"""

from .session import Session
from .sources import (
    csv_binding_bytes,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    register_parquet,
)
from .status import (
    ABI_MAJOR,
    ABI_MINOR,
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    abi_version,
    buffer_status,
    input_length_status,
)
