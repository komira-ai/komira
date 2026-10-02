# =============================================================================
# komira_objectstore_gcs/backend.mojo
#   GcsStorageBackend — the narrow object-verb seam the GCS conformers
#   (GcsConditionalStore, GcsFs) are generic over, and its value carriers.
# =============================================================================
#
# WHY A SEAM. `GcsConditionalStore[B]` and `GcsFs[B]` are generic over exactly
# one parameter, `B: GcsStorageBackend`. A production backend (google.storage.v2
# over gRPC) carries its own transport generic; the seam does not, so that
# generic terminates at the backend and never reaches the conformers above it.
# The same conformers run hermetically over `FakeGcsStorageBackend`
# (fake_backend.mojo), with no socket.
#
# THE VERB SET — the google.storage.v2 object verbs the ConditionalWriteStore
# lifecycle and the FileSystem read path need:
#   * conditional_create(bucket, key, data) -> generation
#       (WriteObject if_generation_match=0; create-if-absent)
#   * compare_and_swap(bucket, key, data, expected_gen) -> generation
#       (WriteObject if_generation_match=<gen>)
#   * read_range(bucket, key, offset, limit) -> bytes
#       (ReadObject; limit=0 means "to end", the full-object get)
#   * get_object(bucket, key) -> ObjectMetaRaw   (GetObject; metadata)
#   * delete_object(bucket, key)                 (DeleteObject)
#   * list_objects(bucket, prefix, page_token, delimiter) -> ListPageRaw
#       (ListObjects, one page)
#
# THE CAS HANDLE. GCS's version handle is the integer GENERATION. At this seam
# it is an Int64; the conversion to and from the trait's opaque String handle
# lives in the conformer (conditional_store.mojo).
#
# ERROR CONTRACT. Every backend raises `StoreError[<KIND>] <method>
# gs://<bucket>/<key> status=<http> ...` — `StoreError[PRECONDITION] ...
# status=412` on a precondition miss and `StoreError[NOT_FOUND] ...
# status=404` on an absent object — so the conformers' behaviour does not
# depend on which backend they run over. `errors.gcs_store_error_kind_from_
# message` reads the kind back.
#
# Encapsulation: no UnsafePointer in any signature; the carriers are flat
# value types holding owned String / List fields.
# =============================================================================


@fieldwise_init
struct ObjectMetaRaw(Movable, Copyable, Deinitable):
    """The metadata GetObject returns, as a flat value. The conformer maps it
    onto the trait's `ObjectMeta`, carrying the generation as the CAS handle.

    Fields:
      key: the bare object key (Object.name).
      size: the object size in bytes (Object.size).
      generation: the content generation (Object.generation), GCS's CAS handle.
      etag: the server etag (Object.etag; may be empty).
    """

    var key: String
    var size: Int64
    var generation: Int64
    var etag: String


@fieldwise_init
struct ListPageRaw(Movable, Deinitable):
    """One ListObjects page: the objects under the prefix, the common
    (delimiter-folded) prefixes, and the next page token.

    Fields:
      objects: the objects under the prefix.
      common_prefixes: the directory-style prefixes (delimiter listings only).
      next_page_token: empty when the listing is exhausted.
    """

    var objects: List[ObjectMetaRaw]
    var common_prefixes: List[String]
    var next_page_token: String

    @staticmethod
    def empty() -> ListPageRaw:
        return ListPageRaw(List[ObjectMetaRaw](), List[String](), String(""))


trait GcsStorageBackend(Movable, Deinitable):
    """The narrow google.storage.v2 object-verb surface the GCS conformers
    depend on. Every conformer raises the same `StoreError[<KIND>] ...
    status=<http>` Error on a precondition miss or an absent object, so the
    conformers' contract does not depend on the backend.

    Every verb takes `mut self`: a network backend drives its transport (and
    the reactor under it) mutably.
    """

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        """Create-if-absent (WriteObject if_generation_match=0). Returns the
        new object's generation. If the key already exists, raises
        `StoreError[PRECONDITION] ... status=412`."""
        ...

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        """Compare-and-swap (WriteObject if_generation_match=<expected>).
        Returns the new generation. On a stale generation or an absent object,
        raises `StoreError[PRECONDITION] ... status=412`."""
        ...

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        """Read `[read_offset, read_offset + read_limit)`; `read_limit = 0`
        reads to the end. If the object is absent, raises
        `StoreError[NOT_FOUND] ... status=404`."""
        ...

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        """GetObject, metadata only. If the object is absent, raises
        `StoreError[NOT_FOUND] ... status=404`."""
        ...

    def delete_object(mut self, bucket: String, key: String) raises:
        """DeleteObject. A backend may raise NOT_FOUND for an absent object;
        `GcsConditionalStore.delete` swallows it."""
        ...

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        """ListObjects under `prefix`, one page. The caller paginates by
        calling again with the page's `next_page_token`.

        `delimiter` selects the listing mode:
          * `""` (default): recursive. Every key under `prefix`, at any depth,
            lands in `objects`; `common_prefixes` is empty.
          * `"/"`: directory-like. A key with a `/` after the prefix is folded
            into `common_prefixes` (truncated just after that `/`); only direct
            children land in `objects`. `GcsFs.list_dir_shallow` and
            `GcsFs.is_dir` need this mode."""
        ...
