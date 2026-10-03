# =============================================================================
# komira_objectstore_s3/s3_fs.mojo -- S3Fs, the FileSystem read conformer for
# one S3 bucket
# =============================================================================
#
# `S3Fs[C, T, K]` is S3 as komira_fs's `FileSystem`, bound to ONE bucket: the
# trait's `path` is the object key in it (a bare key, no `s3://bucket/`; what
# `list` returns is what `open` takes). Every verb is an S3Store verb
# (store.mojo), so every request is the generated client's, signed and sent
# by komira_aws_core:
#
#   list                    -> ListObjectsV2, no delimiter, every page
#   list_dir_shallow        -> ListObjectsV2, delimiter "/", every page
#   is_dir                  -> ListObjectsV2, delimiter "/", one page
#   file_size               -> HeadObject
#   read_at                 -> GetObject with Range
#   read_ranges_prefetched  -> coalesced ranged GetObjects, one version
#   read_footer             -> ONE GetObject with a suffix Range
#
# ONE VERSION PER FETCH. `read_ranges_prefetched` hands every range of a call
# to `S3Store.get_ranges_into`: near ranges are merged into one request, and
# every request after the first carries `If-Match` with the ETag the first
# answered, so an object overwritten during the fetch raises PRECONDITION
# rather than returning bytes of two versions.
#
# ONE REQUEST PER FOOTER. `read_footer` asks for the object's last bytes with
# `Range: bytes=-<window>`; the 206's Content-Range gives the object's size,
# which a HEAD would otherwise have had to fetch first.
#
# Writes are not supported: every write verb raises. `S3WriteFile` is the
# trait's write handle type and no value of it is ever made.
#
# SETTINGS are constructor parameters: the store's in `S3Config`, the file
# system's in `S3FsOptions`. Nothing reads the environment.
#
# CLONES. The trait's verbs take `self` immutably and `clone()` must be
# infallible, so the store is built lazily, behind an
# `ArcPointer[Optional[S3Store]]` reached mutably through the Arc, and a clone
# gets a NEW empty Arc: two file systems never share a store (its connection
# and HTTP client are not shared between threads). A clone copies the
# configuration, the options, the credential source and the clock; the
# connector factory is a thin function pointer (a code address, no heap).
#
# No UnsafePointer in any public signature, no wildcard-origin field.
# =============================================================================

from std.memory import ArcPointer, unsafe_memcpy

from komira_aws_core import AwsClock, AwsCredsSource
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.fs_descriptor_pod import FS_SCHEME_S3
from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import FooterRegion, speculative_tail_start
# `_shallow_basename` is komira_fs's one definition of a listing key's final
# component, shared by every object-store FileSystem; a copy here could drift.
from komira_fs.shallow_dir_entry import ShallowDirEntry, _shallow_basename
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.store import PREFETCH_DEPTH_S3_STANDARD
from komira_objectstore.types import GetRange, RangeSet

from .config import S3Config
from .store import S3Store


comptime S3_FS_ALL_RANGES = 0
"""`S3FsOptions.prefetch_max_inflight` for "every range of one
`read_ranges_prefetched` call"."""


