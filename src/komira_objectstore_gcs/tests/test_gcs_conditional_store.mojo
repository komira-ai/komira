# =============================================================================
# tests/test_gcs_conditional_store.mojo
#   GcsConditionalStore over FakeGcsStorageBackend: the ConditionalWriteStore
#   contract, with no credentials and no network.
# =============================================================================
#
#   (1) create-if-absent: a first create succeeds; a second on the same key
#       raises StoreError[PRECONDITION] status=412.
#   (2) compare-and-swap with the live generation succeeds and returns a new
#       one; (3) with a stale generation it raises 412.
#   (4) get / get_range round-trip the written bytes.
#   (5) head returns the live generation; delete is idempotent; an
#       unconditional put creates, then overwrites.
#   (6) a short get_range raises; a negative start or length is refused.
#   (7) list_with_delimiter folds, sorts and pages as the service does, and
#       keeps a non-ASCII prefix byte for byte.
#   (8) a clone builds its own backend; a malformed CAS handle (including
#       "0", which means create on the wire) is refused before any call; an
#       error kind is read from the leading token, never from the key.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition

from komira_objectstore_gcs import (
    GCS_ERR_NOT_FOUND,
    GCS_ERR_PERMISSION_DENIED,
    GCS_ERR_PRECONDITION,
    FakeGcsStorageBackend,
    GcsConditionalStore,
    GcsStorageBackend,
    ListPageRaw,
    ObjectMetaRaw,
    gcs_store_error_kind_from_message,
)


def _make_fake_backend() -> FakeGcsStorageBackend:
    return FakeGcsStorageBackend()


def _fake_store() -> GcsConditionalStore[FakeGcsStorageBackend]:
    return GcsConditionalStore[FakeGcsStorageBackend](
        bucket=String("test-bucket"),
        make_backend=_make_fake_backend,
    )


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def test_conditional_put_create_then_create_is_precondition() raises:
    var store = _fake_store()
    var path = Path.parse(String("manifest/v1.json"))

    var meta = store.conditional_put(
        path, _bytes([1, 2, 3, 4]), WritePrecondition.if_none_match_star()
    )
    assert_equal(meta.location, String("manifest/v1.json"))
    assert_equal(meta.size, Int64(4))
    assert_true(meta.version.byte_length() > 0)
    # The CAS handle is the generation, in etag as well as version.
    assert_equal(meta.etag, meta.version)

    var raised = False
    try:
        _ = store.conditional_put(
            path, _bytes([9, 9]), WritePrecondition.if_none_match_star()
        )
    except e:
        raised = True
        var msg = String(e)
        assert_equal(
            gcs_store_error_kind_from_message(msg), GCS_ERR_PRECONDITION
        )
        assert_true(msg.find(String("status=412")) >= 0)
    assert_true(raised)


def test_compare_and_swap_success_then_stale_is_precondition() raises:
    var store = _fake_store()
    var path = Path.parse(String("head"))

    var v0 = store.conditional_put(
        path, _bytes([1]), WritePrecondition.if_none_match_star()
    )
    var gen0 = v0.version

    var v1 = store.compare_and_swap(path, _bytes([2, 2]), gen0)
    assert_true(v1.version.byte_length() > 0)
    assert_true(v1.version != gen0)
    assert_equal(v1.size, Int64(2))

    var raised = False
    try:
        _ = store.compare_and_swap(path, _bytes([3, 3, 3]), gen0)
    except e:
        raised = True
        var msg = String(e)
        assert_equal(
            gcs_store_error_kind_from_message(msg), GCS_ERR_PRECONDITION
        )
        assert_true(msg.find(String("status=412")) >= 0)
    assert_true(raised)

    # The live handle still works, chained off etag this time.
    var v2 = store.conditional_put(
        path, _bytes([4]), WritePrecondition.if_match(v1.etag)
    )
    assert_equal(v2.size, Int64(1))


