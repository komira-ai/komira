# =============================================================================
# komira_objectstore_gcs/gcs_fs.mojo — GcsFs[B], the FileSystem read
# conformer for GCS over the GcsStorageBackend seam
# =============================================================================
#
# GcsFs drives only the backend's high-level verbs (read_range, get_object,
# list_objects); it never sees a transport. It is generic over
# `B: GcsStorageBackend`, so a network backend's transport generic stops at
# the backend, and the same conformer runs hermetically over
# `FakeGcsStorageBackend`.
#
# The caller builds the backend (bucket credentials and transport ride on it)
# and hands GcsFs both a built backend and a factory for its clones:
#
#     def mk() raises -> MyBackend: ...
#     var fs = GcsFs[MyBackend](bucket="my-bucket", backend=mk(), mk_backend=mk)
#
# PER-WORKER clone(). A network backend's transport pool is single-thread by
# design and cannot be copied, so `clone()` gives the clone an EMPTY slot that
# the factory fills on the clone's first read. Sharing one backend across
# workers would corrupt its pool.
#
# Writes are not supported: every write verb raises.
#
# Encapsulation: no UnsafePointer in any public signature, no wildcard-origin
# field. `_backend` is a length-1 `Slab[Optional[B]]` holding an owned `B`,
# reached mutably from an immutable `self` through `get_mut_interior(0)`.
# `_mk_backend` is a thin function pointer: a code address, no heap.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FooterRegion, speculative_tail_start
# `_shallow_basename` is a private helper of komira_async, used here on
# purpose: it is the one definition of a listing key's final component that
# every object-store FileSystem shares, and a copy here could drift from it.
from komira_fs.shallow_dir_entry import ShallowDirEntry, _shallow_basename

from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.fs_descriptor_pod import FS_SCHEME_GCS

from .backend import GCS_LIST_MAX_PAGES, GcsStorageBackend


@fieldwise_init
struct GcsWriteFile(Movable, Deinitable):
    """The `FileSystem.WriteFile` of `GcsFs`. GcsFs does not write; every
    write verb raises, so no value of this type is ever returned."""

    var _path: String


@fieldwise_init
struct GcsFileHandle(Movable, Deinitable):
    """A handle returned by `GcsFs.open(key)`: the object key the reads
    address. The transport lives on the GcsFs's backend."""

    var _key: String

    @always_inline
    def key(self) -> String:
        return self._key


