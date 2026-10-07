# =============================================================================
# komira_plan_expr.fs_descriptor_pod — the core packages identity POD for a
# per-source filesystem, type-erased from the concrete FS type.
# =============================================================================
#
# WHY A POD (the layering rule):
#   The plan node that must carry FS identity — `ParquetSourceData`
#   (`komira_plan_ir.physical_plan`) — lives in `komira_plan_expr`, the package
#   every FS package DEPENDS ON. Core therefore CANNOT name a concrete FS type
#   (`LocalFs` / `S3Fs[C]` / `GcsFs[C]` / `AzureFs[C]`) without inverting the
#   dependency graph. So the plan node carries an FS-DESCRIPTOR POD: a pure
#   IDENTITY value (scheme + bucket/container + a stable `node_id`) — NO FS
#   type named. The LIVE FsHandle lives in the upper-layer `komira_fs_registry`
#   side table, paired to this POD by `node_id` at materialize time. This is
#   the same shape as `PartitionPredicatePod`
#   (`komira_plan_expr/partition_pred_pod.mojo`) — a core-resident
#   structural identity whose live counterpart resolves in an upper layer.
#
# Pointer discipline:
#   * Copyable + Movable + Deinitable. Owns only `UInt8` + `String`
#     + `Int`. NO OwnedPointer, NO ArcPointer, NO wildcard origin, NO
#     UnsafePointer in any signature, NO fn-ptr-callback.
#   * This POD rides on the plan node (`ParquetSourceData`) BY VALUE — it is
#     NEVER an element of a byte-slab — so the stale-bytes hazard of heap
#     data inside a byte slab does not apply. Identical safety posture to
#     `PartitionPredicatePod`.
# =============================================================================


# Scheme codes — the URI scheme the descriptor identifies. The registry maps a
# scheme + node_id to the matching `FsHandle` arm. These are stable wire
# constants; the engine resolver branches on them (and on `FsHandle.tag`,
# which is kept byte-identical to these in `komira_fs_registry`).
comptime FS_SCHEME_FILE: UInt8 = 0  # local POSIX ("file://" / bare path)
comptime FS_SCHEME_S3: UInt8 = 1  # AWS S3 ("s3://")
comptime FS_SCHEME_GCS: UInt8 = 2  # Google Cloud Storage ("gs://")
comptime FS_SCHEME_AZURE: UInt8 = 3  # Azure Blob ("az://" / "abfss://")


@fieldwise_init
struct FsDescriptorPod(Copyable, Movable, Deinitable):
    """The core packages identity POD for a per-source filesystem.

    A pure identity value carried on the plan node (`ParquetSourceData`). It
    names NO concrete FS type — the live `FsHandle` lives in the upper-layer
    `komira_fs_registry` side table and is paired to this POD by `node_id` at
    materialize time.

    Owns only `UInt8` + `String` + `Int`, so there is no stale-pointer hazard.
    Rides on the plan node by value; never a byte-slab element. Same safety
    posture as `PartitionPredicatePod`.
    Field contract:
      * `scheme`  — one of `FS_SCHEME_*` (UInt8). The URI scheme identifying
                    which FS arm the registry must resolve. The registry keeps
                    `FsHandle.tag` byte-identical to these scheme codes.
      * `bucket`  — the bucket (S3 / GCS) or container (Azure) name. EMPTY for
                    local (`FS_SCHEME_FILE`).
      * `node_id` — a STABLE per-source id minted when the scan node is built.
                    The key the registry side table is indexed by. The default
                    descriptor (`local()`) uses `node_id = -1` ("no explicit
                    binding"; resolves to the local default).
    """

    var scheme: UInt8
    var bucket: String
    var node_id: Int

    @staticmethod
    def local() -> FsDescriptorPod:
        """The default local descriptor. `scheme = FILE`, empty bucket,
        `node_id = -1` ("no explicit FS binding"). A `ParquetSourceData` with
        this descriptor resolves to the local default resolver (a single
        `LocalFs`)."""
        return FsDescriptorPod(
            scheme=FS_SCHEME_FILE, bucket=String(""), node_id=-1
        )

    @staticmethod
    def cloud(scheme: UInt8, bucket: String, node_id: Int) -> FsDescriptorPod:
        """A cloud-source descriptor: `scheme` in {S3, GCS, AZURE}, a bucket /
        container name, and the stable `node_id` the registry is keyed by."""
        return FsDescriptorPod(scheme=scheme, bucket=bucket, node_id=node_id)

    @always_inline
    def is_local(self) -> Bool:
        """True for the local-default descriptor (no explicit FS binding)."""
        return self.scheme == FS_SCHEME_FILE and self.node_id < 0

    @always_inline
    def has_binding(self) -> Bool:
        """True if this descriptor carries an explicit registry binding (a
        non-negative `node_id`). The engine resolver consults the registry only
        when this is True; otherwise it uses the local default."""
        return self.node_id >= 0
