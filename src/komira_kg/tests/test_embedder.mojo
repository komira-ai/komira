# =============================================================================
# test_embedder.mojo -- the Embedder seam and the deterministic StubEmbedder.
# =============================================================================
#
#   dimension     the stub reports the dimension it was built with, whatever it
#                 is; a zero or negative dimension is refused (no default).
#   width         for a dimension d, every vector the stub returns (fallback,
#                 registered, batch) has d components and passes
#                 unpack_embedding_checked(d) after pack_embedding; the same
#                 cell is refused for d + 1.
#   determinism   the same text gives the same vector on every call and from
#                 every instance; case does not matter; the vector has unit
#                 length, also for an empty text.
#   histogram     the fallback is the character-class histogram folded into d
#                 buckets: stated inputs give stated components.
#   similarity    near-duplicate texts have a higher cosine than unrelated ones.
#   registered    a registered vector wins over the fallback, must have d
#                 components, and is replaced by a second registration.
#   batch         embed_batch is embed per text, in input order.
#   trait         a function generic over Embedder instantiates with the stub.
# No test reads a clock or the environment.
# =============================================================================

from std.math import sqrt
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import Embedder, StubEmbedder
from komira_kg_format import cosine, pack_embedding, unpack_embedding_checked


def _norm(v: List[Float64]) -> Float64:
    var s = 0.0
    for i in range(len(v)):
        s += v[i] * v[i]
    return sqrt(s)


def _drive_embed[E: Embedder](e: E, text: String) raises -> List[Float64]:
    return e.embed(text)


def _drive_dimension[E: Embedder](e: E) -> Int:
    return e.dimension()


def test_the_stub_reports_the_dimension_it_was_built_with() raises:
    assert_equal(StubEmbedder(1).dimension(), 1)
    assert_equal(StubEmbedder(4).dimension(), 4)
    assert_equal(StubEmbedder(28).dimension(), 28)
    assert_equal(StubEmbedder(1536).dimension(), 1536)


def test_a_dimension_that_is_not_positive_is_refused() raises:
    with assert_raises(contains="dimension must be positive"):
        _ = StubEmbedder(0)
    with assert_raises(contains="dimension must be positive"):
        _ = StubEmbedder(-3)


def _check_width(d: Int) raises:
    var e = StubEmbedder(d)
    var v = e.embed("Alpha Service 7")
    assert_equal(len(v), d)
    var cell = pack_embedding(v)
    var back = unpack_embedding_checked(cell.as_bytes(), d)
    assert_equal(len(back), d)
    for i in range(d):
        assert_almost_equal(back[i], v[i], atol=1e-6)
    # The same cell is the wrong width for a graph of dimension d + 1.
    with assert_raises(contains="not a dimension of"):
        _ = unpack_embedding_checked(cell.as_bytes(), d + 1)


def test_a_vector_of_dimension_d_passes_the_checked_unpack_for_d() raises:
    _check_width(1)
    _check_width(7)
    _check_width(28)
    _check_width(96)


def test_registered_and_batch_vectors_have_the_dimension_too() raises:
    var e = StubEmbedder(5)
    var v: List[Float64] = [1.0, 0.0, 0.5, 0.0, 2.0]
    e.add_vector("pinned", v^)
    var texts: List[String] = ["pinned", "other", ""]
    var vecs = e.embed_batch(texts)
    assert_equal(len(vecs), 3)
    for i in range(3):
        var cell = pack_embedding(vecs[i])
        assert_equal(len(unpack_embedding_checked(cell.as_bytes(), 5)), 5)


def test_the_same_text_gives_the_same_vector() raises:
    var a = StubEmbedder(28)
    var b = StubEmbedder(28)
    var v1 = a.embed("Alpha Service")
    var v2 = a.embed("Alpha Service")
    var v3 = b.embed("Alpha Service")
    for i in range(28):
        assert_equal(v1[i], v2[i])
        assert_equal(v1[i], v3[i])


def test_case_is_folded() raises:
    var e = StubEmbedder(28)
    var lower = e.embed("alpha service")
    var upper = e.embed("ALPHA Service")
    for i in range(28):
        assert_equal(lower[i], upper[i])


def test_the_fallback_vector_has_unit_length() raises:
    var e = StubEmbedder(28)
    assert_almost_equal(_norm(e.embed("Alpha Service 7")), 1.0, atol=1e-12)
    assert_almost_equal(_norm(e.embed("x")), 1.0, atol=1e-12)
    assert_almost_equal(_norm(e.embed("a much longer text " * 20)), 1.0, atol=1e-12)


