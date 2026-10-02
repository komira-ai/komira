# =============================================================================
# komira_objectstore_gcs/conditional_store.mojo
#   GcsConditionalStore[B] — the CloneableConditionalWriteStore conformer for
#   GCS over the GcsStorageBackend seam.
# =============================================================================
#
# SHAPE.
#   * Bound to ONE bucket at construction; the trait's `path: Path` is the
#     object KEY within that bucket.
#   * Owns a per-conformer backend, built lazily, behind an
#     `ArcPointer[Optional[B]]`. `ArcPointer.__getitem__` yields a mutable
#     reference through an immutable `self` with a tracked origin. `clone()`
#     mints a FRESH empty Arc, so no two conformers share a backend (and so no
#     two share a transport pool).
#   * Generic over one parameter, the backend: a network backend's transport
#     generic stops at the backend.
#
# VERB MAPPING.
#   conditional_put (create)    -> backend.conditional_create (ifgen=0)
#   conditional_put (if_match),
#   compare_and_swap            -> backend.compare_and_swap   (ifgen=<gen>)
#   put (unconditional)         -> GetObject probe, then create or CAS
#   get_range                   -> backend.read_range(start, length)
#   get                         -> backend.read_range(0, 0)  (to end)
#   head                        -> backend.get_object
#   delete                      -> backend.delete_object (NOT_FOUND swallowed)
#   list_with_delimiter         -> backend.list_objects(delimiter="/"), drained
#
# THE CAS HANDLE IS THE GENERATION, IN BOTH `etag` AND `version`. The trait's
# CAS token is the opaque handle a conformer produces in `ObjectMeta` and
# consumes in `WritePrecondition.if_match(etag)`; `CasManifestStore` threads
# `meta.etag`, as every other conformer fills it. So this conformer renders
# the GENERATION into `ObjectMeta.etag`, not the server etag (`Object.etag`),
# which is not an integer and cannot be fed back as `if_generation_match`.
# `version` carries the same generation, for callers that pass `meta.version`
# to `compare_and_swap`.
#
# 412 CONTRACT. A create on an existing key and a CAS on a stale generation
# both raise `StoreError[PRECONDITION] ... status=412` — the backend's error,
# passed through unchanged.
#
# Encapsulation: no UnsafePointer in any public signature, no wildcard
# origin. The factory field is a thin function pointer: a code address, no
# heap.
# =============================================================================

from std.memory import ArcPointer

from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from .backend import GCS_LIST_MAX_PAGES, GcsStorageBackend
from .errors import GCS_ERR_NOT_FOUND, gcs_store_error_kind_from_message


# =============================================================================
# §1 — Generation <-> handle String.
# =============================================================================


@always_inline
def _generation_to_version(generation: Int64) -> String:
    """Render a GCS generation as the opaque handle String (base 10)."""
    return String(generation)


def _version_to_generation(version: String) raises -> Int64:
    """Parse a handle String back into a GCS generation, for a CAS.

    Accepts only a base-10 integer in `1..Int64.MAX`: what
    `_generation_to_version` renders for a live object. Raises on anything
    else before any backend call. In particular `"0"` is refused, because
    `if_generation_match = 0` on the wire means "create only if absent" and
    would quietly turn a compare-and-swap into a create; a sign, a server
    etag, or a value past Int64.MAX is refused too."""
    var n = version.byte_length()
    if n == 0:
        raise Error(
            "GcsConditionalStore.compare_and_swap: empty version handle;"
            " pass the etag or version a previous write returned"
        )
    var max_div10 = Int64(922337203685477580)  # Int64.MAX // 10
    var max_mod10 = Int64(7)  # Int64.MAX % 10
    var acc = Int64(0)
    for i in range(n):
        var c = ord(version[byte=i])
        if c < ord("0") or c > ord("9"):
            raise Error(
                String("GcsConditionalStore.compare_and_swap: malformed")
                + " version handle (not a base-10 generation): "
                + version
            )
        var d = Int64(c - ord("0"))
        if acc > max_div10 or (acc == max_div10 and d > max_mod10):
            raise Error(
                String("GcsConditionalStore.compare_and_swap: version handle")
                + " overflows a generation: "
                + version
            )
        acc = acc * Int64(10) + d
    if acc == Int64(0):
        raise Error(
            String("GcsConditionalStore.compare_and_swap: version handle 0")
            + " is not a generation (if_generation_match=0 means create)"
        )
    return acc


