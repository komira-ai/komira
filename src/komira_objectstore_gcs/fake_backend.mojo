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
# a conformer behaves the same over it as over the live service.
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
    `StoreError[PRECONDITION] ... status=412`; a read of an absent key raises
    `StoreError[NOT_FOUND] ... status=404`.

    The bucket argument is carried into error messages only: one fake models
    one bucket.

    Single owner, single thread. A `GcsConditionalStore` or `GcsFs` clone
    builds a FRESH backend from its factory, so a clone does not see this
    fake's objects; a test that needs to observe data drives the original.
    """

    var _entries: List[_FakeEntry]
    var _gen_counter: Int64

    def __init__(out self):
        self._entries = List[_FakeEntry]()
        self._gen_counter = Int64(0)

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
        var idx = self._find(key)
        if idx < 0:
            raise Self._not_found_error(String("ReadObject"), bucket, key)
        ref e = self._entries[idx]
        var n = len(e.bytes)
        var start = Int(read_offset)
        if start < 0:
            start = 0
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
        var keep = List[_FakeEntry]()
        for i in range(len(self._entries)):
            if self._entries[i].key != key:
                keep.append(self._entries[i].copy())
        self._entries = keep^

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        """One page holding every match (`next_page_token` is always empty).
        Models the service's directory fold:
          * `delimiter == ""`: every key under `prefix` lands in `objects`.
          * otherwise: a key whose remainder after `prefix` contains the
            delimiter is folded to its name up to and including the first
            delimiter, emitted once in `common_prefixes`; other keys land in
            `objects`."""
        var objects = List[ObjectMetaRaw]()
        var common = List[String]()
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
                    if not _contains_str(common, cp):
                        common.append(cp^)
                    continue
            objects.append(
                ObjectMetaRaw(
                    key=e.key,
                    size=Int64(len(e.bytes)),
                    generation=e.generation,
                    etag=String(""),
                )
            )
        return ListPageRaw(objects^, common^, String(""))


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
