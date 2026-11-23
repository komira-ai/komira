# =============================================================================
# test_iceberg_table_files.mojo — TableFiles: an object store addressed by the
#   absolute URIs of a table's metadata.
# =============================================================================
#
#   * test_a_uri_under_the_prefix_is_its_key: the key is everything after the
#     prefix and its `/`, whatever trailing `/` the prefix was given with.
#   * test_put_get_and_delete_work_by_uri: a put is read back by its URI, a
#     second put replaces it, a delete removes it and deleting again is fine.
#   * test_a_clone_shares_the_data: a write through a clone is read through the
#     original and through the raw store.
#   * test_a_uri_outside_the_prefix_is_refused_by_name: a URI of another
#     bucket, of a sibling whose name starts with the prefix and the prefix
#     itself raise the exact ICEBERG_LOCATION_REFUSED message from every verb,
#     and nothing is written.
#   * test_a_uri_that_names_no_object_is_refused: a directory, a `..` or `.`
#     segment and a repeated `/` raise the exact message of the other kind.
#   * test_the_sink_error_tokens_are_the_designs: the four tokens the sink
#     adds to this package's error module, two of them the format package's.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_LOCATION_REFUSED,
    ICEBERG_MANIFEST_LIST_UNSUPPORTED,
    ICEBERG_NULL_IN_REQUIRED_COLUMN,
    ICEBERG_TYPE_UNSUPPORTED,
)
from iceberg_catalog.iceberg_table_files import TableFiles


comptime _Files = TableFiles[SharedInMemoryConditionalStore]


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _files(store: SharedInMemoryConditionalStore, prefix: String) -> _Files:
    return _Files(store.clone(), String(prefix))


def _not_under(uri: String) -> String:
    return (
        String("ICEBERG_LOCATION_REFUSED: ")
        + uri
        + String(" is not under s3://warehouse, the store this write was given")
    )


def _names_no_object(uri: String) -> String:
    return (
        String("ICEBERG_LOCATION_REFUSED: ")
        + uri
        + String(" does not name an object under s3://warehouse")
    )


def _key_error(files: _Files, uri: String) -> String:
    try:
        _ = files.key_of(uri)
    except e:
        return String(e)
    return String("")


def _put_error(files: _Files, uri: String) -> String:
    try:
        files.put(uri, _bytes(String("x")))
    except e:
        return String(e)
    return String("")


def _get_error(files: _Files, uri: String) -> String:
    try:
        _ = files.get(uri)
    except e:
        return String(e)
    return String("")


def _delete_error(files: _Files, uri: String) -> String:
    try:
        files.delete(uri)
    except e:
        return String(e)
    return String("")


def _stored_keys(store: SharedInMemoryConditionalStore) raises -> Int:
    var listed = store.list_with_delimiter(Path.parse(String("")))
    return len(listed.objects)


def test_a_uri_under_the_prefix_is_its_key() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _files(store, String("s3://warehouse"))
    assert_equal(files.prefix(), String("s3://warehouse"))
    assert_equal(
        files.key_of(String("s3://warehouse/db/t/data/a.parquet")).raw(),
        String("db/t/data/a.parquet"),
    )
    assert_equal(
        files.key_of(String("s3://warehouse/a")).raw(), String("a")
    )

    var slashed = _files(store, String("s3://warehouse//"))
    assert_equal(slashed.prefix(), String("s3://warehouse"))
    assert_equal(
        slashed.key_of(String("s3://warehouse/db/x")).raw(), String("db/x")
    )

    var deeper = _files(store, String("s3://warehouse/wh1"))
    assert_equal(
        deeper.key_of(String("s3://warehouse/wh1/db/x")).raw(), String("db/x")
    )


def test_put_get_and_delete_work_by_uri() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _files(store, String("s3://warehouse"))
    var uri = String("s3://warehouse/db/t/metadata/m.avro")
    files.put(uri, _bytes(String("one")))
    assert_true(files.get(uri) == _bytes(String("one")))
    files.put(uri, _bytes(String("two")))
    assert_true(files.get(uri) == _bytes(String("two")))
    assert_equal(_stored_keys(store), 1)

    files.delete(uri)
    assert_equal(_stored_keys(store), 0)
    assert_true(_get_error(files, uri).byte_length() > 0)
    files.delete(uri)


def test_a_clone_shares_the_data() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _files(store, String("s3://warehouse"))
    var other = files.clone()
    assert_equal(other.prefix(), String("s3://warehouse"))
    other.put(String("s3://warehouse/k"), _bytes(String("v")))
    assert_true(files.get(String("s3://warehouse/k")) == _bytes(String("v")))
    assert_true(store.get(Path.parse(String("k"))) == _bytes(String("v")))


def test_a_uri_outside_the_prefix_is_refused_by_name() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _files(store, String("s3://warehouse"))
    var uris = List[String]()
    uris.append(String("s3://other/db/x"))
    uris.append(String("s3://warehouse2/db/x"))
    uris.append(String("s3://warehouse"))
    uris.append(String("gs://warehouse/db/x"))
    uris.append(String("db/x"))
    uris.append(String(""))
    for i in range(len(uris)):
        var expected = _not_under(uris[i])
        assert_equal(_key_error(files, uris[i]), expected)
        assert_equal(_put_error(files, uris[i]), expected)
        assert_equal(_get_error(files, uris[i]), expected)
        assert_equal(_delete_error(files, uris[i]), expected)
    assert_equal(_stored_keys(store), 0)


def test_a_uri_that_names_no_object_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _files(store, String("s3://warehouse"))
    var uris = List[String]()
    uris.append(String("s3://warehouse/"))
    uris.append(String("s3://warehouse/db/"))
    uris.append(String("s3://warehouse/db/../x"))
    uris.append(String("s3://warehouse/./x"))
    uris.append(String("s3://warehouse//x"))
    uris.append(String("s3://warehouse/db//x"))
    for i in range(len(uris)):
        var expected = _names_no_object(uris[i])
        assert_equal(_key_error(files, uris[i]), expected)
        assert_equal(_put_error(files, uris[i]), expected)
    assert_equal(_stored_keys(store), 0)


def test_the_sink_error_tokens_are_the_designs() raises:
    assert_equal(ICEBERG_LOCATION_REFUSED, String("ICEBERG_LOCATION_REFUSED"))
    assert_equal(
        ICEBERG_MANIFEST_LIST_UNSUPPORTED,
        String("ICEBERG_MANIFEST_LIST_UNSUPPORTED"),
    )
    assert_equal(
        ICEBERG_TYPE_UNSUPPORTED, String("ICEBERG_TYPE_UNSUPPORTED")
    )
    assert_equal(
        ICEBERG_NULL_IN_REQUIRED_COLUMN,
        String("ICEBERG_NULL_IN_REQUIRED_COLUMN"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
