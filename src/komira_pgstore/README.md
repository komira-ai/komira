# komira_pgstore

A Postgres-style table store on a conditional-write object store: a key -> row MVCC store whose write-ahead log is the CAS manifest of `komira_objectstore`, with optimistic-concurrency commits, recovery on open, group commit and a key-partitioned router.
