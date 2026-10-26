# =============================================================================
# test_name_similarity.mojo -- the string math under deduplication.
# =============================================================================
#
#   normalize   case, whitespace runs and ASCII punctuation fold away; digits
#               stay; a name in another script keeps its letters, so two
#               different such names do not normalize alike; the result is
#               stable under a second pass; a name with no letter or digit is "".
#   entropy     "" and a repeated byte score 0.0, uniform distributions score
#               their log2, a varied name scores above a generic one.
#   signature   a signature has the fixed length, is the same on every call, and
#               equals independently computed hash values (so a change of hash
#               or seed shows).
#   similarity  identical names estimate 1.0 and share a band; unrelated names
#               estimate low and share none; signatures of unequal length or
#               empty signatures score 0.0 and never collide.
#   decision    pair_decision merges only on a band collision at the merge floor,
#               escalates anything else at the escalation floor, ignores the rest.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg import (
    LSH_NUM_BANDS,
    MINHASH_NUM_PERM,
    PAIR_ESCALATE,
    PAIR_MERGE,
    PAIR_NONE,
    jaccard_estimate,
    lsh_candidate,
    minhash_signature,
    normalize_name,
    pair_decision,
    shannon_entropy,
)


def _near(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 1.0e-9


def test_normalize_folds_case_space_and_punctuation() raises:
    assert_equal(normalize_name("Acme Inc"), "acme inc")
    assert_equal(normalize_name("acme inc "), "acme inc")
    assert_equal(normalize_name("  ACME,  INC. "), "acme inc")
    assert_equal(normalize_name("Acme, Inc."), "acme inc")
    assert_equal(normalize_name("a-b_c"), "a b c")
    assert_equal(normalize_name("a\tb\nc"), "a b c")
    assert_equal(normalize_name("x1   y2"), "x1 y2")


def test_normalize_gives_empty_for_no_letter_or_digit() raises:
    assert_equal(normalize_name(""), "")
    assert_equal(normalize_name("   "), "")
    assert_equal(normalize_name("!!! ... ???"), "")


def test_normalize_keeps_letters_of_other_scripts() raises:
    assert_equal(normalize_name("Zoë"), "zoë")
    assert_equal(normalize_name("  Müller, GmbH "), "müller gmbh")
    assert_equal(normalize_name("東京 タワー"), "東京 タワー")
    # Different names in one script stay different, and differ from an ASCII
    # name whose only letters are shared.
    assert_true(normalize_name("東京") != normalize_name("大阪"))
    assert_true(normalize_name("Zoë") != normalize_name("Zo"))


def test_normalize_is_idempotent() raises:
    var names = List[String]()
    names.append("  ACME,  INC. ")
    names.append("Müller--GmbH")
    names.append("東京  タワー!")
    names.append("a\tb")
    for i in range(len(names)):
        var once = normalize_name(names[i])
        assert_equal(normalize_name(once), once)


def test_entropy_of_simple_distributions() raises:
    assert_equal(shannon_entropy(""), 0.0)
    assert_equal(shannon_entropy("aaaa"), 0.0)
    assert_equal(shannon_entropy("abab"), 1.0)
    assert_equal(shannon_entropy("aabb"), 1.0)
    assert_equal(shannon_entropy("abcd"), 2.0)
    assert_true(_near(shannon_entropy("abcdefgh"), 3.0))


def test_entropy_is_higher_for_a_more_varied_name() raises:
    assert_true(shannon_entropy("catalog") < 2.6)
    assert_true(shannon_entropy("catalog tier change") > 3.0)


def test_signature_has_the_fixed_length_and_is_stable() raises:
    var a = minhash_signature("acme inc")
    var b = minhash_signature("acme inc")
    assert_equal(len(a), MINHASH_NUM_PERM)
    assert_equal(len(b), MINHASH_NUM_PERM)
    for i in range(len(a)):
        assert_equal(a[i], b[i])
    # An empty name still has a signature (one all-padding shingle).
    assert_equal(len(minhash_signature("")), MINHASH_NUM_PERM)


def test_signature_values_match_an_independent_computation() raises:
    # Values computed outside this code from the FNV-1a-64 definition, the seed
    # rule (p * 0x9E3779B97F4A7C15 + 1) and the padded 3-byte shingles of "ab".
    var sig = minhash_signature("ab")
    assert_equal(sig[0], UInt64(0xB48A3D774B679D00))
    assert_equal(sig[1], UInt64(0x8E8C920ADD9B6E7B))
    assert_equal(sig[2], UInt64(0x0C45F23B41597838))
    assert_equal(sig[31], UInt64(0x41BAA6273090969D))


def test_identical_names_agree_everywhere() raises:
    var a = minhash_signature(normalize_name("Acme Inc"))
    var b = minhash_signature(normalize_name("acme inc"))
    assert_equal(jaccard_estimate(a, b), 1.0)
    assert_true(lsh_candidate(a, b))


def test_unrelated_names_estimate_low_and_share_no_band() raises:
    var a = minhash_signature("acme catalog models")
    var far = minhash_signature("globex ltd")
    assert_true(jaccard_estimate(a, far) < 0.25)
    assert_false(lsh_candidate(a, far))


def test_a_near_duplicate_estimates_high_and_shares_a_band() raises:
    var a = minhash_signature("acme catalog models")
    var b = minhash_signature("acme catalog model")
    assert_true(jaccard_estimate(a, b) >= 0.7)
    assert_true(lsh_candidate(a, b))


def test_mismatched_or_empty_signatures_never_agree() raises:
    var a = minhash_signature("acme inc")
    var short = List[UInt64]()
    short.append(a[0])
    var empty = List[UInt64]()
    assert_equal(jaccard_estimate(a, short), 0.0)
    assert_equal(jaccard_estimate(empty, empty), 0.0)
    assert_false(lsh_candidate(a, short))
    assert_false(lsh_candidate(empty, empty))


def test_the_band_shape_divides_the_signature() raises:
    assert_equal(MINHASH_NUM_PERM % LSH_NUM_BANDS, 0)


def test_one_equal_band_is_a_collision_and_none_is_not() raises:
    var a = List[UInt64]()
    var b = List[UInt64]()
    for i in range(MINHASH_NUM_PERM):
        a.append(UInt64(i))
        b.append(UInt64(1000 + i))
    assert_false(lsh_candidate(a, b))
    # Make the last band (rows 28..31) identical; everything else still differs.
    for i in range(28, MINHASH_NUM_PERM):
        b[i] = a[i]
    assert_true(lsh_candidate(a, b))
    # Three of four rows of a band is not a band.
    b[31] = UInt64(7777)
    assert_false(lsh_candidate(a, b))


def test_pair_decision_merges_only_with_a_band_collision() raises:
    assert_equal(pair_decision(0.8, True, 0.7, 0.25), PAIR_MERGE)
    assert_equal(pair_decision(0.7, True, 0.7, 0.25), PAIR_MERGE)
    # Reaches the merge floor without a band collision: judged, not dropped.
    assert_equal(pair_decision(0.75, False, 0.7, 0.25), PAIR_ESCALATE)


def test_pair_decision_escalates_between_the_floors() raises:
    assert_equal(pair_decision(0.5, True, 0.7, 0.25), PAIR_ESCALATE)
    assert_equal(pair_decision(0.5, False, 0.7, 0.25), PAIR_ESCALATE)
    assert_equal(pair_decision(0.25, False, 0.7, 0.25), PAIR_ESCALATE)


def test_pair_decision_ignores_a_weak_pair() raises:
    assert_equal(pair_decision(0.24, False, 0.7, 0.25), PAIR_NONE)
    assert_equal(pair_decision(0.24, True, 0.7, 0.25), PAIR_NONE)
    assert_equal(pair_decision(0.0, False, 0.7, 0.25), PAIR_NONE)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
