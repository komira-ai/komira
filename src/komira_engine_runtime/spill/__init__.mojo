"""`komira_engine_runtime.spill`: the spill layer.

- `spill_storage`: the `SpillStorage` trait (write a chunk, read it back,
  release it) and `ChunkId`.
- `filesystem_spill_storage`: `FileSystemSpillStorage[FS]`, the storage over
  any `komira_fs` file system; `local_disk`: `LocalDiskSpillStorage`, that
  storage over the local file system, which creates its root directory.
- `thsplc_header` / `thsplc`: the column spill format (a 96-byte header,
  per-column descriptors and regions, a trailing magic) and its codec;
  `column_native_shims` bridges it to `ColumnNativeBatch`.
- `thspill2_header` / `thspill2`: the opaque-body spill format for breaker
  state (`Spillable`) and its codec.
- `native_spill`: a writer and reader of record-batch runs (column format) and
  row bodies (row format) over local-disk spill storage.
- `spillable_op`: the `SpillableOp` trait a spill-capable breaker conforms
  to; `policies`: the victim-pick policy (OLDEST_FIRST is implemented).
- `spill_arbitrator`: `SpillArbitrator[S, *Ops]`, one budget over a fixed
  pack of breakers; `intra_op_slab_arbitrator`: one breaker's partitions
  under its budget; `op_coordinator`: a breaker's partitions presented as one
  `SpillableOp` to the cross-breaker arbitrator; `routed_grow`: a grow that
  spills one of the breaker's own partitions when its reservation denies.
- `shuffle_combine_buffer` / `shuffle_stream_combine`: the shuffle
  producer's per-partition encode buffer and the streaming combine of its
  partitions into one `.seg` object, spilling a hot partition past a
  threshold.
- `fnv1a`: the FNV-1a 64 hash and the partition schema fingerprint the spill
  formats record.

Whether a breaker may spill, and to which tiers, is decided by the host
profile (`HostProfile.spill_tiers_for`) and recorded in the physical plan."""