def test_get_and_get_range_roundtrip_bytes() raises:
    var store = _fake_store()
    var path = Path.parse(String("blob"))
    _ = store.conditional_put(
        path,
        _bytes([10, 20, 30, 40, 50, 60]),
        WritePrecondition.if_none_match_star(),
    )

    var got = store.get(path)
    assert_equal(len(got), 6)
    assert_equal(got[0], UInt8(10))
    assert_equal(got[5], UInt8(60))

    var rng = store.get_range(path, Int64(2), Int64(3))
    assert_equal(len(rng), 3)
    assert_equal(rng[0], UInt8(30))
    assert_equal(rng[1], UInt8(40))
    assert_equal(rng[2], UInt8(50))

    var empty = store.get_range(path, Int64(0), Int64(0))
    assert_equal(len(empty), 0)


def test_head_returns_metadata() raises:
    var store = _fake_store()
    var path = Path.parse(String("meta-probe"))
    var v = store.conditional_put(
        path, _bytes([1, 2, 3, 4, 5]), WritePrecondition.if_none_match_star()
    )
    var meta = store.head(path)
    assert_equal(meta.location, String("meta-probe"))
    assert_equal(meta.size, Int64(5))
    assert_equal(meta.version, v.version)
    assert_equal(meta.etag, v.etag)


def test_delete_is_idempotent() raises:
    var store = _fake_store()
    var path = Path.parse(String("ephemeral"))
    _ = store.conditional_put(
        path, _bytes([7]), WritePrecondition.if_none_match_star()
    )
    store.delete(path)
    var head_raised = False
    try:
        _ = store.head(path)
    except e:
        head_raised = True
        assert_equal(
            gcs_store_error_kind_from_message(String(e)), GCS_ERR_NOT_FOUND
        )
    assert_true(head_raised)
    # A second delete of the now-absent key does not raise.
    store.delete(path)


def test_put_creates_then_overwrites() raises:
    var store = _fake_store()
    var path = Path.parse(String("config"))
    var v0 = store.put(path, _bytes([1, 1]))
    assert_equal(v0.size, Int64(2))

    var v1 = store.put(path, _bytes([2, 2, 2, 2]))
    assert_equal(v1.size, Int64(4))
    assert_true(v1.version != v0.version)

    var got = store.get(path)
    assert_equal(len(got), 4)
    assert_equal(got[0], UInt8(2))


def test_get_range_short_read_raises() raises:
    var store = _fake_store()
    var path = Path.parse(String("small"))
    _ = store.conditional_put(
        path, _bytes([1, 2]), WritePrecondition.if_none_match_star()
    )
    var raised = False
    try:
        _ = store.get_range(path, Int64(0), Int64(5))
    except e:
        raised = True
        assert_true(String(e).find(String("short read")) >= 0)
    assert_true(raised)


def test_list_with_delimiter_folds_sorts_and_keeps_bytes() raises:
    """The `/` fold over the public fake: prefixes come back once each, in
    byte order, byte for byte (a non-ASCII prefix must equal the key's own
    bytes); only direct children are objects, carrying the generation in both
    etag and version."""
    var store = _fake_store()
    var none = WritePrecondition.if_none_match_star()
    _ = store.conditional_put(Path.parse(String("data/é/x")), _bytes([1]), none)
    _ = store.conditional_put(
        Path.parse(String("data/sub/c")), _bytes([2]), none
    )
    _ = store.conditional_put(
        Path.parse(String("data/sub/d")), _bytes([3]), none
    )
    var a = store.conditional_put(
        Path.parse(String("data/a")), _bytes([4, 4]), none
    )
    _ = store.conditional_put(
        Path.parse(String("events/city=Zürich/x")), _bytes([5]), none
    )

    var res = store.list_with_delimiter(Path.parse(String("data/")))
    assert_equal(len(res.common_prefixes), 2)
    assert_equal(res.common_prefixes[0], String("data/sub/"))
    assert_equal(res.common_prefixes[1], String("data/é/"))
    assert_equal(len(res.objects), 1)
    assert_equal(res.objects[0].location, String("data/a"))
    assert_equal(res.objects[0].size, Int64(2))
    assert_equal(res.objects[0].etag, res.objects[0].version)
    assert_equal(res.objects[0].version, a.version)

    var ev = store.list_with_delimiter(Path.parse(String("events/")))
    assert_equal(len(ev.common_prefixes), 1)
    assert_equal(ev.common_prefixes[0], String("events/city=Zürich/"))
    assert_equal(len(ev.objects), 0)


