# =============================================================================
# test_search_http_config.mojo: the config value type and the split uuid rule
# =============================================================================
#
#   * SearchHttpConfig keeps what it is given, defaults the text field to
#     `body` and the limits to the documented values, copies by value, and
#     raises on every unusable value (empty or `..` prefixes, an empty or
#     `_source` text field, a control byte in the node id, a limit below 1).
#   * make_split_uuid lays out discriminant, install-time epoch and sequence in
#     the documented bytes, and two inputs that differ in any one of the three
#     give different uuids (so different object keys).
#   * the dispatcher refuses a worker index outside 0 to 255.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_search_http import (
    DEFAULT_MAX_BODY_BYTES,
    DEFAULT_MAX_SPLITS_PER_SEARCH,
    SearchHttpConfig,
    SearchHttpDispatcher,
    make_split_uuid,
)


def _raises_with(prefix: String, key: String, text: String = "body", node: String = "") -> Bool:
    try:
        _ = SearchHttpConfig(prefix.copy(), key.copy(), text.copy(), node.copy())
    except:
        return True
    return False


def test_config_keeps_its_fields_and_defaults() raises:
    var c = SearchHttpConfig(String("meta"), String("data/x"))
    assert_equal(c.meta_root, String("meta"))
    assert_equal(c.key_prefix, String("data/x"))
    assert_equal(c.text_field, String("body"))
    assert_equal(c.node_id, String(""))
    assert_equal(c.max_body_bytes, DEFAULT_MAX_BODY_BYTES)
    assert_equal(c.max_splits_per_search, DEFAULT_MAX_SPLITS_PER_SEARCH)
    var d = SearchHttpConfig(String("m"), String("k"), String("message"), String("n1"), 10, 3)
    assert_equal(d.text_field, String("message"))
    assert_equal(d.node_id, String("n1"))
    assert_equal(d.max_body_bytes, 10)
    assert_equal(d.max_splits_per_search, 3)


def test_config_copies_by_value() raises:
    var c = SearchHttpConfig(String("m"), String("k"), String("message"), String("n1"), 10, 3)
    var d = c.copy()
    c.text_field = String("changed")
    assert_equal(d.text_field, String("message"))
    assert_equal(d.meta_root, String("m"))
    assert_equal(d.max_splits_per_search, 3)


def test_config_refuses_unusable_prefixes() raises:
    assert_false(_raises_with(String("m"), String("k")))
    assert_false(_raises_with(String("m/"), String("k/sub/")))
    assert_false(_raises_with(String("a.b/c..d"), String("k")))
    assert_true(_raises_with(String(""), String("k")))
    assert_true(_raises_with(String("m"), String("")))
    assert_true(_raises_with(String("m/../x"), String("k")))
    assert_true(_raises_with(String("m"), String("..")))
    assert_true(_raises_with(String("m"), String("./k")))
    assert_true(_raises_with(String("m//x"), String("k")))
    assert_true(_raises_with(String("m"), String("k\\x")))
    assert_true(_raises_with(String("m"), String("k\nx")))
    assert_true(_raises_with(String("x" * 513), String("k")))


def test_config_refuses_bad_text_field_node_and_limits() raises:
    assert_true(_raises_with(String("m"), String("k"), String("")))
    assert_true(_raises_with(String("m"), String("k"), String("_source")))
    assert_true(_raises_with(String("m"), String("k"), String("body"), String("n") + chr(1)))
    var raised = False
    try:
        _ = SearchHttpConfig(String("m"), String("k"), String("body"), String(""), 0, 5)
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = SearchHttpConfig(String("m"), String("k"), String("body"), String(""), 5, 0)
    except:
        raised = True
    assert_true(raised)


def test_split_uuid_layout() raises:
    var u = make_split_uuid(UInt8(9), UInt64(0x0102030405060708), Int64(0x1122))
    assert_equal(Int(u[0]), 9)
    # bytes 1..7: the low 56 bits of the epoch, little-endian
    assert_equal(Int(u[1]), 0x08)
    assert_equal(Int(u[2]), 0x07)
    assert_equal(Int(u[3]), 0x06)
    assert_equal(Int(u[4]), 0x05)
    assert_equal(Int(u[5]), 0x04)
    assert_equal(Int(u[6]), 0x03)
    assert_equal(Int(u[7]), 0x02)  # 0x01 (bit 56 and up) is dropped
    # bytes 8..15: the sequence, little-endian
    assert_equal(Int(u[8]), 0x22)
    assert_equal(Int(u[9]), 0x11)
    for i in range(10, 16):
        assert_equal(Int(u[i]), 0)


def _same(a: InlineArray[UInt8, 16], b: InlineArray[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def test_split_uuid_differs_in_each_input() raises:
    var base = make_split_uuid(UInt8(1), UInt64(5000), Int64(1))
    assert_true(_same(base, make_split_uuid(UInt8(1), UInt64(5000), Int64(1))))
    assert_false(_same(base, make_split_uuid(UInt8(2), UInt64(5000), Int64(1))))
    assert_false(_same(base, make_split_uuid(UInt8(1), UInt64(5001), Int64(1))))
    assert_false(_same(base, make_split_uuid(UInt8(1), UInt64(5000), Int64(2))))


def test_dispatcher_refuses_worker_index_out_of_range() raises:
    var store = SharedInMemoryConditionalStore()
    _ = SearchHttpDispatcher[SharedInMemoryConditionalStore](
        SearchHttpConfig(String("m"), String("k")), store.clone(), 0
    )
    _ = SearchHttpDispatcher[SharedInMemoryConditionalStore](
        SearchHttpConfig(String("m"), String("k")), store.clone(), 255
    )
    var raised = False
    try:
        _ = SearchHttpDispatcher[SharedInMemoryConditionalStore](
            SearchHttpConfig(String("m"), String("k")), store.clone(), 256
        )
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = SearchHttpDispatcher[SharedInMemoryConditionalStore](
            SearchHttpConfig(String("m"), String("k")), store.clone(), -1
        )
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
