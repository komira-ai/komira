"""Status codes, the credential constants, the ABI version and the two-call
buffer test of libkomira."""

# Every fallible call of the C ABI returns one of these. Zero is success and
# every failure is negative, so a caller tells "I passed NULL" from "the
# engine refused" from "my buffer is too small" by the value alone.
comptime KOMIRA_OK: Int32 = 0
"""The call succeeded."""
comptime KOMIRA_ERR_NULL_CTX: Int32 = -1
"""The context handle is NULL."""
comptime KOMIRA_ERR_NULL_ARG: Int32 = -2
"""A required pointer argument other than the context is NULL."""
comptime KOMIRA_ERR_ENGINE: Int32 = -3
"""The engine refused the request; the context's last error says why."""
comptime KOMIRA_ERR_BUFFER_TOO_SMALL: Int32 = -4
"""The caller's buffer cannot hold the output. This is a measurement, not a
failure: the required length has been stored in `*out_len` and nothing has
been written to the buffer."""
comptime KOMIRA_ERR_TOO_LARGE: Int32 = -5
"""A byte input is longer than `KOMIRA_MAX_INPUT_BYTES`. Nothing was read from
it; the context's last error says so."""
comptime KOMIRA_ERR_CANCELLED: Int32 = -6
"""The run was cancelled through the run handle it was given
(`komira_run_cancel`); the context's last error starts `QUERY_CANCELLED: `."""

comptime KOMIRA_MAX_INPUT_BYTES: UInt64 = 64 * 1024 * 1024
"""The longest byte input (the plan of `komira_plan_render`) a call accepts:
64 MiB. The library copies an input in full before decoding it, so the length
the host passes is bounded before anything is allocated; a longer one is
`KOMIRA_ERR_TOO_LARGE`. A length of exactly this many bytes is accepted."""

# A credential is defined in three calls (`komira_credential_add`, `_set`,
# `_seal`; credentials.mojo). Its kind, each field it takes and the scope it
# is sealed in are these numbers. A new kind, field or scope is a new
# constant, which raises the minor version.
comptime KOMIRA_BIND_SESSION: Int32 = 1
"""Seal a credential as the session's value of its name, until the session
is freed or the name is sealed again."""

comptime KOMIRA_CRED_AWS_KEYS: Int32 = 1
"""An AWS access key: `KEY_ID` and `SECRET`, and optionally
`SESSION_TOKEN`."""
comptime KOMIRA_CRED_AWS_PROFILE: Int32 = 2
"""A profile of the shared AWS files: `PROFILE`."""
comptime KOMIRA_CRED_GCP_SERVICE_ACCOUNT: Int32 = 3
"""A Google service-account credentials file: `FILE`."""
comptime KOMIRA_CRED_GCP_TOKEN: Int32 = 4
"""A Google OAuth access token: `TOKEN`."""
comptime KOMIRA_CRED_AZURE_KEY: Int32 = 5
"""An Azure storage account key: `ACCOUNT` and `KEY`."""
comptime KOMIRA_CRED_AZURE_SAS: Int32 = 6
"""An Azure shared access signature: `ACCOUNT` and `SAS`."""
comptime KOMIRA_CRED_BEARER: Int32 = 7
"""A bearer token: `TOKEN`."""
comptime KOMIRA_CRED_OAUTH2_CLIENT: Int32 = 8
"""OAuth2 client credentials: `CLIENT_ID` and `CLIENT_SECRET`, and
optionally `SCOPE` and `TOKEN_URL`."""

