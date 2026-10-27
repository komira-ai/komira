# =============================================================================
# test_structured.mojo -- the structured-ingest body.
# =============================================================================
#
#   full       every field read: entities with type and summary, edges with
#              predicate, fact and both times, and the envelope.
#   defaults   an entity without type and summary has "", an edge without a
#              fact has "<subject> <predicate> <object>", without times has the
#              open sentinel, the envelope's uuid is "structured" and the rest
#              "" or none.
#   required   `entities` and `edges` must be present arrays; an entity needs a
#              name; an edge a subject and an object; the body an object.
#   types      a field of the wrong type is refused, not defaulted (the source
#              ignored a malformed time and a non-string and carried on).
#   malformed  invalid JSON, a body that is not UTF-8 and trailing text are
#              refused.
#   take       the extraction moves out once.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_capture import parse_structured_request
from komira_kg_format import TS_OPEN_SENTINEL


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def test_a_full_body_is_read_field_by_field() raises:
    var body = _bytes(
        '{"entities":[{"name":"Ada","type":"person","summary":"an analyst"},'
        '{"name":"Acme"}],'
        '"edges":[{"subject":"Ada","predicate":"works_at","object":"Acme",'
        '"fact":"Ada works at Acme","valid_at":100,"invalid_at":200}],'
        '"uuid":"u-1","partition":"p-9","valid_at":55,"body":"a note",'
        '"source":"s-1","facet":"f-1","facet_source":"fs-1"}'
    )
    var req = parse_structured_request(body)
    assert_equal(req.num_entities, 2)
    assert_equal(req.num_edges, 1)
    assert_equal(req.uuid, "u-1")
    assert_equal(req.partition_id, "p-9")
    assert_true(Bool(req.valid_at))
    assert_equal(req.valid_at.value(), Int64(55))
    assert_equal(req.note, "a note")
    assert_equal(req.source, "s-1")
    assert_equal(req.facet, "f-1")
    assert_equal(req.facet_source, "fs-1")
    var ex = req.take_extraction()
    assert_equal(ex.num_entities(), 2)
    assert_equal(ex.entities[0].name, "Ada")
    assert_equal(ex.entities[0].entity_type, "person")
    assert_equal(ex.entities[0].summary, "an analyst")
    assert_equal(ex.entities[1].name, "Acme")
    assert_equal(ex.entities[1].entity_type, "")
    assert_equal(ex.entities[1].summary, "")
    assert_equal(ex.num_triples(), 1)
    assert_equal(ex.triples[0].subject_name, "Ada")
    assert_equal(ex.triples[0].predicate, "works_at")
    assert_equal(ex.triples[0].object_name, "Acme")
    assert_equal(ex.triples[0].fact, "Ada works at Acme")
    assert_equal(ex.triples[0].valid_at, Int64(100))
    assert_equal(ex.triples[0].invalid_at, Int64(200))


def test_defaults_when_a_field_is_absent() raises:
    var req = parse_structured_request(
        _bytes('{"entities":[],"edges":[{"subject":"A","object":"B"}]}')
    )
    assert_equal(req.num_entities, 0)
    assert_equal(req.uuid, "structured")
    assert_equal(req.partition_id, "")
    assert_false(Bool(req.valid_at))
    assert_equal(req.note, "")
    assert_equal(req.source, "")
    assert_equal(req.facet, "")
    assert_equal(req.facet_source, "")
    var ex = req.take_extraction()
    assert_equal(ex.triples[0].predicate, "")
    assert_equal(ex.triples[0].fact, "A  B")  # "<subject> <predicate> <object>"
    assert_equal(ex.triples[0].valid_at, TS_OPEN_SENTINEL)
    assert_equal(ex.triples[0].invalid_at, TS_OPEN_SENTINEL)


def test_a_missing_fact_is_built_from_the_triple() raises:
    var req = parse_structured_request(
        _bytes('{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}]}')
    )
    assert_equal(req.take_extraction().triples[0].fact, "A p B")
    var empty_fact = parse_structured_request(
        _bytes('{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B","fact":""}]}')
    )
    assert_equal(empty_fact.take_extraction().triples[0].fact, "A p B")


def test_required_parts_are_enforced() raises:
    with assert_raises(contains="object"):
        _ = parse_structured_request(_bytes("[]"))
    with assert_raises(contains="'entities' is required"):
        _ = parse_structured_request(_bytes('{"edges":[]}'))
    with assert_raises(contains="'edges' is required"):
        _ = parse_structured_request(_bytes('{"entities":[]}'))
    with assert_raises(contains="'entities' must be an array"):
        _ = parse_structured_request(_bytes('{"entities":{},"edges":[]}'))
    with assert_raises(contains="'edges' must be an array"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":"x"}'))
    with assert_raises(contains="entities[1] must be an object"):
        _ = parse_structured_request(_bytes('{"entities":[{"name":"a"},3],"edges":[]}'))
    with assert_raises(contains="entities[0] needs"):
        _ = parse_structured_request(_bytes('{"entities":[{"type":"t"}],"edges":[]}'))
    with assert_raises(contains="entities[0] needs"):
        _ = parse_structured_request(_bytes('{"entities":[{"name":""}],"edges":[]}'))
    with assert_raises(contains="edges[0] must be an object"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[null]}'))
    with assert_raises(contains="edges[0] needs"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[{"object":"B"}]}'))
    with assert_raises(contains="edges[0] needs"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[{"subject":"A"}]}'))


def test_a_field_of_the_wrong_type_is_refused() raises:
    with assert_raises(contains="'name' must be a string"):
        _ = parse_structured_request(_bytes('{"entities":[{"name":5}],"edges":[]}'))
    with assert_raises(contains="'type' must be a string"):
        _ = parse_structured_request(_bytes('{"entities":[{"name":"a","type":[]}],"edges":[]}'))
    with assert_raises(contains="'uuid' must be a string"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[],"uuid":7}'))
    with assert_raises(contains="'facet' must be a string"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[],"facet":null}'))
    with assert_raises(contains="'valid_at' must be an integer"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[],"valid_at":"7"}'))
    with assert_raises(contains="'valid_at' must be an integer"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[],"valid_at":1.5}'))
    with assert_raises(contains="'valid_at' must be an integer"):
        _ = parse_structured_request(
            _bytes('{"entities":[],"edges":[{"subject":"A","object":"B","valid_at":true}]}')
        )
    with assert_raises(contains="'invalid_at' must be an integer"):
        _ = parse_structured_request(
            _bytes('{"entities":[],"edges":[{"subject":"A","object":"B","invalid_at":1e3}]}')
        )
    with assert_raises():  # outside the Int64 range
        _ = parse_structured_request(
            _bytes('{"entities":[],"edges":[],"valid_at":99999999999999999999}')
        )


def test_malformed_json_is_refused() raises:
    with assert_raises(contains="JsonError"):
        _ = parse_structured_request(_bytes('{"entities":[],'))
    with assert_raises(contains="JsonError"):
        _ = parse_structured_request(_bytes('{"entities":[],"edges":[]} x'))
    with assert_raises(contains="JsonError"):
        _ = parse_structured_request(_bytes(""))
    var bad = _bytes('{"entities":[{"name":"')
    bad.append(0xFF)
    bad.extend('"}],"edges":[]}'.as_bytes())
    with assert_raises(contains="JsonError"):
        _ = parse_structured_request(bad)


def test_the_extraction_moves_out_once() raises:
    var req = parse_structured_request(_bytes('{"entities":[],"edges":[]}'))
    _ = req.take_extraction()
    with assert_raises(contains="already taken"):
        _ = req.take_extraction()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
