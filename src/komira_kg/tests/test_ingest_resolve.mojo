# =============================================================================
# test_ingest_resolve.mojo -- resolve extracted mentions to entities of the
#   working set (stub model and embedder; no network, clock or environment).
# =============================================================================
#
#   match       a mention with an existing entity's name resolves to it and adds
#               no row.
#   judgment    a borderline variant is put to the model: yes resolves to the
#               existing entity, no mints a new one; an unrelated mention is a
#               new entity and a repeat of it resolves to the first.
#   candidates  only the `cosine_k` nearest entities are candidates.
#   partitions  an entity of another partition is not a candidate; an empty
#               partition id sees them all; a name lookup is scoped the same way.
#   minting     a new entity's uuid, partition, summary, facet `attrs` and
#               embedding; node ids are minted in order.
#   dimension   an embedding of another length, or not finite, is refused.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
)

from komira_kg import (
    Embedder,
    IngestConfig,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
    WorkingEntity,
    existing_nid_for_name,
    facet_attrs_json,
    facet_from_attrs,
    facet_source_from_attrs,
    mint_entity,
    resolve_entities,
)
from komira_kg_format import EntityMention

comptime DIM = 4
comptime HARBOR = "Harbor Alpha Meadow"
comptime HARBOR_VARIANT = "harbor aypha meadow"
comptime BETA = "Beta Station"


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


struct ShortEmbedder(Embedder):
    """Reports 4 components and returns 3."""

    def __init__(out self):
        pass

    def dimension(self) -> Int:
        return DIM

    def embed(self, text: String) raises -> List[Float64]:
        var v = List[Float64]()
        v.append(1.0)
        v.append(0.0)
        v.append(0.0)
        return v^

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        var out = List[List[Float64]]()
        for _ in range(len(texts)):
            out.append(self.embed(""))
        return out^


