# =============================================================================
# komira_azure_blob/azure_fs.mojo — AzureFs[C], the FileSystem conformer
# =============================================================================
#
# `AzureFs[C: Connector]` is komira_fs's `FileSystem` for Azure Blob
# (az:// / abfs://) URIs, the sibling of komira_objectstore_s3's `S3Fs` and
# komira_objectstore_gcs's `GcsFs`. It OWNS its `AzureClient[C]`, in a
# length-1 `Slab`, and the `AzureClientSpec[C]` (endpoint, credential,
# connector factory) every client it or a clone builds is made from.
#
# Usage:
#     def mk_connector() raises -> MyConnector:
#         return MyConnector.new()
#     var spec = AzureClientSpec[MyConnector](
#         AzureConfig.azure("mystoraccount"),
#         AzureCredential.shared_key(
#             AzureSharedKey("mystoraccount", account_key_b64)
#         ),
#         mk_connector,
#     )
#     var azure_fs = AzureFs[MyConnector](container="my-container", spec=spec)
#
# That form builds its client on the first verb, so constructing it dials
# nothing. `AzureFs(container=, client=, spec=)` seeds the first client
# instead (a test's scripted one); clones still build theirs from `spec`.
#
# The `container` plays the role S3/GCS give `bucket`. The blob key is
# the path passed to `open()`.
#
# `abfs://` alias note: an `abfs://<container>@<account>...` URI is served
# by the FLAT Blob API — the AzureFs container maps to the ABFS filesystem
# and the blob path to the ABFS file path. The wire shape of a range-GET
# read is identical; hierarchical-namespace operations are not exposed.
#
# Read-only: every write verb raises.
#
# No Arc, no wildcard origin, no UnsafePointer in any signature, no
# unsafe_from_address, no take_pointee.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_fs.file_system import FileSystem, WriteMode
from komira_fs.footer_region import (
    FooterRegion,
    speculative_tail_start,
)
from komira_fs.shallow_dir_entry import (
    ShallowDirEntry,
    _shallow_basename,
)
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE

from komira_http_core.transport.io_stream import Connector

from .azure_client import AzureClient
from .azure_client_spec import AzureClientSpec


# The most List Blobs pages one listing (`list` or `list_dir_shallow`)
# drains before it raises, as GcsFs does with GCS_LIST_MAX_PAGES. A service
# or proxy that keeps returning a non-empty `<NextMarker>` (the same one
# forever, say) would otherwise spin the loop, and grow its result, without
# bound. At 5000 entries a page (Azure's maximum) this admits 500 million
# names, far past any listing this filesystem is meant to serve.
comptime AZURE_LIST_MAX_PAGES: Int = 100_000


# =============================================================================
# AzureWriteFile — sentinel WriteFile type (read-only Azure in this slot)
# =============================================================================


@fieldwise_init
struct AzureWriteFile(Movable, Deinitable):
    """Sentinel WriteFile type: AzureFs is read-only (no block upload).
    Satisfies the FileSystem trait surface; every write method raises."""

    var _path: String


@fieldwise_init
struct AzureFileHandle(Movable, Deinitable):
    """A per-blob handle returned by `AzureFs.open(key)`. Stores the
    Azure blob key for subsequent `AzureFs.read_at(...)` calls.
    Lightweight POD — the connection pool lives on the caller-owned
    AzureClient the AzureFs borrows."""

    var _key: String

    @always_inline
    def key(self) -> String:
        return self._key


# =============================================================================
# AzureFs[C] — FileSystem conformer (owns its AzureClient behind a Box)
# =============================================================================