def _make_paged_fake() -> FakeGcsStorageBackend:
    return FakeGcsStorageBackend(page_size=1)


def test_fake_list_objects_pages_by_token() raises:
    """With one entry per page, each page resumes after the previous page's
    token, in byte order, and the last page carries no token."""
    var fake = FakeGcsStorageBackend(page_size=1)
    _ = fake.conditional_create(String("b"), String("p/z"), _bytes([1]))
    _ = fake.conditional_create(String("b"), String("p/sub/c"), _bytes([1]))
    _ = fake.conditional_create(String("b"), String("p/a"), _bytes([1]))
    var names = List[String]()
    var token = String("")
    var pages = 0
    while True:
        pages += 1
        assert_true(pages <= 4, "the fake must honour the page token")
        var page = fake.list_objects(String("b"), String("p/"), token, String("/"))
        assert_equal(len(page.objects) + len(page.common_prefixes), 1)
        for i in range(len(page.objects)):
            names.append(page.objects[i].key)
        for i in range(len(page.common_prefixes)):
            names.append(page.common_prefixes[i])
        if page.next_page_token.byte_length() == 0:
            break
        token = page.next_page_token
    assert_equal(pages, 3)
    assert_equal(names[0], String("p/a"))
    assert_equal(names[1], String("p/sub/"))
    assert_equal(names[2], String("p/z"))


def test_list_with_delimiter_drains_every_page() raises:
    var store = GcsConditionalStore[FakeGcsStorageBackend](
        bucket=String("test-bucket"), make_backend=_make_paged_fake
    )
    var none = WritePrecondition.if_none_match_star()
    _ = store.conditional_put(Path.parse(String("d/b")), _bytes([1]), none)
    _ = store.conditional_put(Path.parse(String("d/s/x")), _bytes([1]), none)
    _ = store.conditional_put(Path.parse(String("d/a")), _bytes([1]), none)
    _ = store.conditional_put(Path.parse(String("d/t/y")), _bytes([1]), none)
    var res = store.list_with_delimiter(Path.parse(String("d/")))
    assert_equal(len(res.objects), 2)
    assert_equal(res.objects[0].location, String("d/a"))
    assert_equal(res.objects[1].location, String("d/b"))
    assert_equal(len(res.common_prefixes), 2)
    assert_equal(res.common_prefixes[0], String("d/s/"))
    assert_equal(res.common_prefixes[1], String("d/t/"))


def test_clone_builds_its_own_backend() raises:
    """A clone's backend comes fresh from the factory: it does not see what
    the original wrote, and the original still does."""
    var store = _fake_store()
    var path = Path.parse(String("only-in-original"))
    var v = store.conditional_put(
        path, _bytes([1, 2]), WritePrecondition.if_none_match_star()
    )
    var clone = store.clone()
    assert_equal(clone.bucket(), String("test-bucket"))
    var raised = False
    try:
        _ = clone.head(path)
    except e:
        raised = True
        assert_equal(
            gcs_store_error_kind_from_message(String(e)), GCS_ERR_NOT_FOUND
        )
    assert_true(raised, "a clone must not share the original's backend")
    assert_equal(store.head(path).version, v.version)


def test_if_match_refuses_malformed_handles_before_any_call() raises:
    """Each handle is refused by the conformer itself (no StoreError kind),
    and the object is untouched. `"0"` in particular would mean
    create-if-absent on the wire."""
    var store = _fake_store()
    var path = Path.parse(String("cas-target"))
    var v = store.conditional_put(
        path, _bytes([1]), WritePrecondition.if_none_match_star()
    )
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("abc"))
    bad.append(String("CJjb1Q8QAQ=="))
    bad.append(String("0"))
    bad.append(String("-5"))
    bad.append(String("99999999999999999999"))
    bad.append(String("9223372036854775808"))
    for i in range(len(bad)):
        var raised = False
        try:
            _ = store.compare_and_swap(path, _bytes([9]), bad[i])
        except e:
            raised = True
            var msg = String(e)
            assert_true(
                msg.find(String("GcsConditionalStore.compare_and_swap")) >= 0,
                String("refused by the conformer: ") + bad[i],
            )
            assert_equal(gcs_store_error_kind_from_message(msg), UInt8(0))
        assert_true(raised, String("must refuse handle: ") + bad[i])
    assert_equal(store.head(path).version, v.version)
    assert_equal(store.get(path)[0], UInt8(1))