def _embedder() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector(HARBOR, _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector(HARBOR_VARIANT, _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector(BETA, _vec(0.0, 1.0, 0.0, 0.0))
    emb.add_vector("Gamma Quarry", _vec(0.0, 0.0, 1.0, 0.0))
    return emb^


def _graph() raises -> SnapshotWorkingSet:
    """Entity 0 is HARBOR and entity 1 is BETA, both of partition p1."""
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(
        WorkingEntity(
            ws.next_nid(), "u0", "p1", HARBOR, _vec(1.0, 0.0, 0.0, 0.0), "", "{}"
        )
    )
    ws.add_entity(
        WorkingEntity(
            ws.next_nid(), "u1", "p1", BETA, _vec(0.0, 1.0, 0.0, 0.0), "", "{}"
        )
    )
    return ws^


def _one(name: String) -> List[EntityMention]:
    var out = List[EntityMention]()
    out.append(EntityMention(name, "", "a summary"))
    return out^


def test_a_mention_with_an_existing_name_resolves_to_it_and_adds_no_row() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    var got = resolve_entities(
        ws, _one("beta station"), llm, emb, "p1", IngestConfig.default()
    )
    assert_equal(len(got), 1)
    assert_equal(got[0], Int64(1))
    assert_equal(ws.num_entities(), 2)


def test_a_judged_variant_resolves_to_the_existing_entity() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    llm.add_same_entity(HARBOR_VARIANT, HARBOR, True)
    var got = resolve_entities(
        ws, _one(HARBOR_VARIANT), llm, emb, "p1", IngestConfig.default()
    )
    assert_equal(got[0], Int64(0))
    assert_equal(ws.num_entities(), 2)


def test_a_variant_the_model_calls_distinct_is_a_new_entity() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    llm.add_same_entity(HARBOR_VARIANT, HARBOR, False)
    var got = resolve_entities(
        ws, _one(HARBOR_VARIANT), llm, emb, "p1", IngestConfig.default()
    )
    assert_equal(got[0], Int64(2))
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.entities[2].name, HARBOR_VARIANT)


def test_distinct_entities_stay_apart_and_a_repeat_resolves_to_the_first() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    var mentions = _one("Gamma Quarry")
    mentions.append(EntityMention("Gamma Quarry", "", ""))
    mentions.append(EntityMention(BETA, "", ""))
    var got = resolve_entities(
        ws, mentions, llm, emb, "p1", IngestConfig.default()
    )
    assert_equal(len(got), 3)
    assert_equal(got[0], Int64(2))  # new
    assert_equal(got[1], Int64(2))  # the same name again: the entity just minted
    assert_equal(got[2], Int64(1))  # the existing one
    assert_equal(ws.num_entities(), 3)


def test_only_the_nearest_cosine_k_entities_are_candidates() raises:
    var cfg = IngestConfig.default()
    cfg.cosine_k = 1
    # The embedder puts BETA's mention next to HARBOR: with one candidate it is
    # HARBOR alone, and BETA is never tried.
    var near_harbor = _embedder()
    near_harbor.add_vector(BETA, _vec(1.0, 0.0, 0.0, 0.0))
    var ws = _graph()
    var llm = StubLlmClient()
    var narrow = resolve_entities(ws, _one(BETA), llm, near_harbor, "p1", cfg)
    assert_equal(narrow[0], Int64(2))
    assert_equal(ws.num_entities(), 3)

    var wide = _graph()
    cfg.cosine_k = 2
    var both = resolve_entities(wide, _one(BETA), llm, near_harbor, "p1", cfg)
    assert_equal(both[0], Int64(1))
    assert_equal(wide.num_entities(), 2)


def test_an_entity_of_another_partition_is_not_a_candidate() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    var got = resolve_entities(
        ws, _one(BETA), llm, emb, "p2", IngestConfig.default()
    )
    assert_equal(got[0], Int64(2))
    assert_equal(ws.entities[2].partition_id, "p2")
    assert_equal(ws.entities[2].uuid, "p2:2")
    assert_equal(ws.num_entities(), 3)


def test_an_empty_partition_id_sees_every_partition() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    var got = resolve_entities(
        ws, _one(BETA), llm, emb, "", IngestConfig.default()
    )
    assert_equal(got[0], Int64(1))
    assert_equal(ws.num_entities(), 2)


def test_a_name_lookup_is_scoped_to_the_partition() raises:
    var ws = _graph()
    assert_equal(existing_nid_for_name(ws, "BETA  station", "p1"), Int64(1))
    assert_equal(existing_nid_for_name(ws, BETA, ""), Int64(1))
    assert_equal(existing_nid_for_name(ws, BETA, "p2"), Int64(-1))
    assert_equal(existing_nid_for_name(ws, "Gamma Quarry", "p1"), Int64(-1))


def test_a_new_entity_carries_its_row_facet_and_embedding() raises:
    var ws = _graph()
    var emb = _embedder()
    var llm = StubLlmClient()
    var got = resolve_entities(
        ws,
        _one("Gamma Quarry"),
        llm,
        emb,
        "p1",
        IngestConfig.default(),
        "chat",
        "src-1",
    )
    ref e = ws.entities[ws.entity_index_of_nid(got[0])]
    assert_equal(e.nid, Int64(2))
    assert_equal(e.uuid, "p1:2")
    assert_equal(e.partition_id, "p1")
    assert_equal(e.name, "Gamma Quarry")
    assert_equal(e.summary, "a summary")
    assert_equal(e.attrs, facet_attrs_json("chat", "src-1"))
    assert_equal(facet_from_attrs(e.attrs), "chat")
    assert_equal(facet_source_from_attrs(e.attrs), "src-1")
    assert_equal(len(e.name_embedding), DIM)
    assert_equal(e.name_embedding[2], 1.0)


def test_without_a_facet_the_attrs_are_empty() raises:
    var ws = _graph()
    var nid = mint_entity(
        ws, EntityMention("Delta", "", ""), _vec(0.5, 0.5, 0.5, 0.5), "p1", "", ""
    )
    assert_equal(nid, Int64(2))
    assert_equal(ws.entities[2].attrs, "{}")
    var next = mint_entity(
        ws, EntityMention("Eps", "", ""), _vec(0.5, 0.5, 0.5, 0.5), "p1", "", ""
    )
    assert_equal(next, Int64(3))


def test_an_embedding_of_another_length_is_refused() raises:
    var ws = _graph()
    var llm = StubLlmClient()
    with assert_raises(contains="3 components but the graph's dimension is 4"):
        _ = resolve_entities(
            ws, _one("Gamma Quarry"), llm, ShortEmbedder(), "p1",
            IngestConfig.default(),
        )
    assert_equal(ws.num_entities(), 2)
    with assert_raises(contains="3 components but the graph's dimension is 4"):
        _ = mint_entity(
            ws, EntityMention("X", "", ""), _short_vec(), "p1", "", ""
        )


def _short_vec() -> List[Float64]:
    var v = List[Float64]()
    v.append(1.0)
    v.append(0.0)
    v.append(0.0)
    return v^


def test_an_embedding_beyond_f32_is_refused() raises:
    var ws = _graph()
    var llm = StubLlmClient()
    var emb = _embedder()
    emb.add_vector("Gamma Quarry", _vec(1.0e300, 0.0, 0.0, 0.0))
    with assert_raises(contains="is not a finite f32"):
        _ = resolve_entities(
            ws, _one("Gamma Quarry"), llm, emb, "p1", IngestConfig.default()
        )
    assert_equal(ws.num_entities(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
