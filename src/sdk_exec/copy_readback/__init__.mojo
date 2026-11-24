"""`copy_readback`: the checks of the pinned DuckDB reading back the Parquet,
CSV and JSON files `run_sql`'s COPY writes (`:copy_komira`, `:copy_readback_oracle` in
src/sdk_exec/BUCK).

Test-only; nothing depends on it. It is a library of its own, not part of
`sdk_exec`, because its test's data is built by a program that depends on
`sdk_exec`: as test data of `sdk_exec` that would be a dependency cycle.
`checks.mojo` reads the files the build actions wrote.
"""
