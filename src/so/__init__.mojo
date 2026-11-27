"""`so` -- the C ABI of komira's one shared library, `libkomira`.

- `status.mojo`: the status codes every fallible call returns (`KOMIRA_OK`
  and the six negative `KOMIRA_ERR_*` codes), the steps of an error
  (`KOMIRA_STEP_*`), the credential kinds, fields
  and scope (`KOMIRA_CRED_*`, `KOMIRA_FIELD_*`, `KOMIRA_BIND_SESSION`), the
  ABI version
  (`abi_version`, `ABI_MAJOR`, `ABI_MINOR`), `buffer_status`, the test the
  two-call output protocol applies to a caller's buffer, and
  `input_length_status`, the bound on a byte input (`KOMIRA_MAX_INPUT_BYTES`).
- `session.mojo`: `Session`, the state behind a context handle,
  `try_new_session`, the session `komira_ctx_new` hands out or None, and
  `session_options`, the engine options of `komira_ctx_new_with_options`'s
  two `int64_t` arguments (0 is the host's own value), `error_code` (the code
  of an error reason) and `step_number` (the number of a step name). A session
  holds the last error (text, step and code), the engine (`sdk_exec`'s `EngineContext`) whose
  catalog holds the registered tables, the credentials, and the object
  stores its bound tables read (`BoundStores`, `bound_store.mojo`: the bucket,
  the credential's NAME and the settings, never a value).
- `bindings.mojo`: `add_sql_binding`, what `komira_add_sql_binding` does on
  values: a SQL name bound to a `komira.plan.v1.WireBoundSource` (a local
  path, or Parquet objects of an `s3://` or `az://` location read with a
  credential sealed on the session), replacing any table of that name, and
  its refusals (`BIND_*`, `STORAGE_*`, `CREDENTIAL*`); `add_sql_binding_with`
  is the same over a caller's connectors; `store_opener` builds the file
  systems a statement reads the bound stores through; `forget_table` drops a
  table and its traces.
- `store_fs.mojo`: `StoreFs`, one object-store file system (an S3 bucket or
  an Azure container), `StoreScanFs`, the opener a run reads every bound
  bucket through, and `StoreConnectors`, the connector factories and clock
  they dial and sign with (`kernel_store_connectors`: http_client's).
- `credentials.mojo`: `SessionCredentials`, a session's credentials by name:
  defined in three steps (`add`, `set`, `seal`), held in a
  `SessionSecretStore` (`credential_store.mojo`) and read back only through a
  reveal of `secret_bindings` over `secret_store`.
- `sources.mojo`: what the source and render exports do on values:
  `register_parquet` (replacing a table of its name), `register_csv`,
  `register_json`, `register_arrow`
  (a table already in memory, replacing one of its name) and its name check
  `check_table_name`,
  `parquet_schema_bytes`, `csv_binding_bytes`,
  `json_binding_bytes`, `plan_render_text`, `sql_result`, the answer of
  one SQL statement as batches ready for the Arrow C stream (`sql_result_with`
  over a caller's connectors), and
  `plan_result`, the answer of a serialized plan run with no SQL front end
  (`STEP_DECODE` names its decode step).

`_c_abi.mojo` is the library's C surface (`komira_abi_version`,
`komira_ctx_new`, `komira_ctx_new_with_options`, `komira_ctx_free`, `komira_last_error`, `komira_last_error_code`, `komira_last_error_step`, the source and
render calls, the three credential calls, `komira_sql_stream`,
`komira_register_csv` and `komira_register_json`, the four run-control
calls, `komira_sql_stream_run`, `komira_plan_stream`, `komira_register_arrow_stream`
and `komira_add_sql_binding`). It is the one file that holds pointers and is not part of this
Mojo package; `libkomira` is built from it by the `libkomira` target.
"""

from .bindings import (
    BIND_SCOPE_NOT_A_TABLE,
    BIND_SCOPE_UNSUPPORTED,
    BIND_SOURCE_MALFORMED,
    BIND_SOURCE_UNSUPPORTED,
    BIND_STORE_CONFLICT,
    CREDENTIALS_NOT_FOUND,
    CREDENTIAL_KIND_MISMATCH,
    STORAGE_REGION_UNKNOWN,
    STORAGE_URL_REFUSED,
    add_sql_binding,
    add_sql_binding_with,
    forget_table,
    store_opener,
)
from .bound_store import BoundStore, BoundStores
from .credential_store import SessionSecretStore
from .credentials import (
    CREDENTIALS_INVALID,
    CREDENTIAL_UNBOUND,
    SessionCredentials,
)
from .session import (
    Session,
    error_code,
    session_options,
    step_number,
    try_new_session,
)
from .sources import (
    QUERY_CANCELLED,
    TABLE_TYPE_UNSUPPORTED,
    check_table_name,
    csv_binding_bytes,
    STEP_DECODE,
    is_cancelled_error,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    plan_result,
    register_arrow,
    register_csv,
    register_json,
    register_parquet,
    sql_result,
    sql_result_with,
)
from .store_fs import (
    KernelStoreConnectors,
    StoreConnectors,
    StoreFile,
    StoreFs,
    StoreScanFs,
    StoreWriteFile,
    kernel_store_connectors,
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
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_EXECUTE,
    KOMIRA_STEP_LOWER,
    KOMIRA_STEP_NONE,
    KOMIRA_STEP_OPTIMIZE,
    KOMIRA_STEP_PARSE,
    abi_version,
    buffer_status,
    input_length_status,
)
