"""`komira_engine_runtime.spill`: the spill layer.

- `spill_storage`: the `SpillStorage` trait (write a chunk, read it back,
  release it) and `ChunkId`.
- `filesystem_spill_storage`: `FileSystemSpillStorage[FS]`, the storage over
  any `komira_fs` file system; `local_disk`: `LocalDiskSpillStorage`, that
  storage over the local file system, which creates its root directory.
- `fnv1a`: the FNV-1a 64 hash and the partition schema fingerprint the spill
  formats record and checksum with.
- `thsplc` and `thsplc_header`: the THSPLC column codec for a RecordBatch.
- `column_native_shims`: the bridges between RecordBatch and
  ColumnNativeBatch.
- `thspill2_header` / `thspill2`: the opaque-body spill format for breaker
  state (`Spillable`) and its codec.
- `native_spill`: a writer and reader of record-batch runs (column format) and
  row bodies (row format) over local-disk spill storage.
- `policies`, `spillable_op`, `spill_arbitrator`, `intra_op_slab_arbitrator`,
  `op_coordinator`, `routed_grow`: which breaker or partition spills under
  memory pressure. `SpillableOp` is what a breaker exposes (resident bytes,
  age, whether it may spill, spill, restore). `SpillArbitrator` picks the
  oldest spillable op from a fixed pack of ops of different types;
  `IntraOpSlabArbitrator` does so over one operator's partitions in a
  caller-owned slab; `SpillableOpCoordinator` presents one operator as a
  single `SpillableOp`; `try_grow_intra_op_routed` grows a
  `MemoryReservation` and, when it refuses, spills one of the breaker's own
  partitions and retries once. Only the oldest-first policy runs.

Whether a breaker may spill, and to which tiers, is decided by the host
profile (`HostProfile.spill_tiers_for`) and recorded in the physical plan."""