struct AzureFs[C: Connector](FileSystem, Movable, Deinitable):
    """FileSystem conformer for Azure Blob URIs. OWNS its `AzureClient[C]`
    (owns its client).

    The AzureClient is OWNED in a length-1 `Slab`, reached mutably from
    immutable `self` via `get_mut_interior(0)` (interior mutability), so
    the read verbs need no `mut self`.

    Each worker constructs its OWN AzureClient + AzureFs; the HttpClient
    pool inside is per-pthread single-thread-access by design.

    The `AzureClientSpec[C]` is threaded in at construction; a missing
    client (the lazy form's, a clone's) is built from it on the first verb
    (the HttpClient pool is OWNED + NOT Copyable).

    Fields:
      * `_container: String` — the Azure container name (owned).
      * `_client: Slab[AzureClient[C]]` — OWNED client in a length-1 Slab;
        the read methods reach it mutably from immutable `self` via
        `get_mut_interior(0)`.
      * `_spec: AzureClientSpec[C]` — what each client is built from.
    """

    comptime File = AzureFileHandle
    comptime WriteFile = AzureWriteFile
    # Azure block-blob writes are block-list-serial; no disjoint-range
    # pwrite atomicity. Gate False so SDK callers branch at comptime.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = False

    # AzureFs has a working `list_dir_shallow` (BlobPrefixes -> dir / Blob
    # -> file) and a paginated recursive `list` (NextMarker loop), so a
    # lazy Hive discovery can prune partitions over it. The flag asserts
    # list + list_dir_shallow work for prefix pruning, nothing more.
    comptime SUPPORTS_LAZY_HIVE: Bool = True

    # The scheme tag: FS_SCHEME_AZURE, the code komira_source_url maps
    # az://, abfs[s]:// and Azure Blob https:// URLs to.
    comptime SCHEME: UInt8 = FS_SCHEME_AZURE

    var _container: String
    # OWNED client in a length-1 `Slab[Optional[...]]`, built LAZILY on the
    # first read (the FileSystem trait's `clone()` is INFALLIBLE but the
    # AzureClient ctor is FALLIBLE + the pool is OWNED+NOT-Copyable); reached
    # mutably from immutable `self` via `get_mut_interior(0)`. The initial FS
    # seeds slot 0; clones start with an EMPTY slab (built on first read).
    var _client: Slab[Optional[AzureClient[Self.C]]]
    # What the lazy build (the lazy form's first verb, a clone's) makes a
    # client from: endpoint, credential and connector factory.
    var _spec: AzureClientSpec[Self.C]

    def __init__(
        out self,
        var container: String,
        var client: AzureClient[Self.C],
        var spec: AzureClientSpec[Self.C],
    ):
        """Construct an AzureFs bound to `container`, seeding slot 0 of the
        length-1 client slab with `client`; clones build theirs from `spec`.

        Args:
            container: Azure container name. Moved in.
            client: A configured `AzureClient[C]` (`is_configured() ==
                True`), MOVED in + OWNED by the AzureFs (seeds slot 0).
            spec: What a clone's client is built from.
        """
        self._container = container^
        var slab = Slab[Optional[AzureClient[Self.C]]]()
        slab.append(Optional[AzureClient[Self.C]](client^))
        self._client = slab^
        self._spec = spec^

    def __init__(out self, var container: String, var spec: AzureClientSpec[Self.C]):
        """Construct an AzureFs bound to `container` whose client is built
        from `spec` on the first verb: nothing is built or dialed here."""
        self._container = container^
        var slab = Slab[Optional[AzureClient[Self.C]]]()
        slab.append(Optional[AzureClient[Self.C]](None))
        self._client = slab^
        self._spec = spec^

    def __init__(
        out self,
        var _container: String,
        var _client: Slab[Optional[AzureClient[Self.C]]],
        var _spec: AzureClientSpec[Self.C],
    ):
        """INTERNAL fieldwise ctor — used by `clone()` (infallible)."""
        self._container = _container^
        self._client = _client^
        self._spec = _spec^

    # ---- FileSystem trait conformance ----

    def clone(self) -> Self:
        """Return a fresh `AzureFs[C]` with the same container + spec and
        an EMPTY (lazily-built) client slab. INFALLIBLE per the FileSystem
        trait; the AzureClient is built on the clone's FIRST read (it cannot
        be deep-copied, and the ctor is fallible)."""
        var slab = Slab[Optional[AzureClient[Self.C]]]()
        slab.append(Optional[AzureClient[Self.C]](None))
        return Self(
            _container=self._container.copy(),
            _client=slab^,
            _spec=self._spec.copy(),
        )

    # ---- Lazy client build (private helper, inlined into read methods) ----
    def _build_client_if_absent(self) raises:
        # SAFETY: get_mut_interior(0) invariants — single worker (slot 0
        # only); `self` outlives the locally-bound ref; slab sized 1, never
        # grown; single-threaded.
        ref slot = self._client.get_mut_interior(0)
        if not slot:
            slot = Optional[AzureClient[Self.C]](self._spec.build())
        # Defensive sentinel guard: a configured client is required to read.
        if not slot.value().is_configured():
            raise Error(
                "AzureFs: owned AzureClient is the sentinel (not"
                " configured). Construct + seed/clone from a configured"
                " client."
            )

    @always_inline
    def container(self) -> String:
        """The Azure container name this AzureFs is bound to."""
        return self._container

    def spec(self) -> AzureClientSpec[Self.C]:
        """A copy of the spec this file system builds its clients from."""
        return self._spec.copy()

    def client_built(self) -> Bool:
        """True once this file system holds a client (seeded, or built by
        a verb)."""
        # SAFETY: get_mut_interior(0) invariants as `_build_client_if_absent`.
        return Bool(self._client.get_mut_interior(0))

    def list(self, prefix: String) raises -> List[String]:
        """List Azure blob keys under `prefix` (RECURSIVE — all blobs at any
        depth), as bare blob names (relative to `self._container`).

        `AzureStore.list_page` is single-page, so the pagination loop
        lives HERE, following `<NextMarker>` (Azure's pagination sibling of
        S3's `NextContinuationToken` / GCS's `next_marker`) until
        `is_truncated()` is False, aggregating `<Blob><Name>` entries, with
        a "truncated-but-empty-marker" termination guard against a
        non-conforming proxy looping forever on the same URL, and a page cap:
        a service that keeps returning a non-empty `<NextMarker>` (the same
        one forever, say) gets AZURE_LIST_MAX_PAGES requests and then an
        error, never an unbounded loop.

        RECURSIVE listing (no delimiter), as S3Fs.list and GcsFs.list do:
        the `FileSystem.list` trait carries no recursive
        flag and the discovery layer re-filters client-side via
        `glob_match_path`. A recursive list is always a correct superset.

        KEY FORM: returns each `AzureBlobEntry.name` UNCHANGED (the bare blob
        name). This is the form `AzureFs.open` consumes (`open(path)` stores
        `path` verbatim as `AzureFileHandle._key`; `read_at` issues the GET
        against `(self._container, file._key)`). The `list` -> discovery ->
        `open` round-trip is bare-key throughout; we deliberately do NOT
        re-prepend `az://container/` (that would break the round-trip) — the
        same key-form S3/GCS use.

        # THREAD-SAFETY: per-worker-owned AzureClient (see read_at). The
        # borrowed store/connector/reactor are bound LOCALLY via the
        # interior-mut slot; the wildcard origin never escapes a signature.

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured).
          * HTTP 4xx/5xx via AzureStore.list_page's error channel.
          * After AZURE_LIST_MAX_PAGES pages that each carry a `<NextMarker>`
            ("page cap exceeded").
        """
        # Interior-mut ref to the owned AzureClient (single-worker;
        # slab sized 1, never grown).
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor

        var out = List[String]()
        var marker = String("")
        var pages = 0
        # Pagination loop (mirror GcsFs.list): follow next_marker until
        # is_truncated() is False, at most AZURE_LIST_MAX_PAGES requests.
        # Flat listing -> delimiter="".
        while True:
            pages += 1
            if pages > AZURE_LIST_MAX_PAGES:
                raise Error(
                    String("AzureFs.list: page cap exceeded (")
                    + String(AZURE_LIST_MAX_PAGES)
                    + String(" List Blobs pages and the service still returns"
                    " a NextMarker)")
                )
            var page = store_opt.value().list_page[
                PerCoreAsyncRuntime[NoopSink], Self.C,
            ](
                self._container,
                prefix,
                String(""),
                marker,
                connector_opt.value(),
                reactor_opt.value(),
            )
            for i in range(len(page.blobs)):
                out.append(page.blobs[i].name.copy())
            if not page.is_truncated():
                break
            # Defensive: truncated but no marker -> terminate to avoid an
            # infinite re-issue of the same URL (non-conforming proxy).
            if page.next_marker.byte_length() == 0:
                break
            marker = page.next_marker.copy()
        return out^

    def open(self, path: String) raises -> Self.File:
        """Open a read-handle for `path` (the Azure blob key — container
        is set at AzureFs construction time). No HTTP traffic; lazy at
        first `read_at`."""
        return AzureFileHandle(_key=path)

    @always_inline
    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Read `length` bytes from `offset` in `file` (an Azure blob key)
        via the Azure Blob REST GET-Range API.

        Drives `AzureStore.get_range[PerCoreAsyncRuntime[NoopSink], C]`
        through the borrowed AzureClient[C]; copies the returned
        `List[UInt8]` into an owning aligned buffer (one alloc + one
        memcpy per range, dominated by network latency).

        # THREAD-SAFETY:
        The borrowed AzureClient[C] is per-worker (caller-owned on the
        caller's stack frame). The HttpClient pool inside is per-pthread
        single-thread-access by design. NO cross-worker sharing; NO Arc;
        concurrent dispatch is safe BECAUSE each worker has its own
        client.

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured):
            clear error pointing at the construction-site gating bug.
          * HTTP 4xx/5xx surface via AzureStore.get_range's error channel.
          * Truncated response surfaces as a length mismatch.
        """
        # Interior-mut ref to the owned AzureClient through
        # immutable `self` (single-worker; slab sized 1, never grown).
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor

        var end_inclusive = offset + length - Int64(1)

        var bytes = store_opt.value().get_range[
            PerCoreAsyncRuntime[NoopSink], Self.C,
        ](
            self._container,
            file._key,
            offset,
            end_inclusive,
            connector_opt.value(),
            reactor_opt.value(),
        )

        if Int64(bytes.__len__()) != length:
            raise Error(
                "AzureFs.read_at: short read — requested "
                + String(Int(length))
                + " bytes, got "
                + String(bytes.__len__())
                + " (blob key: " + file._key + ")"
            )

        var buf = OwnedAlignedBuffer(Int(length))
        var dst = buf.view_range_mut(0, Int(length))
        # SAFETY: `dst` is rooted in the owning `buf` allocated on the
        # preceding line; `bytes.unsafe_ptr()` aliases the response body
        # bytes owned in this frame. Both pointers are valid for the
        # duration of memcpy; neither is stored. Bounds enforced by the
        # length check above. Identical to S3Fs / GcsFs read_at.
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
        """Fan-out read of N
        `(offset, length)` ranges from `file` (an Azure blob key),
        returning one owning buffer per range in INPUT ORDER.

        This conformer is the SEQUENTIAL form — one `read_at` per range,
        in source order, no in-flight overlap (the shape of
        `LocalFs.read_ranges_prefetched`). An N-in-flight form, as S3Fs
        has, is not written for Azure.

        # THREAD-SAFETY: identical to `read_at` — each per-call `read_at`
        # drives the per-worker-owned AzureClient on its own pthread; no
        # cross-worker sharing, no Arc.

        Returns a `Slab[SharedAlignedBuffer[HeapRegion]]` of size N; entry
        `i` is the owning buffer for `ranges[i]`.
        """
        var out = Slab[SharedAlignedBuffer[HeapRegion]]()
        var i = 0
        var n = ranges.__len__()
        while i < n:
            var offset_len = ranges[i]
            var buf = self.read_at(file, offset_len[0], offset_len[1])
            out.append(buf^)
            i = i + 1
        return out^

    @always_inline
    def prefetch_depth(self) -> Int:
        """Azure standard prefetch depth — 64, same as S3 / GCS standard
        (all are networked object stores with similar RTT)."""
        return 64

    @always_inline
    def supports_random_read(self) -> Bool:
        """True — Azure Blob supports HTTP Range-GET random-access reads."""
        return True

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        """Bounded speculative tail read of `path` via the Azure Blob REST
        GET-Range API — the trailing region bytes plus the blob's total size.

        `window` is the caller's choice of how many trailing bytes to read.
        The size rides back on `FooterRegion`, so a caller needs no second
        `file_size`. This conformer still needs the size BEFORE the read —
        the Azure Blob `x-ms-range`
        header has NO suffix form (`bytes=-N` is not part of the Azure REST
        range grammar; only `bytes=A-B` and the open-ended `bytes=A-`), so
        unlike S3 it cannot name the tail without knowing the length. Azure
        therefore pays 2 requests here where S3 pays 1. That is one round
        trip per BLOB per session, not per worker.

        This is the footer source a parquet reader calls for a non-mmap
        file system.

        # THREAD-SAFETY: same per-worker-owned-AzureClient contract as
        # `read_at` (see its docstring) — the borrowed AzureClient is
        # caller-owned + per-worker; no cross-worker sharing.

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured).
          * HTTP 4xx/5xx via AzureStore.head / get_range error channel.
          * Blob smaller than the 8-byte parquet trailer minimum.
        """
        var size = self.file_size(path)
        if size < 8:
            raise Error(
                "AzureFs.read_footer: blob too small for a parquet"
                " trailer (size " + String(size) + " < 8): " + path
            )

        var region_start = speculative_tail_start(size, window)
        var read_count = size - region_start
        var start = Int64(region_start)
        var end_inclusive = Int64(size - 1)

        # Borrow the per-call Store + Connector + Reactor from the client
        # (same shape as read_at). is_configured() guarantees all three
        # Optionals are populated.
        # Interior-mut ref to the owned AzureClient through
        # immutable `self` (single-worker; slab sized 1, never grown).
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor

        var bytes = store_opt.value().get_range[
            PerCoreAsyncRuntime[NoopSink], Self.C,
        ](
            self._container,
            path,
            start,
            end_inclusive,
            connector_opt.value(),
            reactor_opt.value(),
        )
        if bytes.__len__() != read_count:
            raise Error(
                "AzureFs.read_footer: short read — requested "
                + String(read_count)
                + " bytes, got "
                + String(bytes.__len__())
                + " (blob key: " + path + ")"
            )
        return FooterRegion(bytes^, region_start, size)

    def is_dir(self, path: String) raises -> Bool:
        """Azure `is_dir` — True iff at least one blob exists under `path/`.

        A name like `events` with no trailing `/` is a directory when blobs
        exist under `events/`. Azure has no real directories; a "directory" is a prefix under which
        at least one blob exists. We probe with a SHALLOW (`delimiter="/"`)
        single-page `list_page`: if any `<Blob>` or `<BlobPrefix>` comes back,
        the prefix names a directory-like subtree. One cheap page.

        The probe prefix is normalized to end with `/` so `is_dir("events")`
        probes `events/` (not the `events*` prefix, which would also match a
        sibling blob `events.parquet`).

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured).
          * HTTP 4xx/5xx via AzureStore.list_page's error channel.
        """
        var probe_prefix = path
        if not probe_prefix.endswith(String("/")):
            probe_prefix = probe_prefix + String("/")
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor
        var page = store_opt.value().list_page[
            PerCoreAsyncRuntime[NoopSink], Self.C,
        ](
            self._container,
            probe_prefix,
            String("/"),
            String(""),
            connector_opt.value(),
            reactor_opt.value(),
        )
        return len(page.blobs) > 0 or len(page.blob_prefixes) > 0

    def list_dir_shallow(
        self, prefix: String
    ) raises -> List[ShallowDirEntry]:
        """SHALLOW (one-level) listing of the immediate children under
        `prefix`, as `GcsFs.list_dir_shallow` and `S3Fs.list_dir_shallow`
        do. Each `<BlobPrefix>` fold
        maps to a directory entry, each `<Blob>` name to a file entry. NOT
        recursive: the lazy Hive partition-schema probe walks `key=value`
        levels one at a time WITHOUT enumerating the leaf data files.

        Prefix normalization (load-bearing — same as `is_dir`): the probe
        prefix is normalized to end with `/` so `list_dir_shallow("events")`
        lists under `events/` and does NOT over-match a sibling blob
        `events.parquet`. An already-slash-terminated prefix is left as-is;
        the EMPTY prefix (container root) is left un-normalized.

        Like GCS (whose `GcsStore.list_page` is single-page),
        `AzureStore.list_page` exposes only a single page, so the pagination
        loop lives HERE — mirroring `AzureFs.list`'s loop over `<NextMarker>`
        until `is_truncated()` is False, including the defensive
        truncated-but-empty-marker termination guard (non-conforming proxy)
        and the AZURE_LIST_MAX_PAGES page cap. Here we list WITH `delimiter="/"` to get the one-level folded view.

        KEY FORM: returned entry names are BARE final path components (G.3
        finding). We do NOT re-prepend `az://container/`.

        # THREAD-SAFETY: per-worker-owned AzureClient (see read_at). The
        # borrowed store/connector/reactor are bound locally via the
        # interior-mut slot; no wildcard origin escapes a signature.

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured).
          * HTTP 4xx/5xx via AzureStore.list_page's error channel.
          * After AZURE_LIST_MAX_PAGES pages that each carry a `<NextMarker>`
            ("page cap exceeded").
        """
        var probe_prefix = prefix
        if probe_prefix.byte_length() > 0 and not probe_prefix.endswith(String("/")):
            probe_prefix = probe_prefix + String("/")
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor

        var out = List[ShallowDirEntry]()
        var marker = String("")
        var pages = 0
        # Pagination loop (mirror AzureFs.list): follow next_marker until
        # is_truncated() is False, but WITH delimiter="/" for the one-level
        # folded view. BlobPrefixes -> dirs, Blobs -> files; the cloud store
        # returns keys lexicographically, and we append in arrival order so the
        # natural sorted order survives across pages. At most
        # AZURE_LIST_MAX_PAGES requests, as `list`.
        while True:
            pages += 1
            if pages > AZURE_LIST_MAX_PAGES:
                raise Error(
                    String("AzureFs.list_dir_shallow: page cap exceeded (")
                    + String(AZURE_LIST_MAX_PAGES)
                    + String(" List Blobs pages and the service still returns"
                    " a NextMarker)")
                )
            var page = store_opt.value().list_page[
                PerCoreAsyncRuntime[NoopSink], Self.C,
            ](
                self._container,
                probe_prefix,
                String("/"),
                marker,
                connector_opt.value(),
                reactor_opt.value(),
            )
            for i in range(len(page.blob_prefixes)):
                out.append(
                    ShallowDirEntry(
                        name=_shallow_basename(page.blob_prefixes[i]),
                        is_dir=True,
                    )
                )
            for i in range(len(page.blobs)):
                # Skip the prefix-placeholder key (`probe_prefix`, e.g.
                # `events/`) that a delimiter list can echo back as a
                # zero-byte Blob marker — it is the directory itself. (Guard
                # against key == probe_prefix, NOT empty-basename.)
                ref name = page.blobs[i].name
                if name == probe_prefix:
                    continue
                var base = _shallow_basename(name)
                if base.byte_length() == 0:
                    continue
                out.append(ShallowDirEntry(name=base^, is_dir=False))
            if not page.is_truncated():
                break
            # Defensive: truncated but no marker -> terminate to avoid an
            # infinite re-issue of the same URL (non-conforming proxy).
            if page.next_marker.byte_length() == 0:
                break
            marker = page.next_marker.copy()
        return out^

    def file_size(self, path: String) raises -> Int:
        """Get blob size via HEAD.

        Implemented against `AzureStore.head` through the same per-worker
        AzureClient as `read_at` / `read_footer`.

        # THREAD-SAFETY: per-worker-owned AzureClient (see read_at).

        Raises:
          * If the borrowed AzureClient is the sentinel (not configured).
          * HTTP 4xx/5xx via AzureStore.head error channel (404).
          * Negative Content-Length (blob size unavailable).
        """
        # Interior-mut ref to the owned AzureClient through
        # immutable `self` (single-worker; slab sized 1, never grown).
        self._build_client_if_absent()
        ref client = self._client.get_mut_interior(0).value()
        ref store_opt = client._inner_store
        ref connector_opt = client._inner_connector
        ref reactor_opt = client._inner_reactor
        var meta = store_opt.value().head[
            PerCoreAsyncRuntime[NoopSink], Self.C,
        ](
            self._container,
            path,
            connector_opt.value(),
            reactor_opt.value(),
        )
        if meta.size < Int64(0):
            raise Error(
                "AzureFs.file_size: HEAD returned no Content-Length for"
                " blob key: " + path
            )
        return Int(meta.size)

    # =========================================================================
    # WRITE-side stubs (read-only: no block upload)
    # =========================================================================

    def open_write(
        self, path: String, mode: WriteMode
    ) raises -> Self.WriteFile:
        raise Error(
            "AzureFs.open_write: AzureFs is read-only (no block-blob"
            " upload). path=",
            path,
        )

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error(
            "AzureFs.write_at: AzureFs is read-only (no block-blob"
            " upload)."
        )

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error(
            "AzureFs.pwrite_at: Azure block-blob does not support"
            " disjoint-range concurrent writes (SUPPORTS_PARALLEL_WRITES"
            " = False). Use a parallel-write-capable conformer or"
            " serialize via write_at."
        )

    def close_write(
        self, var file: Self.WriteFile
    ) raises -> None:
        raise Error(
            "AzureFs.close_write: AzureFs is read-only (no block-blob"
            " upload)."
        )