@always_inline
def _is_not_found(msg: String) -> Bool:
    """True iff a raised backend Error is a NOT_FOUND, read from its leading
    `StoreError[<KIND>]` token only (never from the key in the message)."""
    return gcs_store_error_kind_from_message(msg) == GCS_ERR_NOT_FOUND


# =============================================================================
# §2 — GcsConditionalStore[B].
# =============================================================================


struct GcsConditionalStore[B: GcsStorageBackend](
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """The `ConditionalWriteStore` conformer for GCS, over a
    `GcsStorageBackend`.

    The backend is built by a caller-supplied factory on the first verb, so
    construction and `clone()` are infallible even when building a backend
    is not:

        var store = GcsConditionalStore[FakeGcsStorageBackend](
            bucket="b", make_backend=make_fake,
        )
        var meta = store.conditional_put(
            Path.parse("manifest/v1.json"), bytes,
            WritePrecondition.if_none_match_star(),
        )
        var meta2 = store.compare_and_swap(
            Path.parse("manifest/v1.json"), bytes2, meta.etag,
        )
    """

    var _bucket: String
    # The per-conformer backend, built on the first verb and reached mutably
    # from an immutable `self` through the Arc. `clone()` mints a fresh empty
    # Arc rather than sharing this one.
    var _backend: ArcPointer[Optional[Self.B]]
    # The backend factory: a thin function pointer (no captures; a capturing
    # closure cannot return a trait-bound generic). `raises`, because a
    # network backend's construction can fail; a non-raising factory such as
    # a test fake's satisfies it too. It runs only inside a raising verb.
    var _make_backend: def () raises thin -> Self.B

    def __init__(
        out self,
        var bucket: String,
        make_backend: def () raises thin -> Self.B,
    ):
        """A store bound to `bucket`. The backend is built by `make_backend`
        on the first verb; nothing is built here."""
        self._bucket = bucket^
        self._make_backend = make_backend
        self._backend = ArcPointer[Optional[Self.B]](Optional[Self.B](None))

    def __init__(
        out self,
        var bucket: String,
        var backend: Self.B,
        make_backend: def () raises thin -> Self.B,
    ):
        """A store bound to `bucket` over an already-built `backend`, so a
        build failure surfaces at the construction site rather than on the
        first verb. `make_backend` builds the backend of each clone."""
        self._bucket = bucket^
        self._make_backend = make_backend
        self._backend = ArcPointer[Optional[Self.B]](Optional[Self.B](backend^))

    def __init__(
        out self,
        var _bucket: String,
        var _backend: ArcPointer[Optional[Self.B]],
        _make_backend: def () raises thin -> Self.B,
    ):
        """Fieldwise constructor, for `clone()`."""
        self._bucket = _bucket^
        self._backend = _backend^
        self._make_backend = _make_backend

    def clone(self) -> Self:
        """A store on the same bucket and factory with its OWN, not yet built,
        backend (a new Arc, not a copy of this one). Infallible: the backend is
        built on the clone's first verb."""
        return Self(
            _bucket=self._bucket.copy(),
            _backend=ArcPointer[Optional[Self.B]](Optional[Self.B](None)),
            _make_backend=self._make_backend,
        )

    @always_inline
    def bucket(self) -> String:
        """The bucket this store is bound to."""
        return self._bucket

    def _build_backend_if_absent(self) raises:
        ref slot = self._backend[]
        if not slot:
            slot = Optional[Self.B](self._make_backend())

    # =========================================================================
    # ObjectStore.
    # =========================================================================

    def head(self, path: Path) raises -> ObjectMeta:
        """Size and generation of the object at `path` (GetObject)."""
        self._build_backend_if_absent()
        ref backend = self._backend[].value()
        var raw = backend.get_object(self._bucket, path.raw())
        var handle = _generation_to_version(raw.generation)
        return ObjectMeta(
            location=path.raw(),
            size=raw.size,
            etag=handle,
            last_modified_unix_ms=Int64(-1),
            version=handle,
        )

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """The `/`-delimited listing under `prefix`, every page drained."""
        self._build_backend_if_absent()
        ref backend = self._backend[].value()
        var objects = List[ObjectMeta]()
        var common = List[String]()
        var page_token = String("")
        var pages = 0
        while True:
            pages += 1
            if pages > GCS_LIST_MAX_PAGES:
                raise Error(
                    "GcsConditionalStore.list_with_delimiter: page cap exceeded"
                )
            var page = backend.list_objects(
                self._bucket, prefix.raw(), page_token, String("/")
            )
            for i in range(len(page.objects)):
                ref o = page.objects[i]
                var handle = _generation_to_version(o.generation)
                objects.append(
                    ObjectMeta(
                        location=o.key,
                        size=o.size,
                        etag=handle,
                        last_modified_unix_ms=Int64(-1),
                        version=handle,
                    )
                )
            for i in range(len(page.common_prefixes)):
                common.append(page.common_prefixes[i])
            if page.next_page_token.byte_length() == 0:
                break
            page_token = page.next_page_token
        return ListResult(objects^, common^)

    def coalesce_policy(self) -> CoalescePolicy:
        """The default range-coalescing policy."""
        return CoalescePolicy.default()

    # =========================================================================
    # ConditionalWriteStore.
    # =========================================================================

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        """Write `bytes` at `path` under `precond`:
          * create-if-absent -> backend.conditional_create (ifgen=0);
          * if-match(handle) -> backend.compare_and_swap (ifgen=<handle>);
          * none             -> create or overwrite (`_unconditional_put`).
        A precondition miss raises `StoreError[PRECONDITION] ... status=412`.

        Returns the committed `ObjectMeta`, with the new generation in `etag`
        and `version`, so a caller can chain the next CAS without a head."""
        self._build_backend_if_absent()
        var key = path.raw()

        var new_gen: Int64
        if precond.is_create():
            ref backend = self._backend[].value()
            new_gen = backend.conditional_create(self._bucket, key, bytes.copy())
        elif precond.is_if_match():
            var expected = _version_to_generation(precond.etag)
            ref backend = self._backend[].value()
            new_gen = backend.compare_and_swap(
                self._bucket, key, bytes.copy(), expected
            )
        else:
            new_gen = self._unconditional_put(key, bytes.copy())

        var handle = _generation_to_version(new_gen)
        return ObjectMeta(
            location=key,
            size=Int64(len(bytes)),
            etag=handle,
            last_modified_unix_ms=Int64(-1),
            version=handle,
        )

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        """Write `bytes` only if the object's generation is
        `expected_version`; `conditional_put` with `if_match`."""
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        """Create or overwrite `path`; `conditional_put` with no
        precondition."""
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def _unconditional_put(self, key: String, var bytes: List[UInt8]) raises -> Int64:
        """Create or overwrite. The seam has only conditional writes, so this
        probes with GetObject, then creates if absent or CASes against the
        generation it read. Between the probe and the write a concurrent
        writer makes it raise 412, never overwrite blindly."""
        var live_gen = Int64(-1)
        var exists = True
        try:
            var raw = self._backend[].value().get_object(self._bucket, key)
            live_gen = raw.generation
        except e:
            if _is_not_found(String(e)):
                exists = False
            else:
                raise e^
        if not exists:
            return self._backend[].value().conditional_create(
                self._bucket, key, bytes^
            )
        return self._backend[].value().compare_and_swap(
            self._bucket, key, bytes^, live_gen
        )

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        """`length` bytes from `start`. A zero-length read returns empty
        without a call; a negative `start` or `length`, or a short read,
        raises."""
        if start < Int64(0) or length < Int64(0):
            raise Error(
                "GcsConditionalStore.get_range: negative start ("
                + String(start)
                + ") or length ("
                + String(length)
                + ") (key: "
                + path.raw()
                + ")"
            )
        if length == Int64(0):
            return List[UInt8]()
        self._build_backend_if_absent()
        ref backend = self._backend[].value()
        var bytes = backend.read_range(self._bucket, path.raw(), start, length)
        if Int64(len(bytes)) != length:
            raise Error(
                "GcsConditionalStore.get_range: short read: requested "
                + String(Int(length))
                + " bytes, got "
                + String(len(bytes))
                + " (key: "
                + path.raw()
                + ")"
            )
        return bytes^

    def get(self, path: Path) raises -> List[UInt8]:
        """The whole object at `path`."""
        self._build_backend_if_absent()
        ref backend = self._backend[].value()
        return backend.read_range(self._bucket, path.raw(), Int64(0), Int64(0))

    def delete(self, path: Path) raises -> None:
        """Delete the object at `path`. Deleting an absent object succeeds."""
        self._build_backend_if_absent()
        ref backend = self._backend[].value()
        try:
            backend.delete_object(self._bucket, path.raw())
        except e:
            if _is_not_found(String(e)):
                return
            raise e^
