# komira_table_store

A table store on a conditional-write object store: a key -> row MVCC store whose write-ahead log is the CAS manifest of `komira_objectstore`, with optimistic-concurrency commits, recovery on open, group commit and a key-partitioned router.

This package was named `komira_pgstore`. It was renamed because the old name said Postgres, and the package does not parse SQL and does not speak the Postgres protocol. A SQL layer can be built on it as a consumer; none is part of this package.

## Postgres statements that remain

The code still mentions Postgres in a few places. Each one is a statement about Postgres semantics that this store matches, or a contrast with Postgres, and each one is true:

- Isolation is snapshot isolation with first-committer-wins conflict detection. Write skew is admitted and lost updates are not, which is the anomaly profile of Postgres `REPEATABLE READ` (`test_table_store_si_occ_property.mojo` has a write-skew witness and an N-writer first-committer-wins check).
- A commit that loses a conflict raises an error carrying the token `OCC_CONFLICT 40001`. `40001` is the Postgres SQLSTATE for `serialization_failure`, so a SQL layer can pass it through unchanged.
- There is no cross-shard unique check. The design requires a unique key on a partitioned table to include the shard key (a SQL layer enforces that at DDL), so uniqueness is checked within one shard. Postgres has the same rule for unique constraints on partitioned tables.
- A cross-shard range scan returns rows in no particular order between shards. A correct Postgres application cannot depend on row order without `ORDER BY` either.
- The parkable commit is asynchronous I/O and still waits for the commit to be durable before acknowledging it. It is not Postgres's relaxed-durability `synchronous_commit = off`.

The commit-chunk magic is `PGC`. It is part of the on-disk format and is kept so that existing logs still decode.
