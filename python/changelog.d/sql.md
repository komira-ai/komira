- **SQL.** `Session.sql(query)` runs one SQL statement over the session's registered tables and returns
  a `Result`, read once as a pyarrow `Table` (`to_arrow()`), a `RecordBatchReader` (`to_reader()`) or
  through the Arrow PyCapsule interface (`__arrow_c_stream__`, so `pyarrow.table(result)` reads it). A
  syntax error, an unknown table or a refused construct raises `KomiraError` from `sql` itself, with the
  engine's message, in the most specific subclass of `KomiraError` its refusal names: `ParseError` for
  a syntax error (and any refusal of the parse step with no other code), `BindError` for a name that does
  not resolve (and any refusal of the bind step with no other code), `UnsupportedOperation` for a
  construct refused by name, `StorageError` for a failed storage read or write (the codes
  `STORAGE_NOT_FOUND`, `STORAGE_ACCESS_DENIED`, `STORAGE_THROTTLED`, `STORAGE_TRANSPORT`,
  `STORAGE_MALFORMED`, `STORAGE_OBJECT_CHANGED`, `STORAGE_IO` and `STORAGE_REGION_UNKNOWN`) and
  `CredentialsError` for a credential the engine refuses (`CREDENTIAL_UNBOUND`,
  `CREDENTIAL_NAME_CONFLICT`, `CREDENTIAL_KIND_MISMATCH`, `CREDENTIALS_NOT_FOUND` and
  `CREDENTIALS_INVALID`; no public call takes a credential yet). A result still reads after its session is closed. `komira.Result` is a new public name; a requested
  schema on `__arrow_c_stream__` raises a `KomiraError`.