comptime KOMIRA_FIELD_KEY_ID: Int32 = 1
"""The access key id of `KOMIRA_CRED_AWS_KEYS`."""
comptime KOMIRA_FIELD_SECRET: Int32 = 2
"""The secret access key of `KOMIRA_CRED_AWS_KEYS`."""
comptime KOMIRA_FIELD_SESSION_TOKEN: Int32 = 3
"""The session token of temporary `KOMIRA_CRED_AWS_KEYS`."""
comptime KOMIRA_FIELD_PROFILE: Int32 = 4
"""The profile name of `KOMIRA_CRED_AWS_PROFILE`."""
comptime KOMIRA_FIELD_FILE: Int32 = 5
"""The credentials file path of `KOMIRA_CRED_GCP_SERVICE_ACCOUNT`."""
comptime KOMIRA_FIELD_TOKEN: Int32 = 6
"""The token of `KOMIRA_CRED_GCP_TOKEN` and `KOMIRA_CRED_BEARER`."""
comptime KOMIRA_FIELD_ACCOUNT: Int32 = 7
"""The storage account of `KOMIRA_CRED_AZURE_KEY` and `_AZURE_SAS`."""
comptime KOMIRA_FIELD_KEY: Int32 = 8
"""The account key of `KOMIRA_CRED_AZURE_KEY`."""
comptime KOMIRA_FIELD_SAS: Int32 = 9
"""The shared access signature of `KOMIRA_CRED_AZURE_SAS`."""
comptime KOMIRA_FIELD_CLIENT_ID: Int32 = 10
"""The client id of `KOMIRA_CRED_OAUTH2_CLIENT`."""
comptime KOMIRA_FIELD_CLIENT_SECRET: Int32 = 11
"""The client secret of `KOMIRA_CRED_OAUTH2_CLIENT`."""
comptime KOMIRA_FIELD_SCOPE: Int32 = 12
"""The scope `KOMIRA_CRED_OAUTH2_CLIENT` asks for."""
comptime KOMIRA_FIELD_TOKEN_URL: Int32 = 13
"""The token endpoint `KOMIRA_CRED_OAUTH2_CLIENT` exchanges at."""

# The step of the pipeline a refused call stopped at, what `komira_last_error_step`
# returns. A failure of a registration, a schema or binding read, or a
# credential call is `KOMIRA_STEP_BIND`; a refusal of `komira_sql_stream`, or of
# `komira_plan_stream` at `optimize`, `lower` or `execute`, is the step that
# refused; any other error (among them a plan refused at `decode`), and no
# error, is `KOMIRA_STEP_NONE`.
comptime KOMIRA_STEP_NONE: Int32 = 0
"""No step: there is no error, or the error belongs to no step."""
comptime KOMIRA_STEP_PARSE: Int32 = 1
"""The SQL text was refused as a statement."""
comptime KOMIRA_STEP_BIND: Int32 = 2
"""A name, a table or a credential could not be bound."""
comptime KOMIRA_STEP_OPTIMIZE: Int32 = 3
"""The optimizer refused the plan."""
comptime KOMIRA_STEP_LOWER: Int32 = 4
"""The plan could not be lowered to an executable pipeline."""
comptime KOMIRA_STEP_EXECUTE: Int32 = 5
"""The pipeline was refused or failed while it ran."""

# The ABI version is `ABI_MAJOR * 1000 + ABI_MINOR`: 1000 is 1.0 and 2003 is
# 2.3. A new symbol raises the minor version; changing or removing a symbol
# raises the major version and resets the minor to 0. The minor version stays
# below 1000 so that the integer decodes uniquely.
comptime ABI_MAJOR: Int32 = 1
"""The major version: raised by a change that breaks an existing caller."""
comptime ABI_MINOR: Int32 = 11
"""The minor version: raised by an addition that breaks no caller."""
comptime _ABI_MINOR_LIMIT: Int32 = 1000


@always_inline
def abi_version() -> Int32:
    """The version of the C ABI as `major * 1000 + minor`."""
    comptime assert ABI_MINOR >= 0 and ABI_MINOR < _ABI_MINOR_LIMIT
    return ABI_MAJOR * _ABI_MINOR_LIMIT + ABI_MINOR


@always_inline
def input_length_status(length: UInt64) -> Int32:
    """The test a byte input's length passes before it is copied in:
    `KOMIRA_ERR_TOO_LARGE` when `length` is above `KOMIRA_MAX_INPUT_BYTES`
    (which includes any length that would be negative as a signed value),
    `KOMIRA_OK` otherwise."""
    if length > KOMIRA_MAX_INPUT_BYTES:
        return KOMIRA_ERR_TOO_LARGE
    return KOMIRA_OK


@always_inline
def buffer_status(needed: Int, capacity: UInt64) -> Int32:
    """The two-call protocol's test of a caller's buffer.

    A call that returns bytes stores their count in `*out_len` first, then
    returns this: `KOMIRA_ERR_BUFFER_TOO_SMALL` when `capacity` is below
    `needed` (and writes nothing), `KOMIRA_OK` otherwise. A caller sizes its
    buffer by calling once with capacity zero.
    """
    if capacity < UInt64(needed):
        return KOMIRA_ERR_BUFFER_TOO_SMALL
    return KOMIRA_OK
