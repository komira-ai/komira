# =============================================================================
# komira_objectstore_s3/s3_fs.mojo -- S3Fs, the FileSystem conformer for one
# S3 bucket
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
#   is_dir                  -> ListObjectsV2, delimiter "/", one key
#   file_size               -> HeadObject
#   read_at                 -> GetObject with Range
#   read_ranges_prefetched  -> coalesced ranged GetObjects, one version
#   read_footer             -> ONE GetObject with a suffix Range
#   open_write              -> nothing (the first request waits for bytes)
#   write_at                -> UploadPart per full part (the first one
#                              after CreateMultipartUpload)
#   close_write             -> PutObject when no part was sent, else the
#                              last UploadPart and CompleteMultipartUpload
#   abort_write             -> AbortMultipartUpload when a part was sent
#   delete                  -> DeleteObject (an absent key is not an error)
#
# ONE VERSION PER FETCH. `read_ranges_prefetched` hands every range of a call
# to `S3Store.get_ranges_into`: near ranges are merged into one request, and
# every request after the first carries `If-Match` with the ETag the first
# answered, so an object overwritten during the fetch raises PRECONDITION
# rather than returning bytes of two versions. The guarantee is per call:
# `read_footer`, `read_at` and separate prefetches each read whatever version
# is current when they are sent, and a server that answers without an ETag
# gives the later requests of a fetch nothing to send in `If-Match`.
#
# ONE REQUEST PER FOOTER. `read_footer` asks for the object's last bytes with
# `Range: bytes=-<window>`; the 206's Content-Range gives the object's size,
# which a HEAD would otherwise have had to fetch first.
#
# WRITES are S3 multipart uploads, sent one request at a time. `write_at`
# buffers bytes and sends each full part of `S3FsOptions.upload_part_bytes`
# (5 MiB at least, S3's floor for every part but the last); the upload is
# created with the first part, so an object smaller than one part is a single
# PutObject at `close_write` and leaves no upload behind. A failed part or
# completion aborts the upload before the error is raised, and the handle is
# then refused; `abort_write` is the caller's error path. A handle dropped
# without `close_write` or `abort_write` leaves the parts it sent stored (and
# billed) until a bucket lifecycle rule removes them: a destructor cannot
# reach the store. Objects are written whole: `WriteMode.append()` and
# `WriteMode.create_exclusive()` are refused, and `pwrite_at` raises
# (`SUPPORTS_PARALLEL_WRITES = False`). An object is durable when its PutObject
# or CompleteMultipartUpload is answered, so `fsync_file` and `fsync_dir` do
# nothing.
#
# SETTINGS are constructor parameters: the store's in `S3Config`, the file
# system's in `S3FsOptions`. Nothing reads the environment.
#
# CLONES. The trait's verbs take `self` immutably and `clone()` must be
# infallible, so the store is built lazily, behind an
# `ArcPointer[Optional[S3Store]]` reached mutably through the Arc, and a clone
# gets a NEW empty Arc: two file systems never share a store (its connection
# and HTTP client are not shared between threads), and none shares a retry
# quota. A clone copies the configuration, the caller's `HttpClientConfig`,
# the options, the credential source and the clock; the connector factory is
# a thin function pointer (a code address, no heap).
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
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.store import PREFETCH_DEPTH_S3_STANDARD
from komira_objectstore.types import GetRange, RangeSet, WritePrecondition

from .config import S3Config
from .store import S3Store, S3UploadedPart


comptime S3_FS_ALL_RANGES = 0
"""`S3FsOptions` `prefetch_max_inflight` for "every range of one
`read_ranges_prefetched` call"."""

comptime S3_MIN_PART_BYTES = 5 * 1024 * 1024
"""S3's smallest part, for every part of a multipart upload but the last."""

comptime S3_MAX_PART_BYTES = 5 * 1024 * 1024 * 1024
"""S3's largest part."""

comptime S3_FS_DEFAULT_PART_BYTES = 8 * 1024 * 1024
"""The part size an `S3Fs` writes unless told otherwise."""

comptime S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT = 8
"""The parts one upload may have in flight unless told otherwise."""

comptime S3_FS_UPLOAD_MAX_INFLIGHT_CAP = 16
"""The most parts one upload may have in flight: each pins a part buffer."""


@fieldwise_init
struct _S3FsDefaults(Copyable, Movable):
    """Selects `S3FsOptions`'s defaults constructor."""

    pass


