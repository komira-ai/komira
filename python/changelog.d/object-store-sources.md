- **Parquet on S3 and Azure Blob, with named credentials.** `Session.add_sql_binding(name, source)`
  binds a SQL name to a `komira.files(location, *, credential=AMBIENT, endpoint=None, region=None,
  url_style=None)` source, and `sql` reads it as a table: one object or a glob of Parquet objects of
  `s3://` (read with `AwsKeys` and a `region`) or of `az://`, `abfs://` and `abfss://` (read with
  `AzureKey` or `AzureSas`), or a local Parquet file. The credential kinds are public: `AwsKeys`,
  `AwsProfile`, `GcpServiceAccount`, `GcpToken`, `AzureKey`, `AzureSas`, and the built-in `AMBIENT`
  and `ANONYMOUS`. A credential has a name; binding seals its value on the session under that name,
  and the library is given only the name to bind. A secret is never in a log record, an error
  message or a `repr` (which shows it as `<set>`), and a credential or a source refuses `pickle` and
  `copy`. What the engine does not read yet is refused by name when the source is bound: `gs://`
  locations, `AMBIENT` on an object store, `ANONYMOUS` and `AwsProfile` on `s3://`. Needs the
  library of this release (ABI 1.10).
