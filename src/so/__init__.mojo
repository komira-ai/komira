"""`so` -- the C ABI of komira's one shared library, `libkomira`.

- `status.mojo`: the status codes every fallible call returns (`KOMIRA_OK`
  and the six negative `KOMIRA_ERR_*` codes), the credential kinds, fields
  and scope (`KOMIRA_CRED_*`, `KOMIRA_FIELD_*`, `KOMIRA_BIND_SESSION`), the
  ABI version
  (`abi_version`, `ABI_MAJOR`, `ABI_MINOR`), `buffer_status`, the test the
  two-call output protocol applies to a caller's buffer, and
  `input_length_status`, the bound on a byte input (`KOMIRA_MAX_INPUT_BYTES`).
- `session.mojo`: `Session`, the state behind a context handle,
  `try_new_session`, the session `komira_ctx_new` hands out or None, and
  `session_options`, the engine options of `komira_ctx_new_with_options`'s
  two `int64_t` arguments (0 is the host's own value). A session holds the
  text of the last error, the engine (`sdk_exec`'s `EngineContext`) whose
  catalog holds the registered tables, and the credentials.
- `credentials.mojo`: `SessionCredentials`, a session's credentials by name:
  defined in three steps (`add`, `set`, `seal`), held in a
  `SessionSecretStore` (`credential_store.mojo`) and read back only through a
  reveal of `secret_bindings` over `secret_store`.
- `sources.mojo`: what the source and render exports do on values:
  `register_parquet`, `register_csv`, `register_json`,
  `parquet_schema_bytes`, `csv_binding_bytes`,
  `json_binding_bytes`, `plan_render_text` and `sql_result`, the answer of
  one SQL statement as batches ready for the Arrow C stream.

`_c_abi.mojo` is the library's C surface (`komira_abi_version`,
`komira_ctx_new`, `komira_ctx_new_with_options`, `komira_ctx_free`, `komira_last_error`, the source and
render calls, the three credential calls, `komira_sql_stream`,
`komira_register_csv` and `komira_register_json`, the four run-control
calls and `komira_sql_stream_run`). It is the one file that holds pointers and is not part of this
Mojo package; `libkomira` is built from it by the `libkomira` target.
"""

from .credential_store import SessionSecretStore
from .credentials import (
    CREDENTIALS_INVALID,
    CREDENTIAL_UNBOUND,
    SessionCredentials,
)
from .session import Session, session_options, try_new_session
from .sources import (
    QUERY_CANCELLED,
    csv_binding_bytes,
    is_cancelled_error,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    register_csv,
    register_json,
    register_parquet,
    sql_result,
)
from .status import (
    ABI_MAJOR,
    ABI_MINOR,
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_CRED_AWS_PROFILE,
    KOMIRA_CRED_AZURE_KEY,
    KOMIRA_CRED_AZURE_SAS,
    KOMIRA_CRED_BEARER,
    KOMIRA_CRED_GCP_SERVICE_ACCOUNT,
    KOMIRA_CRED_GCP_TOKEN,
    KOMIRA_CRED_OAUTH2_CLIENT,
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_CANCELLED,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_FIELD_ACCOUNT,
    KOMIRA_FIELD_CLIENT_ID,
    KOMIRA_FIELD_CLIENT_SECRET,
    KOMIRA_FIELD_FILE,
    KOMIRA_FIELD_KEY,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_PROFILE,
    KOMIRA_FIELD_SAS,
    KOMIRA_FIELD_SCOPE,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_SESSION_TOKEN,
    KOMIRA_FIELD_TOKEN,
    KOMIRA_FIELD_TOKEN_URL,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    abi_version,
    buffer_status,
    input_length_status,
)
