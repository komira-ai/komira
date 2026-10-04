# komira_table_store

A table store on a conditional-write object store: a key -> row MVCC store whose write-ahead log is the CAS manifest of `komira_objectstore`, with optimistic-concurrency commits, recovery on open, group commit and a key-partitioned router.

This package was named `komira_pgstore`. It was renamed because the old name said Postgres, and the package does not parse SQL and does not speak the Postgres protocol. A SQL layer can be built on it as a consumer; none is part of this package.

## Postgres references that remain

The package's identifiers carry no `Pg`/`PG_` prefix; the old ones were renamed to `TableStore*` (types) and `TS_*` (constants). What still refers to Postgres is listed here, all of it. Each item is a true statement about Postgres semantics that this store matches, or a contrast with Postgres:

- `table_store.mojo`: a commit that loses a conflict raises an error carrying the token `OCC_CONFLICT 40001` (`OCC_CONFLICT_TOKEN`). `40001` is the Postgres SQLSTATE for `serialization_failure`, so a SQL layer can pass it through unchanged.
- `table_store.mojo`: a unique-constraint violation raises an error carrying the token `UNIQUE_VIOLATION 23505` (`UNIQUE_VIOLATION_TOKEN`). `23505` is the Postgres SQLSTATE for `unique_violation`. The unique-index test (`tests/test_table_store_unique_index.mojo`) asserts both codes.
- `table_store.mojo`: the parkable commit is asynchronous I/O and still waits for the commit to be durable before acknowledging it. The comment says it is not Postgres's relaxed-durability asynchronous commit (`synchronous_commit = off`).
- `partitioned_table_store.mojo`: a cross-shard scan returns rows in no particular order between shards. The docstring notes that a correct Postgres application cannot depend on row order without `ORDER BY` either.
- `partitioned_table_store.mojo`: there is no cross-shard unique check. A unique key on a partitioned table must include the shard key (a SQL layer enforces that at DDL), so uniqueness is checked within one shard. The comment records this as matching Postgres, which has the same rule for unique constraints on partitioned tables.

One more property is stated here and not in the code: isolation is snapshot isolation with first-committer-wins conflict detection, so write skew is admitted and lost updates are not. That is the anomaly profile of Postgres `REPEATABLE READ` (`tests/test_table_store_si_occ_property.mojo` has a write-skew witness and an N-writer first-committer-wins check).

## The `PGC` magic

Every commit chunk starts with the magic bytes `PGC` followed by an ASCII format-version digit (`PGC2`, `PGC3`). The bytes are part of the on-disk format and are unchanged, so existing logs still decode. Only the constants' names changed (`TS_COMMIT_MAGIC_PREFIX`, `TS_COMMIT_MAGIC`, `TS_COMMIT_MAGIC_V3` in `table_store_codec.mojo`); their values are the same. The comments and error messages that describe the format still spell the bytes `PGC`, because that is what is on disk.
