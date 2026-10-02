# =============================================================================
# komira_objectstore_gcs/fake_backend.mojo
#   FakeGcsStorageBackend — an in-memory GcsStorageBackend with GCS
#   generation semantics, for hermetic tests. No socket, no credentials.
# =============================================================================
#
# A PUBLIC TEST DOUBLE. Tests of code that sits above `GcsConditionalStore[B]`
# or `GcsFs[B]` instantiate them over this type; no binary should. It models
# the google.storage.v2 object verbs with the generation-based CAS the live
# service enforces, and raises the same `StoreError[<KIND>] ... status=<http>`
# messages a network backend raises for a FAILED_PRECONDITION / NOT_FOUND, so
# a conformer behaves the same over it as over the live service. Listings come
# back in name (byte) order and page as the service pages them.
#
# Storage is a plain owned `List` of value entries; no UnsafePointer.
# =============================================================================

from .backend import GcsStorageBackend, ListPageRaw, ObjectMetaRaw


@fieldwise_init
struct _FakeEntry(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]
    var generation: Int64


struct FakeGcsStorageBackend(GcsStorageBackend, Movable, Deinitable):
    """An in-memory `GcsStorageBackend` for tests.

    Generation model (as GCS): each object carries a monotone integer
    generation, minted fresh on every successful write. Create-if-absent
    succeeds only when the key is absent; compare_and_swap(expected) succeeds
    only when the live generation equals `expected`. A miss raises
    `StoreError[PRECONDITION] ... status=412`; a read, head or delete of an
    absent key raises `StoreError[NOT_FOUND] ... status=404`.

    Listing (as GCS): objects and folded common prefixes come back merged in
    name (byte) order, at most `page_size` of them per page (0: one page
    holding everything); `next_page_token` resumes after the last name of the
    page.

    The bucket argument is carried into error messages only: one fake models
    one bucket.

    Single owner, single thread. A `GcsConditionalStore` or `GcsFs` clone
    builds a FRESH backend from its factory, so a clone does not see this
    fake's objects; a test that needs to observe data drives the original.
    """

    var _entries: List[_FakeEntry]
    var _gen_counter: Int64
    var _page_size: Int

    def __init__(out self):
        """An empty fake whose listings come back in one page."""
        self._entries = List[_FakeEntry]()
        self._gen_counter = Int64(0)
        self._page_size = 0

    def __init__(out self, page_size: Int):
        """An empty fake whose listings hold at most `page_size` entries
        (objects plus common prefixes) per page; 0 means one page."""
        self._entries = List[_FakeEntry]()
        self._gen_counter = Int64(0)
        self._page_size = page_size if page_size > 0 else 0


    def _find(self, key: String) -> Int:
        for i in range(len(self._entries)):
            if self._entries[i].key == key:
                return i
        return -1

    def _next_generation(mut self) -> Int64:
        # GCS generations are large monotone integers whose value is opaque to
        # callers; a counter over a realistic base models that.
        self._gen_counter += Int64(1)
        return Int64(1_700_000_000_000_000) + self._gen_counter

    @staticmethod
    def _precondition_error(
        method: String, bucket: String, key: String, detail: String
    ) -> Error:
        return Error(
            String("StoreError[PRECONDITION] ")
            + method
            + " gs://"
            + bucket
            + "/"
            + key
            + " status=412 grpc_code=9 grpc_detail="
            + detail
        )

    @staticmethod
    def _not_found_error(method: String, bucket: String, key: String) -> Error:
        return Error(
            String("StoreError[NOT_FOUND] ")
            + method
            + " gs://"
            + bucket
            + "/"
            + key
            + " status=404 grpc_code=5 grpc_detail=object not found"
        )

    # ---- GcsStorageBackend conformance ----

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        if self._find(key) >= 0:
            raise Self._precondition_error(
                String("WriteObject"),
                bucket,
                key,
                String("create-if-absent: object already exists"),
            )
        var gen = self._next_generation()
        self._entries.append(_FakeEntry(key, data.copy(), gen))
        return gen

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        var idx = self._find(key)
        if idx < 0:
            # The service rejects if_generation_match=<n> on an absent object.
            raise Self._precondition_error(
                String("WriteObject"),
                bucket,
                key,
                String("compare-and-swap: object absent"),
            )
        if self._entries[idx].generation != expected_generation:
            raise Self._precondition_error(
                String("WriteObject"),
                bucket,
                key,
                String("compare-and-swap: stale generation"),
            )
        var gen = self._next_generation()
        self._entries[idx].bytes = data.copy()
        self._entries[idx].generation = gen
        return gen

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        if read_offset < Int64(0) or read_limit < Int64(0):
            # The seam's precondition. The wire gives a negative offset a
            # suffix meaning this fake does not model, so it refuses rather
            # than read the wrong bytes.
            raise Error(
                String("StoreError[MALFORMED] ReadObject gs://")
                + bucket
                + "/"
                + key
                + " status=400 grpc_code=3 grpc_detail=negative read_offset ("
                + String(read_offset)
                + ") or read_limit ("
                + String(read_limit)
                + ")"
            )
        var idx = self._find(key)
        if idx < 0:
            raise Self._not_found_error(String("ReadObject"), bucket, key)
        ref e = self._entries[idx]
        var n = len(e.bytes)
        var start = Int(read_offset)
        if start > n:
            start = n
        var end = n
        if read_limit > Int64(0):
            var lim_end = start + Int(read_limit)
            if lim_end < end:
                end = lim_end
        var out = List[UInt8]()
        for i in range(start, end):
            out.append(e.bytes[i])
        return out^

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        var idx = self._find(key)
        if idx < 0:
            raise Self._not_found_error(String("GetObject"), bucket, key)
        ref e = self._entries[idx]
        return ObjectMetaRaw(
            key=e.key,
            size=Int64(len(e.bytes)),
            generation=e.generation,
            etag=String(""),
        )

    def delete_object(mut self, bucket: String, key: String) raises:
        """Deletes `key`; an absent key raises NOT_FOUND, as DeleteObject
        does."""
        var idx = self._find(key)
        if idx < 0:
            raise Self._not_found_error(String("DeleteObject"), bucket, key)
        var keep = List[_FakeEntry]()
        for i in range(len(self._entries)):
            if i != idx:
                keep.append(self._entries[i].copy())
        self._entries = keep^

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        """One page of the listing under `prefix`. Models the service's
        directory fold:
          * `delimiter == ""`: every key under `prefix` lands in `objects`.
          * otherwise: a key whose remainder after `prefix` contains the
            delimiter is folded to its name up to and including the first
            delimiter, emitted once in `common_prefixes`; other keys land in
            `objects`.
        Objects and prefixes are merged in name (byte) order; a page holds the
        first `page_size` names after `page_token` (the last name of the
        previous page)."""
        # The merged listing: every name, and the entry index of each object
        # (-1 for a folded prefix).
        var names = List[String]()
        var entry_of = List[Int]()
        var use_delim = delimiter.byte_length() > 0
        for i in range(len(self._entries)):
            ref e = self._entries[i]
            if not _starts_with(e.key, prefix):
                continue
            if use_delim:
                var fold_end = _find_delim_after(
                    e.key, prefix.byte_length(), delimiter
                )
                if fold_end >= 0:
                    var cp = _prefix_bytes(
                        e.key, fold_end + delimiter.byte_length()
                    )
                    if not _contains_str(names, cp):
                        names.append(cp^)
                        entry_of.append(-1)
                    continue
            names.append(e.key.copy())
            entry_of.append(i)

        # Insertion sort by byte order; a fake's listings are small.
        for i in range(1, len(names)):
            var j = i
            while j > 0 and _bytes_less(names[j], names[j - 1]):
                var tn = names[j].copy()
                names[j] = names[j - 1].copy()
                names[j - 1] = tn^
                var te = entry_of[j]
                entry_of[j] = entry_of[j - 1]
                entry_of[j - 1] = te
                j -= 1

        var resume = page_token.byte_length() > 0
        var objects = List[ObjectMetaRaw]()
        var common = List[String]()
        var taken = 0
        var next_token = String("")
        for i in range(len(names)):
            if resume and not _bytes_less(page_token, names[i]):
                continue
            if self._page_size > 0 and taken == self._page_size:
                next_token = names[i - 1].copy()
                break
            taken += 1
            if entry_of[i] < 0:
                common.append(names[i].copy())
            else:
                ref e = self._entries[entry_of[i]]
                objects.append(
                    ObjectMetaRaw(
                        key=e.key,
                        size=Int64(len(e.bytes)),
                        generation=e.generation,
                        etag=String(""),
                    )
                )
        return ListPageRaw(objects^, common^, next_token^)