struct S3FsOptions(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """What an `S3Fs` decides beyond its store's `S3Config`. Every field is
    set by the caller; the defaults are S3's standard.

    - `prefetch_max_inflight`: the requests one `read_ranges_prefetched` call
      may plan to have in flight: `S3_FS_ALL_RANGES` (0) for one per range
      of the call, or a bound K >= 1. The store clamps it to
      `S3Config.max_inflight`. komira_aws_core's send blocks its thread, so
      the store sends a plan's requests one after another; the bound is the
      plan's until a non-blocking send exists (store.mojo).
    - `prefetch_depth`: what `prefetch_depth()` reports, the depth of the
      reader's prefetch ring: 64 for S3 standard, 32 for S3 Express.
    """

    var prefetch_max_inflight: Int
    var prefetch_depth: Int

    def __init__(
        out self,
        *,
        prefetch_max_inflight: Int = S3_FS_ALL_RANGES,
        prefetch_depth: Int = PREFETCH_DEPTH_S3_STANDARD,
    ) raises:
        """Refuses a negative `prefetch_max_inflight` and a `prefetch_depth`
        below 1."""
        if prefetch_max_inflight < 0:
            raise Error(
                String("S3FsOptions: prefetch_max_inflight must be >= 0 (0 for every range), got ")
                + String(prefetch_max_inflight)
            )
        if prefetch_depth < 1:
            raise Error(
                String("S3FsOptions: prefetch_depth must be >= 1, got ")
                + String(prefetch_depth)
            )
        self.prefetch_max_inflight = prefetch_max_inflight
        self.prefetch_depth = prefetch_depth

    @staticmethod
    def standard() -> S3FsOptions:
        """The defaults: every range of a call, and S3 standard's depth."""
        return S3FsOptions(
            _checked_inflight=S3_FS_ALL_RANGES,
            _checked_depth=PREFETCH_DEPTH_S3_STANDARD,
        )

    def __init__(out self, *, _checked_inflight: Int, _checked_depth: Int):
        """Values already known to be valid (`standard`)."""
        self.prefetch_max_inflight = _checked_inflight
        self.prefetch_depth = _checked_depth

    def prefetch_window(self, num_ranges: Int) -> Int:
        """The in-flight bound of a call reading `num_ranges` ranges: all of
        them, or the bound when it is smaller. 1 at least."""
        var window = num_ranges
        if self.prefetch_max_inflight != S3_FS_ALL_RANGES:
            window = min(window, self.prefetch_max_inflight)
        return max(1, window)


@fieldwise_init
struct S3WriteFile(Movable, Deinitable):
    """The `FileSystem.WriteFile` of `S3Fs`. S3Fs does not write; every write
    verb raises, so no value of this type is ever returned."""

    var _key: String


@fieldwise_init
struct S3FileHandle(Movable, Deinitable):
    """A handle returned by `S3Fs.open(key)`: the object key the reads
    address. The connection lives on the S3Fs's store."""

    var _key: String

    @always_inline
    def key(self) -> String:
        return self._key


def _to_buffer(bytes: Span[UInt8, _]) -> SharedAlignedBuffer[HeapRegion]:
    """`bytes` copied into an owning aligned buffer."""
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(n)
    buf.set_length(Int64(n))
    if n > 0:
        var dst = buf.view_range_mut(0, n)
        # SAFETY: `dst` views the `n` bytes of `buf`, allocated above; `bytes`
        # holds `n` bytes. Both outlive the copy and neither pointer is kept.
        unsafe_memcpy(dest=dst._unsafe_ptr(), src=bytes.unsafe_ptr(), count=n)
    return SharedAlignedBuffer.from_owned(buf^)


struct S3Fs[
    C: Connector,
    T: AwsCredsSource & Copyable,
    K: AwsClock & Copyable & Deinitable,
](FileSystem, Movable, Deinitable):
    """The `FileSystem` read conformer for one S3 bucket (module header).

        var fs = S3Fs[KernelTcpConnector, StaticCredsSource, SystemAwsClock](
            "lake", S3Config.aws("us-east-1"), mk_connector, creds, SystemAwsClock(),
        )
        var footer = fs.read_footer("events/part-0.parquet", 64 * 1024)
    """

    comptime File = S3FileHandle
    comptime WriteFile = S3WriteFile
    # S3 has no disjoint-range concurrent write.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = False
    # S3Fs has a shallow listing (`list_dir_shallow`, from the delimiter fold)
    # and a paginated recursive `list`, which lazy Hive discovery needs: the
    # pruned discovery lists only the surviving partitions' prefixes.
    comptime SUPPORTS_LAZY_HIVE: Bool = True
    # The S3 scheme tag, by name, so it cannot drift from the descriptor.
    comptime SCHEME: UInt8 = FS_SCHEME_S3

    var _bucket: String
    var _config: S3Config
    var _options: S3FsOptions
    var _mk_connector: def () raises thin -> Self.C
    var _creds: Self.T
    var _clock: Self.K
    var _store: ArcPointer[Optional[S3Store[Self.C, Self.T, Self.K]]]

    def __init__(
        out self,
        var bucket: String,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        var creds: Self.T,
        var clock: Self.K,
        options: S3FsOptions = S3FsOptions.standard(),
    ):
        """A file system on `bucket`. Nothing is built or dialed here: the
        store is built on the first verb.

        Args:
            bucket: The S3 bucket name.
            config: The store's configuration (region, endpoint, retry, the
                store's own in-flight bound, listing pages).
            mk_connector: Makes the connector each store dials through.
            creds: The credential source requests are signed with.
            clock: The signing clock.
            options: The file system's settings (`S3FsOptions`).
        """
        self._bucket = bucket^
        self._config = config^
        self._options = options
        self._mk_connector = mk_connector
        self._creds = creds^
        self._clock = clock^
        self._store = ArcPointer[Optional[S3Store[Self.C, Self.T, Self.K]]](
            Optional[S3Store[Self.C, Self.T, Self.K]](None)
        )

    @staticmethod
    def built(
        var bucket: String,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        var creds: Self.T,
        var clock: Self.K,
        options: S3FsOptions = S3FsOptions.standard(),
    ) raises -> Self:
        """A file system whose store is built now, so a failure to build it
        (a bad endpoint, a connector that cannot be made) raises here rather
        than on the first verb."""
        var fs = Self(bucket^, config^, mk_connector, creds^, clock^, options)
        fs._build_if_absent()
        return fs^

    # ---- FileSystem ----

    def clone(self) -> Self:
        """A file system on the same bucket, configuration and options with
        its OWN, not yet built, store (a new Arc). Infallible."""
        return Self(
            self._bucket.copy(),
            self._config.copy(),
            self._mk_connector,
            self._creds.copy(),
            self._clock.copy(),
            self._options,
        )

    def _build_if_absent(self) raises:
        ref slot = self._store[]
        if not slot:
            slot = Optional[S3Store[Self.C, Self.T, Self.K]](
                S3Store[Self.C, Self.T, Self.K](
                    self._config.copy(),
                    self._mk_connector,
                    self._creds.copy(),
                    self._clock.copy(),
                )
            )

    @always_inline
    def bucket(self) -> String:
        """The bucket this file system reads."""
        return self._bucket

    def options(self) -> S3FsOptions:
        """The file system's settings."""
        return self._options

    def list(self, prefix: String) raises -> List[String]:
        """Every key under `prefix`, at any depth, as bare object keys (the
        form `open` takes). Recursive: no delimiter, every page drained; the
        trait carries no recursion flag, and a caller filtering by glob
        re-filters the keys itself."""
        self._build_if_absent()
        var result = self._store[].value().list(self._bucket, prefix, String(""))
        var out = List[String](capacity=len(result.objects))
        for i in range(len(result.objects)):
            out.append(result.objects[i].location.copy())
        return out^

    def open(self, path: String) raises -> Self.File:
        """A handle on the object key `path`. Sends no request."""
        return S3FileHandle(_key=path)

    @always_inline
    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """`length` bytes from `offset` of `file`: one GetObject with
        `Range`. A zero length reads nothing and sends nothing; a negative
        `offset` or `length`, or fewer bytes than asked for (the object ends
        first), raises."""
        if offset < Int64(0) or length < Int64(0):
            raise Error(
                "S3Fs.read_at: negative offset ("
                + String(offset)
                + ") or length ("
                + String(length)
                + ") (key: "
                + file._key
                + ")"
            )
        if length == Int64(0):
            return SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(0))
        self._build_if_absent()
        var bytes = self._store[].value().get_range(self._bucket, file._key, offset, length)
        if Int64(len(bytes)) != length:
            raise Error(
                "S3Fs.read_at: short read: asked for "
                + String(length)
                + " bytes, got "
                + String(len(bytes))
                + " (key: "
                + file._key
                + ")"
            )
        return _to_buffer(Span(bytes))

    def read_ranges_prefetched(
        self,
        mut file: Self.File,
        ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        """One buffer per `(offset, length)` range, in input order, all read
        in ONE fetch of one version of the object (module header): the
        ranges are coalesced, and every request after the first carries
        `If-Match`. A zero-length range is an empty buffer and is not
        fetched; a negative offset or length, or a range the object ends
        before, raises."""
        var n = len(ranges)
        var fetched = RangeSet.empty()
        var at = List[Int](capacity=n)
        var total = 0
        for i in range(n):
            var r = ranges[i]
            var offset = r[0]
            var length = r[1]
            if offset < Int64(0) or length < Int64(0):
                raise Error(
                    "S3Fs.read_ranges_prefetched: range "
                    + String(i)
                    + " has a negative offset ("
                    + String(offset)
                    + ") or length ("
                    + String(length)
                    + ") (key: "
                    + file._key
                    + ")"
                )
            at.append(total)
            if length > Int64(0):
                fetched.append(GetRange.bounded(offset, offset + length), total)
                total += Int(length)

        var joined = OwnedAlignedBuffer(total)
        joined.set_length(Int64(total))
        if fetched.num_ranges() > 0:
            self._build_if_absent()
            var view = joined.view_range_mut(0, total)
            var result = self._store[].value().get_ranges_into(
                self._bucket,
                file._key,
                fetched,
                view,
                self._options.prefetch_window(fetched.num_ranges()),
            )
            var j = 0
            for i in range(n):
                var r = ranges[i]
                var length = r[1]
                if length == Int64(0):
                    continue
                if result.fetched_bytes_at(j) != length:
                    raise Error(
                        "S3Fs.read_ranges_prefetched: short read: range "
                        + String(i)
                        + " asked for "
                        + String(length)
                        + " bytes, got "
                        + String(result.fetched_bytes_at(j))
                        + " (key: "
                        + file._key
                        + ")"
                    )
                j += 1

        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        for i in range(n):
            var r = ranges[i]
            var view = joined.view_range_ro(at[i], Int(r[1]))
            out.append(_to_buffer(view.into_span()))
        return out^

    @always_inline
    def prefetch_depth(self) -> Int:
        """`S3FsOptions.prefetch_depth`: 64 for S3 standard unless set."""
        return self._options.prefetch_depth

    @always_inline
    def supports_random_read(self) -> Bool:
        return True

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        """The last `window` bytes of `path` (at least the 8-byte parquet
        trailer), with the object's size, in ONE request: a GetObject with
        `Range: bytes=-<window>`, whose Content-Range carries the size. A
        footer longer than the window is not an error here; the caller asks
        again with a larger window.

        Raises if the object is smaller than the 8-byte parquet trailer, or
        the answer is not the tail asked for."""
        var w = max(window, 8)
        self._build_if_absent()
        var tail = self._store[].value().get_suffix(self._bucket, path, Int64(w))
        var size = Int(tail.total)
        if size < 8:
            raise Error(
                "S3Fs.read_footer: object too small for a parquet trailer (size "
                + String(size)
                + " < 8): "
                + path
            )
        var start = speculative_tail_start(size, w)
        if Int(tail.offset) != start or len(tail.bytes) != size - start:
            raise Error(
                "S3Fs.read_footer: expected the "
                + String(size - start)
                + " trailing bytes of a "
                + String(size)
                + "-byte object, got "
                + String(len(tail.bytes))
                + " from offset "
                + String(tail.offset)
                + " (key: "
                + path
                + ")"
            )
        return FooterRegion(tail.bytes.copy(), start, size)

    def is_dir(self, path: String) raises -> Bool:
        """True iff some key exists under `path/`. S3 has no directories; a
        directory is a prefix with objects under it. `path` is normalized to
        end in `/`, so `events` does not match a sibling `events.parquet`.
        One `/`-delimited page answers it."""
        var probe = path
        if not probe.endswith(String("/")):
            probe = probe + String("/")
        self._build_if_absent()
        var page = self._store[].value().list_page(
            self._bucket, probe, String("/"), String("")
        )
        return len(page.objects) > 0 or len(page.common_prefixes) > 0

    def list_dir_shallow(self, prefix: String) raises -> List[ShallowDirEntry]:
        """The immediate children of `prefix`, one level: each folded common
        prefix is a directory entry and each object a file entry, named by
        its final path component. Not recursive, so a Hive partition probe
        walks `key=value` levels without listing the data files.

        A non-empty `prefix` is normalized to end in `/` (as in `is_dir`); the
        empty prefix (the bucket root) is left as is. The zero-byte
        placeholder object named exactly the prefix is the directory itself
        and is skipped. Every page is drained; the directories come first,
        then the files, each in S3's (name) order."""
        var probe = prefix
        if probe.byte_length() > 0 and not probe.endswith(String("/")):
            probe = probe + String("/")
        self._build_if_absent()
        var result = self._store[].value().list(self._bucket, probe, String("/"))
        var out = List[ShallowDirEntry]()
        for i in range(len(result.common_prefixes)):
            out.append(
                ShallowDirEntry(
                    name=_shallow_basename(result.common_prefixes[i]),
                    is_dir=True,
                )
            )
        for i in range(len(result.objects)):
            ref key = result.objects[i].location
            if key == probe:
                continue
            var base = _shallow_basename(key)
            if base.byte_length() == 0:
                continue
            out.append(ShallowDirEntry(name=base^, is_dir=False))
        return out^

    def file_size(self, path: String) raises -> Int:
        """The size of the object at `path` (HeadObject). Raises if the object
        is absent or the answer carries no size."""
        self._build_if_absent()
        var meta = self._store[].value().head(self._bucket, path)
        if meta.size < Int64(0):
            raise Error(
                "S3Fs.file_size: HeadObject returned no Content-Length for key: " + path
            )
        return Int(meta.size)

    # ---- Writes: not supported ----

    def open_write(self, path: String, mode: WriteMode) raises -> Self.WriteFile:
        raise Error("S3Fs.open_write: S3Fs does not write. path=" + path)

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("S3Fs.write_at: S3Fs does not write.")

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error(
            "S3Fs.pwrite_at: S3 has no disjoint-range concurrent write"
            " (SUPPORTS_PARALLEL_WRITES = False)."
        )

    def close_write(self, var file: Self.WriteFile) raises -> None:
        raise Error("S3Fs.close_write: S3Fs does not write.")
