# =============================================================================
# test_iceberg_version.mojo — which metadata version is current.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. A table with no hint and no metadata file is version 0 (never committed).
#   2. The hint's number is the version when no higher metadata file exists.
#   3. A metadata file past the hint (a writer stopped before moving the hint)
#      is a committed version: current_version steps over every such file, and
#      read_hint_version still reports the hint alone.
#   4. A hint that is not a number is an error, not version 0 (a failure to
#      read must never look like a table that was never committed).
#   5. A location whose name contains "404" does not turn a read failure into
#      absence: only a proven not-found is absence.
#   6. The key builders produce the Hadoop-table layout.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_iceberg.iceberg_version import (
    metadata_dir,
    pointer_key,
    metadata_json_key,
    read_hint_version,
    version_exists,
    current_version,
)


def _put(mut store: InMemoryConditionalStore, key: String, body: String) raises:
    _ = store.put(Path.parse(key), List[UInt8](body.as_bytes()))


def test_key_builders() raises:
    assert_equal(metadata_dir(String("a/b")), String("a/b/metadata"))
    assert_equal(pointer_key(String("a/b")), String("a/b/metadata/version-hint.text"))
    assert_equal(
        metadata_json_key(String("a/b"), 12), String("a/b/metadata/v12.metadata.json")
    )


def test_a_never_committed_table_is_version_zero() raises:
    var store = InMemoryConditionalStore()
    assert_equal(read_hint_version(store, String("t")), 0)
    assert_false(version_exists(store, String("t"), 1))
    assert_equal(current_version(store, String("t")), 0)


def test_the_hint_is_the_version_when_nothing_is_past_it() raises:
    var store = InMemoryConditionalStore()
    _put(store, String("t/metadata/version-hint.text"), String("3\n"))
    _put(store, String("t/metadata/v3.metadata.json"), String("{}"))
    assert_equal(read_hint_version(store, String("t")), 3)
    assert_true(version_exists(store, String("t"), 3))
    assert_equal(current_version(store, String("t")), 3)


def test_files_past_the_hint_are_committed_versions() raises:
    var store = InMemoryConditionalStore()
    _put(store, String("t/metadata/version-hint.text"), String("1"))
    _put(store, String("t/metadata/v1.metadata.json"), String("{}"))
    _put(store, String("t/metadata/v2.metadata.json"), String("{}"))
    _put(store, String("t/metadata/v3.metadata.json"), String("{}"))
    assert_equal(read_hint_version(store, String("t")), 1)
    assert_equal(current_version(store, String("t")), 3)
    # No hint at all but a first metadata file: that file is the table.
    var fresh = InMemoryConditionalStore()
    _put(fresh, String("t/metadata/v1.metadata.json"), String("{}"))
    assert_equal(current_version(fresh, String("t")), 1)
    # A gap is not stepped over: v5 without v4 is not reachable from v3.
    _put(store, String("t/metadata/v5.metadata.json"), String("{}"))
    assert_equal(current_version(store, String("t")), 3)


def test_a_hint_that_is_not_a_number_is_an_error() raises:
    var store = InMemoryConditionalStore()
    _put(store, String("t/metadata/version-hint.text"), String("latest"))
    with assert_raises():
        _ = read_hint_version(store, String("t"))
    with assert_raises():
        _ = current_version(store, String("t"))


def test_a_location_named_404_is_not_a_proof_of_absence() raises:
    var store = InMemoryConditionalStore()
    _put(store, String("t404/metadata/version-hint.text"), String("2"))
    _put(store, String("t404/metadata/v2.metadata.json"), String("{}"))
    assert_equal(current_version(store, String("t404")), 2)
    assert_equal(current_version(store, String("other404")), 0)


def main() raises:
    test_key_builders()
    test_a_never_committed_table_is_version_zero()
    test_the_hint_is_the_version_when_nothing_is_past_it()
    test_files_past_the_hint_are_committed_versions()
    test_a_hint_that_is_not_a_number_is_an_error()
    test_a_location_named_404_is_not_a_proof_of_absence()
    print("test_iceberg_version: all passed")
