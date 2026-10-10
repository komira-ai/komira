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
#   type named. It names the exact source the scan reads: a surface maps the
#   source URL's prefix to the scheme code (komira_source_url) before it
#   builds the plan, and the file system that reads the source is the one
#   whose `SCHEME` is that code. This is the same shape as
#   `PartitionPredicatePod` (`komira_plan_expr/partition_pred_pod.mojo`) — a
#   core-resident structural identity whose live counterpart is an upper
#   layer's.
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


# Scheme codes — the URI scheme the descriptor identifies, and the `SCHEME`
# each file system advertises (komira_source_url's test_source_scheme_agrees
# holds the two together). These are stable wire constants.
comptime FS_SCHEME_FILE: UInt8 = 0  # local POSIX ("file://" / bare path)
comptime FS_SCHEME_S3: UInt8 = 1  # AWS S3 ("s3://")
comptime FS_SCHEME_GCS: UInt8 = 2  # Google Cloud Storage ("gs://")
comptime FS_SCHEME_AZURE: UInt8 = 3  # Azure Blob ("az://" / "abfss://")


@fieldwise_init
struct FsDescriptorPod(Copyable, Movable, Deinitable):
    """The core packages identity POD for a per-source filesystem.

    A pure identity value carried on the plan node (`ParquetSourceData`). It
    names the source and NO concrete FS type: the file system that reads it
    is the one whose `SCHEME` is `scheme`.

    Owns only `UInt8` + `String` + `Int`, so there is no stale-pointer hazard.
    Rides on the plan node by value; never a byte-slab element. Same safety
    posture as `PartitionPredicatePod`.
    Field contract:
      * `scheme`  — one of `FS_SCHEME_*` (UInt8). The URI scheme identifying
                    which file system reads the source
                    (komira_source_url's `check_source_descriptor` refuses
                    any other code).
      * `bucket`  — the bucket (S3 / GCS) or container (Azure) name. EMPTY for
                    local (`FS_SCHEME_FILE`).
      * `node_id` — a STABLE per-source id minted when the scan node is built.
                    The key `FsBindings` is indexed by. The default
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
        container name, and the stable `node_id` `FsBindings` is keyed by."""
        return FsDescriptorPod(scheme=scheme, bucket=bucket, node_id=node_id)

    @always_inline
    def is_local(self) -> Bool:
        """True for the local-default descriptor (no explicit FS binding)."""
        return self.scheme == FS_SCHEME_FILE and self.node_id < 0

    @always_inline
    def has_binding(self) -> Bool:
        """True if this descriptor carries an explicit binding (a
        non-negative `node_id`); otherwise it is the local default."""
        return self.node_id >= 0
