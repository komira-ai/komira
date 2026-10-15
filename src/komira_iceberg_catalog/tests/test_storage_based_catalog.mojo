# =============================================================================
# test_storage_based_catalog.mojo — StorageBasedCatalog identity and
#   re-registration (komira-ai/komira#1502).
# =============================================================================
#
#   (1) RE-REGISTER WINS: registering a new current metadata-location for an
#       identifier replaces the old one. DEFECT CAUGHT: a registry that appends
#       and returns the first match keeps resolving v1 after v2 is registered.
#   (2) IDENTIFIER PARTS STAY APART: namespace `a.b` + table `c` and namespace
#       `a` + table `b.c` are different tables (Iceberg names may contain `.`).
#       DEFECT CAUGHT: a `namespace + "." + table` key resolves one as the other.
#   (3) RE-REGISTER TOUCHES ONLY ITS OWN IDENTIFIER: replacing one table's
#       location leaves another table's location as registered. DEFECT CAUGHT:
#       a replace that overwrote the wrong slot.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_iceberg_catalog.iceberg_catalog import StorageBasedCatalog


def test_reregister_latest_location_wins() raises:
    var c = StorageBasedCatalog()
    c.register(
        String("db"),
        String("orders"),
        String("s3://wh/db/orders/metadata/v1.metadata.json"),
    )
    c.register(
        String("db"),
        String("orders"),
        String("s3://wh/db/orders/metadata/v2.metadata.json"),
    )
    assert_equal(
        c.load_table(String("db"), String("orders")).metadata_location,
        String("s3://wh/db/orders/metadata/v2.metadata.json"),
    )


def test_dotted_namespace_and_table_do_not_collide() raises:
    var c = StorageBasedCatalog()
    c.register(
        String("a.b"),
        String("c"),
        String("s3://wh/one/metadata/v1.metadata.json"),
    )
    var raised = False
    try:
        var _r = c.load_table(String("a"), String("b.c"))
    except e:
        raised = True
        assert_true(String(e).find("no table registered") >= 0)
    assert_true(raised)

    # Both identifiers registered: each resolves to its own location.
    c.register(
        String("a"),
        String("b.c"),
        String("s3://wh/two/metadata/v1.metadata.json"),
    )
    assert_equal(
        c.load_table(String("a.b"), String("c")).metadata_location,
        String("s3://wh/one/metadata/v1.metadata.json"),
    )
    assert_equal(
        c.load_table(String("a"), String("b.c")).metadata_location,
        String("s3://wh/two/metadata/v1.metadata.json"),
    )


def test_reregister_leaves_other_tables_alone() raises:
    var c = StorageBasedCatalog()
    c.register(
        String("db"),
        String("orders"),
        String("s3://wh/db/orders/metadata/v1.metadata.json"),
    )
    c.register(
        String("db"),
        String("items"),
        String("s3://wh/db/items/metadata/v1.metadata.json"),
    )
    c.register(
        String("db"),
        String("items"),
        String("s3://wh/db/items/metadata/v2.metadata.json"),
    )
    assert_equal(
        c.load_table(String("db"), String("orders")).metadata_location,
        String("s3://wh/db/orders/metadata/v1.metadata.json"),
    )
    assert_equal(
        c.load_table(String("db"), String("items")).metadata_location,
        String("s3://wh/db/items/metadata/v2.metadata.json"),
    )


def main() raises:
    test_reregister_latest_location_wins()
    test_dotted_namespace_and_table_do_not_collide()
    test_reregister_leaves_other_tables_alone()
    print("test_storage_based_catalog: ALL PASS")
