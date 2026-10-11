"""`komira_engine_runtime.spill`: the spill layer.

- `spill_storage`: the `SpillStorage` trait (write a chunk, read it back,
  release it) and `ChunkId`.
- `filesystem_spill_storage`: `FileSystemSpillStorage[FS]`, the storage over
  any `komira_fs` file system; `local_disk`: `LocalDiskSpillStorage`, that
  storage over the local file system, which creates its root directory.
- `thsplc_header` / `thsplc`: the column spill format (a 96-byte header,
  per-column descriptors and regions, a trailing magic) and its codec;
  `column_native_shims` bridges it to `ColumnNativeBatch`.
- `fnv1a`: the FNV-1a 64 hash and the partition schema fingerprint the spill
  formats record.

Whether a breaker may spill, and to which tiers, is decided by the host
profile (`HostProfile.spill_tiers_for`) and recorded in the physical plan."""