def test_get_range_refuses_negative_start_or_length() raises:
    var store = _fake_store()
    var path = Path.parse(String("ranged"))
    _ = store.conditional_put(
        path, _bytes([1, 2, 3]), WritePrecondition.if_none_match_star()
    )
    var raised_start = False
    try:
        _ = store.get_range(path, Int64(-2), Int64(2))
    except e:
        raised_start = True
        assert_true(String(e).find(String("negative")) >= 0)
    assert_true(raised_start)
    var raised_len = False
    try:
        _ = store.get_range(path, Int64(0), Int64(-1))
    except e:
        raised_len = True
        assert_true(String(e).find(String("negative")) >= 0)
    assert_true(raised_len)


struct _DeniedDeleteBackend(GcsStorageBackend, Movable, Deinitable):
    """The public fake, except DeleteObject is denied, with the key echoed in
    the message as a live backend echoes it."""

    var _inner: FakeGcsStorageBackend

    def __init__(out self):
        self._inner = FakeGcsStorageBackend()

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        return self._inner.conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        return self._inner.compare_and_swap(
            bucket, key, data, expected_generation
        )

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        return self._inner.read_range(bucket, key, read_offset, read_limit)

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        return self._inner.get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        raise Error(
            String("StoreError[PERMISSION_DENIED] DeleteObject gs://")
            + bucket
            + "/"
            + key
            + " status=403 grpc_code=7"
        )

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        return self._inner.list_objects(bucket, prefix, page_token, delimiter)


def _make_denied() -> _DeniedDeleteBackend:
    return _DeniedDeleteBackend()


def test_error_kind_is_read_from_the_leading_token_not_the_key() raises:
    """A key holding `StoreError[NOT_FOUND]` / `status=404` must not turn a
    denied delete into a swallowed NOT_FOUND."""
    var msg = String(
        "StoreError[PERMISSION_DENIED] DeleteObject"
        " gs://b/x/StoreError[NOT_FOUND]/status=404 status=403"
    )
    assert_equal(
        gcs_store_error_kind_from_message(msg), GCS_ERR_PERMISSION_DENIED
    )
    assert_equal(
        gcs_store_error_kind_from_message(String("no kind here status=404")),
        UInt8(0),
    )

    var store = GcsConditionalStore[_DeniedDeleteBackend](
        bucket=String("test-bucket"), make_backend=_make_denied
    )
    var raised = False
    try:
        store.delete(Path.parse(String("x/StoreError[NOT_FOUND]/status=404")))
    except e:
        raised = True
        assert_equal(
            gcs_store_error_kind_from_message(String(e)),
            GCS_ERR_PERMISSION_DENIED,
        )
    assert_true(raised, "a denied delete must not be swallowed as NOT_FOUND")


def main() raises:
    test_conditional_put_create_then_create_is_precondition()
    test_compare_and_swap_success_then_stale_is_precondition()
    test_get_and_get_range_roundtrip_bytes()
    test_head_returns_metadata()
    test_delete_is_idempotent()
    test_put_creates_then_overwrites()
    test_get_range_short_read_raises()
    test_list_with_delimiter_folds_sorts_and_keeps_bytes()
    test_fake_list_objects_pages_by_token()
    test_list_with_delimiter_drains_every_page()
    test_clone_builds_its_own_backend()
    test_if_match_refuses_malformed_handles_before_any_call()
    test_get_range_refuses_negative_start_or_length()
    test_error_kind_is_read_from_the_leading_token_not_the_key()
    print("PASS test_gcs_conditional_store")
