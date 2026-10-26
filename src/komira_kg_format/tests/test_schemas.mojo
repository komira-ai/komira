# =============================================================================
# test_schemas.mojo -- the table schemas and their versions, pinned by name.
# =============================================================================
#
#   columns     each table's schema has exactly the columns listed here, in this
#               order, each with this Arrow type: episodes (6), entities (7),
#               edges (12), edges_tombstone (5), entities_embedding (2),
#               communities (4), community_reports (6).
#   nullability no column of any table is nullable.
#   versions    every SCHEMA_VERSION_* constant is 1, and is a value a manifest
#               entry can carry.
#   constants   TS_OPEN_SENTINEL is the stated open-interval value.
#   shared      the embedding columns are LARGE_STRING in every table that has
#               one, and a delta-only projection repeats the entities columns it
#               projects with the same type.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_kg_format import (
    KgTableEntry,
    SCHEMA_VERSION_COMMUNITIES,
    SCHEMA_VERSION_COMMUNITY_REPORTS,
    SCHEMA_VERSION_EDGES,
    SCHEMA_VERSION_ENTITIES,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    SCHEMA_VERSION_EPISODES,
    TS_OPEN_SENTINEL,
    communities_schema,
    community_reports_schema,
    edges_schema,
    edges_tombstone_schema,
    entities_embedding_schema,
    entities_schema,
    episodes_schema,
)


def _expect(
    s: Schema, label: String, names: List[String], types: List[ArrowType]
) raises:
    """The schema has exactly these columns, in order, with these types, and
    none is nullable."""
    assert_equal(s.num_columns(), len(names), label + ": column count")
    for i in range(len(names)):
        assert_equal(s.field_name(i), names[i], label + ": name of column " + String(i))
        assert_true(
            s.field_arrow_type(i) == types[i],
            label + ": type of " + names[i],
        )
        assert_true(
            not s.field_nullable(i), label + ": " + names[i] + " is not nullable"
        )


def test_episodes_columns() raises:
    _expect(
        episodes_schema(),
        "episodes",
        ["uuid", "partition_id", "body", "ts", "valid_at", "facet"],
        [
            ArrowType.STRING,
            ArrowType.STRING,
            ArrowType.LARGE_STRING,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.STRING,
        ],
    )


def test_entities_columns() raises:
    _expect(
        entities_schema(),
        "entities",
        ["nid", "uuid", "partition_id", "name", "name_embedding", "summary", "attrs"],
        [
            ArrowType.INT64,
            ArrowType.STRING,
            ArrowType.STRING,
            ArrowType.STRING,
            ArrowType.LARGE_STRING,
            ArrowType.LARGE_STRING,
            ArrowType.LARGE_STRING,
        ],
    )


def test_edges_columns() raises:
    _expect(
        edges_schema(),
        "edges",
        [
            "src_nid",
            "dst_nid",
            "src_uuid",
            "dst_uuid",
            "fact",
            "fact_embedding",
            "valid_at",
            "invalid_at",
            "expired_at",
            "created_at",
            "reference_time",
            "source",
        ],
        [
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.STRING,
            ArrowType.STRING,
            ArrowType.LARGE_STRING,
            ArrowType.LARGE_STRING,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.STRING,
        ],
    )


def test_edges_tombstone_columns() raises:
    _expect(
        edges_tombstone_schema(),
        "edges_tombstone",
        ["src_nid", "dst_nid", "created_at", "invalid_at", "expired_at"],
        [
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
        ],
    )


def test_entities_embedding_columns() raises:
    _expect(
        entities_embedding_schema(),
        "entities_embedding",
        ["nid", "name_embedding"],
        [ArrowType.INT64, ArrowType.LARGE_STRING],
    )


def test_communities_columns() raises:
    _expect(
        communities_schema(),
        "communities",
        ["level", "community_id", "parent_community_id", "member_uuids"],
        [
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.LARGE_STRING,
        ],
    )


def test_community_reports_columns() raises:
    _expect(
        community_reports_schema(),
        "community_reports",
        ["community_id", "level", "title", "summary", "findings", "rating"],
        [
            ArrowType.INT64,
            ArrowType.INT64,
            ArrowType.STRING,
            ArrowType.LARGE_STRING,
            ArrowType.LARGE_STRING,
            ArrowType.FLOAT64,
        ],
    )


def test_schema_versions_pinned() raises:
    assert_equal(SCHEMA_VERSION_EPISODES, Int64(1))
    assert_equal(SCHEMA_VERSION_ENTITIES, Int64(1))
    assert_equal(SCHEMA_VERSION_EDGES, Int64(1))
    assert_equal(SCHEMA_VERSION_COMMUNITIES, Int64(1))
    assert_equal(SCHEMA_VERSION_COMMUNITY_REPORTS, Int64(1))
    assert_equal(SCHEMA_VERSION_ENTITIES_EMBEDDING, Int64(1))


def test_version_is_carried_by_a_manifest_entry() raises:
    # The version a schema constant names is the one a manifest entry stores.
    var e = KgTableEntry("episodes", "objects/a", SCHEMA_VERSION_EPISODES, 3)
    assert_equal(e.schema_version, Int64(1))


def test_open_sentinel_value() raises:
    assert_equal(TS_OPEN_SENTINEL, Int64(999999999999))


def test_embedding_columns_are_large_string_everywhere() raises:
    var e = entities_schema()
    var p = entities_embedding_schema()
    var f = edges_schema()
    assert_true(e.get_field_arrow_type("name_embedding") == ArrowType.LARGE_STRING)
    assert_true(p.get_field_arrow_type("name_embedding") == ArrowType.LARGE_STRING)
    assert_true(f.get_field_arrow_type("fact_embedding") == ArrowType.LARGE_STRING)
    # The projection repeats the entity columns it projects, with the same type.
    assert_true(p.get_field_arrow_type("nid") == e.get_field_arrow_type("nid"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