struct GcsFs[B: GcsStorageBackend](FileSystem, Movable, Deinitable):
    """The `FileSystem` read conformer for GCS, over a `GcsStorageBackend`.

    Owns its backend in a length-1 `Slab`, reached mutably from an immutable
    `self` (the backend verbs take `mut self`). Each worker uses its own
    GcsFs; `clone()` gives the clone its own backend, built by `_mk_backend`
    on the clone's first read.
    """

    comptime File = GcsFileHandle
    comptime WriteFile = GcsWriteFile
    # GCS has no disjoint-range concurrent write.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = False
    # GcsFs has a shallow listing (`list_dir_shallow`, from the delimiter
    # fold) and a paginated recursive `list`, which lazy Hive discovery needs.
    comptime SUPPORTS_LAZY_HIVE: Bool = True
    # The GCS scheme tag, by name, so it cannot drift from the descriptor.
    comptime SCHEME: UInt8 = FS_SCHEME_GCS

    var _bucket: String
    # The owned backend. Built lazily on a clone, because `clone()` is
    # infallible and building a backend may not be; the first GcsFs is seeded
    # with the backend its constructor is given.
    var _backend: Slab[Optional[Self.B]]
    var _mk_backend: def () raises thin -> Self.B

    def __init__(
        out self,
        var bucket: String,
        var backend: Self.B,
        mk_backend: def () raises thin -> Self.B,
    ):
        """A GcsFs on `bucket` over `backend`, which it owns.

        Args:
            bucket: The GCS bucket name.
            backend: A built backend; credentials and transport ride on it.
            mk_backend: Builds a fresh backend for each clone.
        """
        self._bucket = bucket^
        var slab = Slab[Optional[Self.B]]()
        slab.append(Optional[Self.B](backend^))
        self._backend = slab^
        self._mk_backend = mk_backend

    def __init__(
        out self,
        var _bucket: String,
        var _backend: Slab[Optional[Self.B]],
        _mk_backend: def () raises thin -> Self.B,
    ):
        """Fieldwise constructor, for `clone()`."""
        self._bucket = _bucket^
        self._backend = _backend^
        self._mk_backend = _mk_backend

    # ---- FileSystem ----

    def clone(self) -> Self:
        """A GcsFs on the same bucket and factory with an empty backend slot,
        filled by the factory on the clone's first read. Two clones never
        share a backend."""
        var slab = Slab[Optional[Self.B]]()
        slab.append(Optional[Self.B](None))
        return Self(
            _bucket=self._bucket.copy(),
            _backend=slab^,
            _mk_backend=self._mk_backend,
        )

    def _build_backend_if_absent(self) raises:
        # SAFETY: get_mut_interior(0): the slab has exactly one slot and never
        # grows, the reference does not outlive `self`, and a GcsFs is used by
        # one thread.
        ref slot = self._backend.get_mut_interior(0)
        if not slot:
            slot = Optional[Self.B](self._mk_backend())

    @always_inline
    def bucket(self) -> String:
        """The bucket this GcsFs reads."""
        return self._bucket

    def list(self, prefix: String) raises -> List[String]:
        """Every key under `prefix`, at any depth, as bare object keys (the
        form `open` takes; no `gs://bucket/` prefix). Recursive listing,
        every page drained."""
        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()

        var out = List[String]()
        var page_token = String("")
        var pages = 0
        while True:
            pages += 1
            if pages > GCS_LIST_MAX_PAGES:
                raise Error("GcsFs.list: page cap exceeded")
            var page = backend.list_objects(
                self._bucket, prefix, page_token, String("")
            )
            for i in range(len(page.objects)):
                out.append(page.objects[i].key.copy())
            if page.next_page_token.byte_length() == 0:
                break
            page_token = page.next_page_token.copy()
        return out^

    def open(self, path: String) raises -> Self.File:
        """A handle on the object key `path`. Issues no request."""
        return GcsFileHandle(_key=path)

    @always_inline
    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """`length` bytes from `offset` of `file`, via
        `backend.read_range(offset, length)`. A zero-length read returns an
        empty buffer without a request (the wire reads `read_limit = 0` as
        "to the end"); a negative `offset` or `length`, or a short response,
        raises."""
        if offset < Int64(0) or length < Int64(0):
            raise Error(
                "GcsFs.read_at: negative offset ("
                + String(offset)
                + ") or length ("
                + String(length)
                + ") (object key: "
                + file._key
                + ")"
            )
        if length == Int64(0):
            return SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(0))
        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()

        var bytes = backend.read_range(self._bucket, file._key, offset, length)

        if Int64(len(bytes)) != length:
            raise Error(
                "GcsFs.read_at: short read: requested "
                + String(Int(length))
                + " bytes, got "
                + String(len(bytes))
                + " (object key: "
                + file._key
                + ")"
            )

        var buf = OwnedAlignedBuffer(Int(length))
        var dst = buf.view_range_mut(0, Int(length))
        # SAFETY: `dst` points into `buf`, allocated above with `length`
        # bytes; `bytes` owns `length` bytes (checked above). Both outlive the
        # copy and neither pointer is kept.
        unsafe_memcpy(
            dest=dst._unsafe_ptr(),
            src=bytes.unsafe_ptr(),
            count=Int(length),
        )
        buf.set_length(Int64(Int(length)))

        return SharedAlignedBuffer.from_owned(buf^)

    def read_ranges_prefetched(
        self,
        mut file: Self.File,
        ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """One buffer per `(offset, length)` range, in input order, read one
        `read_at` at a time."""
        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        for i in range(len(ranges)):
            var offset_len = ranges[i]
            var buf = self.read_at(file, offset_len[0], offset_len[1])
            out.append(buf^)
        return out^

    @always_inline
    def prefetch_depth(self) -> Int:
        """64: a networked object store, where the round trip, not the
        transfer, dominates a small read."""
        return 64

    @always_inline
    def supports_random_read(self) -> Bool:
        return True

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        """The last `window` bytes of `path`, with the object's size.

        The seam's `read_range` returns bytes but no object metadata, and
        the footer needs the object's size, so this takes the size first
        (GetObject) and then reads the absolute tail range: two requests per
        file.

        Raises if the object is smaller than the 8-byte parquet trailer."""
        var size = self.file_size(path)
        if size < 8:
            raise Error(
                "GcsFs.read_footer: object too small for a parquet trailer"
                " (size "
                + String(size)
                + " < 8): "
                + path
            )

        var start = speculative_tail_start(size, window)
        var read_count = size - start

        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()

        var bytes = backend.read_range(
            self._bucket, path, Int64(start), Int64(read_count)
        )
        if len(bytes) != read_count:
            raise Error(
                "GcsFs.read_footer: short read: requested "
                + String(read_count)
                + " bytes, got "
                + String(len(bytes))
                + " (object key: "
                + path
                + ")"
            )
        return FooterRegion(bytes^, start, size)

    def is_dir(self, path: String) raises -> Bool:
        """True iff some key exists under `path/`. GCS has no directories; a
        directory is a prefix with objects under it. `path` is normalized to
        end in `/`, so `events` does not match a sibling `events.parquet`.
        One `/`-delimited page is enough to answer."""
        var probe_prefix = path
        if not probe_prefix.endswith(String("/")):
            probe_prefix = probe_prefix + String("/")
        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()
        var page = backend.list_objects(
            self._bucket, probe_prefix, String(""), String("/")
        )
        return len(page.objects) > 0 or len(page.common_prefixes) > 0

    def list_dir_shallow(self, prefix: String) raises -> List[ShallowDirEntry]:
        """The immediate children of `prefix`, one level: each folded common
        prefix is a directory entry and each object a file entry, named by
        its final path component. Not recursive.

        A non-empty `prefix` is normalized to end in `/` (as in `is_dir`); the
        empty prefix (the bucket root) is left as is. The zero-byte
        placeholder object named exactly the prefix is the directory itself
        and is skipped. Every page is drained, in page order; within a page the
        directories come first, then the files, each in name order."""
        var probe_prefix = prefix
        if probe_prefix.byte_length() > 0 and not probe_prefix.endswith(
            String("/")
        ):
            probe_prefix = probe_prefix + String("/")
        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()

        var out = List[ShallowDirEntry]()
        var page_token = String("")
        var pages = 0
        while True:
            pages += 1
            if pages > GCS_LIST_MAX_PAGES:
                raise Error("GcsFs.list_dir_shallow: page cap exceeded")
            var page = backend.list_objects(
                self._bucket, probe_prefix, page_token, String("/")
            )
            for i in range(len(page.common_prefixes)):
                out.append(
                    ShallowDirEntry(
                        name=_shallow_basename(page.common_prefixes[i]),
                        is_dir=True,
                    )
                )
            for i in range(len(page.objects)):
                ref key = page.objects[i].key
                if key == probe_prefix:
                    continue
                var base = _shallow_basename(key)
                if base.byte_length() == 0:
                    continue
                out.append(ShallowDirEntry(name=base^, is_dir=False))
            if page.next_page_token.byte_length() == 0:
                break
            page_token = page.next_page_token.copy()
        return out^

    def file_size(self, path: String) raises -> Int:
        """The size of the object at `path` (GetObject). Raises if the object
        is absent or reports a negative size."""
        self._build_backend_if_absent()
        ref backend = self._backend.get_mut_interior(0).value()
        var meta = backend.get_object(self._bucket, path)
        if meta.size < Int64(0):
            raise Error(
                "GcsFs.file_size: GetObject returned no size for object key: "
                + path
            )
        return Int(meta.size)

    # ---- Writes: not supported ----

    def open_write(self, path: String, mode: WriteMode) raises -> Self.WriteFile:
        raise Error("GcsFs.open_write: GcsFs does not write. path=" + path)

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("GcsFs.write_at: GcsFs does not write.")

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error(
            "GcsFs.pwrite_at: GCS has no disjoint-range concurrent write"
            " (SUPPORTS_PARALLEL_WRITES = False)."
        )

    def close_write(self, var file: Self.WriteFile) raises -> None:
        raise Error("GcsFs.close_write: GcsFs does not write.")