@always_inline
def _starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _bytes_less(a: String, b: String) -> Bool:
    """True iff `a` sorts before `b` in byte order (GCS's name order)."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return len(ab) < len(bb)


def _find_delim_after(s: String, start: Int, delim: String) -> Int:
    """The byte index of the first `delim` in `s` at or after byte `start`, or
    -1."""
    var sb = s.as_bytes()
    var db = delim.as_bytes()
    var n = len(sb)
    var m = len(db)
    if m == 0 or n < m:
        return -1
    var i = start
    while i + m <= n:
        var matched = True
        for j in range(m):
            if sb[i + j] != db[j]:
                matched = False
                break
        if matched:
            return i
        i += 1
    return -1


def _contains_str(items: List[String], needle: String) -> Bool:
    for i in range(len(items)):
        if items[i] == needle:
            return True
    return False


def _prefix_bytes(s: String, n: Int) -> String:
    """The first `n` bytes of `s`, byte for byte.

    Keys are arbitrary UTF-8, so this copies bytes; building the result one
    `chr(byte)` at a time would re-encode every byte >= 0x80 as a two-byte
    codepoint, and the folded prefix would then match no key. The fold cuts
    just after a whole delimiter, so on a character boundary, and the prefix
    is valid UTF-8."""
    var bs = s.as_bytes()
    var lim = n if n < len(bs) else len(bs)
    var buf = List[UInt8]()
    for i in range(lim):
        buf.append(bs[i])
    return String(unsafe_from_utf8=Span(buf))