struct S3FsOptions(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """What an `S3Fs` decides beyond its store's `S3Config`. Every setting is
    a constructor argument, checked there, and read through its accessor;
    the defaults are S3's standard.

    - `prefetch_max_inflight`: the requests one `read_ranges_prefetched` call
      may have in flight: `S3_FS_ALL_RANGES` (0) for one per range of the
      call, or a bound K >= 1. RECORDED, NOT YET ENFORCED: komira_aws_core's
      send blocks its thread, so the store sends a fetch's requests one after
      another whatever the bound; it is handed to the store's plan (clamped
      to `S3Config.max_inflight`) for the non-blocking send to honour.
    - `prefetch_depth`: what `prefetch_depth()` reports, the depth of the
      reader's prefetch ring (`PREFETCH_DEPTH_S3_STANDARD`, 64, by default).
    - `upload_part_bytes`: the size of every part of a multipart upload but
      the last, `S3_MIN_PART_BYTES` to `S3_MAX_PART_BYTES` (8 MiB by
      default). An object smaller than one part is one PutObject.
    - `upload_max_inflight`: the parts one upload may have in flight, 1 to
      `S3_FS_UPLOAD_MAX_INFLIGHT_CAP` (8 by default). RECORDED, NOT YET
      ENFORCED: parts are sent one at a time until the send is non-blocking.
    """

    var _prefetch_max_inflight: Int
    var _prefetch_depth: Int
    var _upload_part_bytes: Int
    var _upload_max_inflight: Int

    def __init__(
        out self,
        *,
        prefetch_max_inflight: Int = S3_FS_ALL_RANGES,
        prefetch_depth: Int = PREFETCH_DEPTH_S3_STANDARD,
        upload_part_bytes: Int = S3_FS_DEFAULT_PART_BYTES,
        upload_max_inflight: Int = S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT,
    ) raises:
        """Refuses a setting out of its range (above), naming it."""
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
        if upload_part_bytes < S3_MIN_PART_BYTES or upload_part_bytes > S3_MAX_PART_BYTES:
            raise Error(
                String("S3FsOptions: upload_part_bytes must be ")
                + String(S3_MIN_PART_BYTES)
                + " to "
                + String(S3_MAX_PART_BYTES)
                + ", got "
                + String(upload_part_bytes)
            )
        if upload_max_inflight < 1 or upload_max_inflight > S3_FS_UPLOAD_MAX_INFLIGHT_CAP:
            raise Error(
                String("S3FsOptions: upload_max_inflight must be 1 to ")
                + String(S3_FS_UPLOAD_MAX_INFLIGHT_CAP)
                + ", got "
                + String(upload_max_inflight)
            )
        self._prefetch_max_inflight = prefetch_max_inflight
        self._prefetch_depth = prefetch_depth
        self._upload_part_bytes = upload_part_bytes
        self._upload_max_inflight = upload_max_inflight

    def __init__(out self, _defaults: _S3FsDefaults):
        """The defaults, without the checks (`standard`): it takes no
        value, so it cannot make options the checks would refuse."""
        self._prefetch_max_inflight = S3_FS_ALL_RANGES
        self._prefetch_depth = PREFETCH_DEPTH_S3_STANDARD
        self._upload_part_bytes = S3_FS_DEFAULT_PART_BYTES
        self._upload_max_inflight = S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT

    @staticmethod
    def standard() -> S3FsOptions:
        """The defaults, as `S3FsOptions()` gives them, without `raises`."""
        return S3FsOptions(_S3FsDefaults())

    @always_inline
    def prefetch_max_inflight(self) -> Int:
        return self._prefetch_max_inflight

    @always_inline
    def prefetch_depth(self) -> Int:
        return self._prefetch_depth

    @always_inline
    def upload_part_bytes(self) -> Int:
        return self._upload_part_bytes

    @always_inline
    def upload_max_inflight(self) -> Int:
        return self._upload_max_inflight

    def prefetch_window(self, num_ranges: Int) -> Int:
        """The in-flight bound handed to the store for a call reading
        `num_ranges` ranges: all of them, or the bound when it is smaller.
        1 at least. Recorded, not yet enforced (above)."""
        var window = num_ranges
        if self._prefetch_max_inflight != S3_FS_ALL_RANGES:
            window = min(window, self._prefetch_max_inflight)
        return max(1, window)


struct S3WriteFile(Movable, Deinitable):
    """The `FileSystem.WriteFile` of `S3Fs`: one object being written. It
    holds the bytes of the part not yet sent, the parts sent, and the
    multipart upload's id once the first part has created it."""

    var _key: String
    var _upload_id: String
    var _pending: List[UInt8]
    var _parts: List[S3UploadedPart]
    var _written: Int64
    var _aborted: Bool

    def __init__(out self, var key: String):
        self._key = key^
        self._upload_id = String("")
        self._pending = List[UInt8]()
        self._parts = List[S3UploadedPart]()
        self._written = Int64(0)
        self._aborted = False

    @always_inline
    def key(self) -> String:
        return self._key

    @always_inline
    def upload_id(self) -> String:
        """The multipart upload's id; "" until the first part is sent."""
        return self._upload_id

    @always_inline
    def parts_sent(self) -> Int:
        return len(self._parts)

    @always_inline
    def bytes_written(self) -> Int64:
        """Every byte `write_at` accepted, sent or buffered."""
        return self._written


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
    """The `FileSystem` conformer for one S3 bucket (module header).

        def mk() raises -> MyConnector: ...

        var fs = S3Fs[MyConnector, MyCreds, MyClock](
            "lake", S3Config.aws("us-east-1"), mk, HttpClientConfig.defaults(),
            my_creds, my_clock,
        )
        var footer = fs.read_footer("events/part-0.parquet", 64 * 1024)

    `MyConnector` is any komira_http_core `Connector`; for an https endpoint
    such as AWS's, one whose streams speak TLS.
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
    var _http_config: HttpClientConfig
    var _creds: Self.T
    var _clock: Self.K
    var _store: ArcPointer[Optional[S3Store[Self.C, Self.T, Self.K]]]

    def __init__(
        out self,
        var bucket: String,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        http_config: HttpClientConfig,
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
            http_config: The caller's HTTP client configuration, which each
                store's client is built from (it has no default).
            creds: The credential source requests are signed with.
            clock: The signing clock.
            options: The file system's settings (`S3FsOptions`).
        """
        self._bucket = bucket^
        self._config = config^
        self._options = options
        self._mk_connector = mk_connector
        self._http_config = http_config.copy()
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
        http_config: HttpClientConfig,
        var creds: Self.T,
        var clock: Self.K,
        options: S3FsOptions = S3FsOptions.standard(),
    ) raises -> Self:
        """A file system whose store is built now, so a failure to build it
        (a bad endpoint, a connector that cannot be made) raises here rather
        than on the first verb."""
        var fs = Self(
            bucket^, config^, mk_connector, http_config, creds^, clock^, options
        )
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
            self._http_config,
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
                    self._http_config,
                    self._creds.copy(),
                    self._clock.copy(),
                )
            )

    @always_inline
    def bucket(self) -> String:
        """The bucket this file system reads and writes."""
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
        `If-Match`. The ranges land in one buffer, and each returned buffer
        shares its window of it (no second copy). A zero-length range is an
        empty buffer and is not fetched; a negative offset or length raises,
        and so does a range the object ends before (the store refuses it)."""
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
            # Every range is fetched in full or the store raises (a range
            # past the object, a short or mismatched 206), so the result
            # holds nothing more to check.
            _ = self._store[].value().get_ranges_into(
                self._bucket,
                file._key,
                fetched,
                view,
                self._options.prefetch_window(fetched.num_ranges()),
            )

        var shared = SharedAlignedBuffer.from_owned(joined^)
        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        for i in range(n):
            out.append(shared.share_range_as[HeapRegion](at[i], Int(ranges[i][1])))
        return out^

    @always_inline
    def prefetch_depth(self) -> Int:
        """`S3FsOptions` `prefetch_depth`: 64 for S3 standard unless set."""
        return self._options.prefetch_depth()

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
        var got_offset = Int(tail.offset)
        var got_len = len(tail.bytes)
        if size < 8:
            raise Error(
                "S3Fs.read_footer: object too small for a parquet trailer (size "
                + String(size)
                + " < 8): "
                + path
            )
        var start = speculative_tail_start(size, w)
        if got_offset != start or got_len != size - start:
            raise Error(
                "S3Fs.read_footer: expected the "
                + String(size - start)
                + " trailing bytes of a "
                + String(size)
                + "-byte object, got "
                + String(got_len)
                + " from offset "
                + String(got_offset)
                + " (key: "
                + path
                + ")"
            )
        return FooterRegion(tail^.into_bytes(), start, size)

    def is_dir(self, path: String) raises -> Bool:
        """True iff some key exists under `path/`. S3 has no directories; a
        directory is a prefix with objects under it. A non-empty `path` is
        normalized to end in `/`, so `events` does not match a sibling
        `events.parquet`; the empty path is the bucket root, a directory
        when the bucket holds anything. One `/`-delimited page of one key
        answers it."""
        var probe = path
        if probe.byte_length() > 0 and not probe.endswith(String("/")):
            probe = probe + String("/")
        self._build_if_absent()
        var page = self._store[].value().list_page(
            self._bucket, probe, String("/"), String(""), max_keys=1
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

    def delete(self, path: String) raises -> None:
        """DeleteObject of `path`. Deleting an absent key succeeds (the
        trait's contract, which a spill release deleting a chunk twice
        relies on); any other failure raises."""
        self._build_if_absent()
        self._store[].value().delete(self._bucket, path)

    def fsync_file(self, path: String) raises -> None:
        """Nothing: an object is durable once its PutObject or
        CompleteMultipartUpload is answered (`close_write`)."""
        _ = path

    def fsync_dir(self, dir: String) raises -> None:
        """Nothing: S3 has no directory to flush; a key is visible once its
        object is written."""
        _ = dir

    # ---- Writes ----

    def open_write(self, path: String, mode: WriteMode) raises -> Self.WriteFile:
        """A write handle on the object key `path`, created or overwritten
        whole at `close_write`. Sends nothing: the multipart upload is
        created with the first full part, so an object smaller than one
        part is one PutObject.

        Refuses `WriteMode.append()` (an S3 object cannot be appended to)
        and `WriteMode.create_exclusive()` (S3Fs does not send the
        conditional write it would need)."""
        if mode.is_append():
            raise Error(
                "S3Fs.open_write: an S3 object cannot be appended to (WriteMode.append): " + path
            )
        if mode.is_create_exclusive():
            raise Error(
                "S3Fs.open_write: WriteMode.create_exclusive is not supported;"
                " an object is created or overwritten whole: " + path
            )
        return S3WriteFile(path)

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        """Appends `data` to the object and returns `len(data)`. Each time
        `upload_part_bytes` are buffered they are sent as the next part (the
        first creating the upload). A part that fails aborts the upload
        before the error is raised, and the handle is refused from then on.
        Empty input is a no-op."""
        if file._aborted:
            raise Error(
                "S3Fs.write_at: the upload of " + file._key + " failed and was aborted"
            )
        var n = len(data)
        var part_bytes = self._options.upload_part_bytes()
        var at = 0
        try:
            while at < n:
                var take = min(part_bytes - len(file._pending), n - at)
                file._pending.extend(data[at : at + take])
                at += take
                file._written += Int64(take)
                if len(file._pending) == part_bytes:
                    self._send_part(file)
        except e:
            raise self._abort_after(file, e)
        return Int64(n)

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error(
            "S3Fs.pwrite_at: S3 has no disjoint-range concurrent write"
            " (SUPPORTS_PARALLEL_WRITES = False); use write_at."
        )

    def close_write(self, var file: Self.WriteFile) raises -> None:
        """Commits the object: one PutObject of the buffered bytes when no
        part was sent (an empty object included), else the last part, if
        any bytes are buffered, and CompleteMultipartUpload. A failure
        aborts the upload before the error is raised."""
        if file._aborted:
            raise Error(
                "S3Fs.close_write: the upload of " + file._key + " failed and was aborted"
            )
        try:
            self._build_if_absent()
            if file._upload_id.byte_length() == 0:
                _ = self._store[].value().conditional_put(
                    self._bucket, file._key, file._pending, WritePrecondition.none()
                )
                return
            if len(file._pending) > 0:
                self._send_part(file)
            _ = self._store[].value().complete_multipart_upload(
                self._bucket, file._key, file._upload_id, file._parts
            )
        except e:
            raise self._abort_after(file, e)

    def abort_write(self, var file: Self.WriteFile) raises -> None:
        """Discards the object: AbortMultipartUpload when a part was sent
        (an upload already gone counts as aborted), nothing otherwise, and
        nothing for an upload a failure already aborted."""
        if file._aborted or file._upload_id.byte_length() == 0:
            return
        self._build_if_absent()
        self._store[].value().abort_multipart_upload(
            self._bucket, file._key, file._upload_id
        )

    def _send_part(self, mut file: Self.WriteFile) raises:
        """Sends the buffered bytes as the next part, creating the upload
        first if this is its first part."""
        self._build_if_absent()
        if file._upload_id.byte_length() == 0:
            file._upload_id = self._store[].value().create_multipart_upload(
                self._bucket, file._key
            )
        var part = self._store[].value().upload_part(
            self._bucket, file._key, file._upload_id, len(file._parts) + 1, file._pending
        )
        file._parts.append(part^)
        file._pending.clear()

    def _abort_after(self, mut file: Self.WriteFile, cause: Error) -> Error:
        """`cause`, after aborting the upload (if one was created) and
        marking the handle aborted. An abort that fails too is named in the
        error, with the upload id, so the upload can be found."""
        file._aborted = True
        file._pending = List[UInt8]()
        if file._upload_id.byte_length() == 0:
            return Error(String(cause))
        try:
            self._build_if_absent()
            self._store[].value().abort_multipart_upload(
                self._bucket, file._key, file._upload_id
            )
        except abort_error:
            return Error(
                String(cause)
                + "; and AbortMultipartUpload of upload "
                + file._upload_id
                + " failed: "
                + String(abort_error)
            )
        return Error(String(cause))
