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
#   (6) a short get_range raises.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition

from komira_objectstore_gcs import (
    GCS_ERR_NOT_FOUND,
    GCS_ERR_PRECONDITION,
    FakeGcsStorageBackend,
    GcsConditionalStore,
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


def main() raises:
    test_conditional_put_create_then_create_is_precondition()
    test_compare_and_swap_success_then_stale_is_precondition()
    test_get_and_get_range_roundtrip_bytes()
    test_head_returns_metadata()
    test_delete_is_idempotent()
    test_put_creates_then_overwrites()
    test_get_range_short_read_raises()
    print("PASS test_gcs_conditional_store")