def test_an_empty_text_is_a_unit_vector_on_the_other_class() raises:
    var e = StubEmbedder(28)
    var v = e.embed("")
    assert_equal(v[27], 1.0)
    assert_almost_equal(_norm(v), 1.0, atol=1e-12)
    # With a narrower embedder the "other" class folds to bucket 27 % 4 == 3.
    var narrow = StubEmbedder(4).embed("")
    assert_equal(narrow[3], 1.0)
    assert_equal(narrow[0], 0.0)


def test_the_fallback_is_the_character_class_histogram() raises:
    var e = StubEmbedder(28)
    var ab = e.embed("ab")
    assert_almost_equal(ab[0], 1.0 / sqrt(2.0), atol=1e-12)
    assert_almost_equal(ab[1], 1.0 / sqrt(2.0), atol=1e-12)
    assert_equal(ab[2], 0.0)
    # Class 26 counts digits, class 27 counts every other byte.
    var mixed = e.embed("a1 ")
    assert_almost_equal(mixed[0], 1.0 / sqrt(3.0), atol=1e-12)
    assert_almost_equal(mixed[26], 1.0 / sqrt(3.0), atol=1e-12)
    assert_almost_equal(mixed[27], 1.0 / sqrt(3.0), atol=1e-12)


def test_classes_fold_modulo_the_dimension() raises:
    # Letters a (class 0) and e (class 4) share bucket 0 when the width is 4,
    # and b (class 1) lands in bucket 1.
    var e = StubEmbedder(4)
    var ae = e.embed("ae")
    assert_equal(ae[0], 1.0)
    assert_equal(ae[1], 0.0)
    var b = e.embed("b")
    assert_equal(b[1], 1.0)
    assert_equal(b[0], 0.0)


def test_near_duplicates_are_closer_than_unrelated_texts() raises:
    var e = StubEmbedder(28)
    var base = e.embed("Alpha Corporation")
    var near = e.embed("Alpha Corporaton")
    var far = e.embed("Zenith Logistics Group")
    assert_true(cosine(base, near) > 0.95)
    assert_true(cosine(base, far) < cosine(base, near))
    assert_almost_equal(cosine(base, base), 1.0, atol=1e-12)


def test_a_registered_vector_wins_over_the_fallback() raises:
    var e = StubEmbedder(4)
    var v: List[Float64] = [1.0, 0.0, 0.9, 0.0]
    e.add_vector("pinned", v^)
    var got = e.embed("pinned")
    assert_equal(got[0], 1.0)
    assert_equal(got[1], 0.0)
    assert_equal(got[2], 0.9)
    assert_equal(got[3], 0.0)
    # Another text still gets the fallback.
    assert_almost_equal(_norm(e.embed("unpinned")), 1.0, atol=1e-12)


def test_a_registered_vector_of_the_wrong_length_is_refused() raises:
    var e = StubEmbedder(4)
    var short: List[Float64] = [1.0, 0.0]
    with assert_raises(contains="dimension is 4"):
        e.add_vector("pinned", short^)
    var long: List[Float64] = [1.0, 0.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="5 components"):
        e.add_vector("pinned", long^)
    # Nothing was registered: the text still gets the fallback.
    assert_almost_equal(_norm(e.embed("pinned")), 1.0, atol=1e-12)


def test_registering_a_text_again_replaces_its_vector() raises:
    var e = StubEmbedder(2)
    var first: List[Float64] = [1.0, 0.0]
    var second: List[Float64] = [0.0, 3.0]
    e.add_vector("t", first^)
    e.add_vector("t", second^)
    var got = e.embed("t")
    assert_equal(got[0], 0.0)
    assert_equal(got[1], 3.0)


def test_a_batch_is_embed_per_text_in_order() raises:
    var e = StubEmbedder(28)
    var texts: List[String] = ["alpha", "beta", "gamma"]
    var vecs = e.embed_batch(texts)
    assert_equal(len(vecs), 3)
    for t in range(3):
        var single = e.embed(texts[t])
        for i in range(28):
            assert_equal(vecs[t][i], single[i])
    assert_equal(len(e.embed_batch(List[String]())), 0)


def test_a_function_generic_over_embedder_takes_the_stub() raises:
    var e = StubEmbedder(9)
    assert_equal(_drive_dimension(e), 9)
    assert_equal(len(_drive_embed(e, "anything")), 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
