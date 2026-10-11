from std.testing import assert_equal, assert_true

from mutate.gen import generate
from mutate.sample import fnv1a64, parse_list, render_list, sample

# The sample: deterministic, the n smallest hashes in list order, all for 0
# or n >= count, mostly unmoved by an unrelated mutant; the list file round
# trip and its refusals.


def _ids(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("p.mojo:") + String(i + 1) + ":1:cmp_negate")
    return out^


def test_fnv_vectors() raises:
    # FNV-1a 64 reference values (the empty string is the offset basis).
    assert_equal(fnv1a64(String("")), UInt64(14695981039346656037))
    assert_equal(fnv1a64(String("a")), UInt64(12638187200555641996))
    assert_equal(fnv1a64(String("foobar")), UInt64(9625390261332436968))


def test_all_when_zero_or_large() raises:
    var ids = _ids(5)
    assert_equal(len(sample(ids, 0, String("s"))), 5)
    assert_equal(len(sample(ids, 5, String("s"))), 5)
    assert_equal(len(sample(ids, 9, String("s"))), 5)


def test_smallest_hashes_in_order() raises:
    var ids = _ids(40)
    var keep = sample(ids, 7, String("seed"))
    assert_equal(len(keep), 7)
    for i in range(1, len(keep)):
        assert_true(keep[i - 1] < keep[i])
    # every kept hash is below every dropped one
    var worst_kept = UInt64(0)
    for k in keep:
        worst_kept = max(worst_kept, fnv1a64(String("seed\n") + ids[k]))
    for i in range(len(ids)):
        var kept = False
        for k in keep:
            if k == i:
                kept = True
        if not kept:
            assert_true(fnv1a64(String("seed\n") + ids[i]) > worst_kept)
    # deterministic, and the seed matters
    var again = sample(ids, 7, String("seed"))
    for i in range(len(keep)):
        assert_equal(keep[i], again[i])
    var other = sample(ids, 7, String("other"))
    var same = True
    for i in range(len(keep)):
        if keep[i] != other[i]:
            same = False
    assert_true(not same)


def test_unrelated_mutant_moves_at_most_one() raises:
    var ids = _ids(40)
    var keep = sample(ids, 10, String("s"))
    var more = ids.copy()
    more.append(String("q.mojo:1:1:const_inc"))
    var keep2 = sample(more, 10, String("s"))
    var common = 0
    for a in keep:
        for b in keep2:
            if a == b:
                common += 1
    assert_true(common >= 9)


def test_list_round_trip() raises:
    var g = generate(String("x.mojo"), String("a = b < 1  # mutation: equivalent const_dec why\n"))
    var text = render_list(g.mutants, g.suppressed, 0, String("s"))
    var lf = parse_list(text)
    assert_equal(lf.header, "# mutate list: 2 mutants, 2 sampled, seed s")
    assert_equal(len(lf.rows), 2)
    assert_equal(lf.rows[0].id, "x.mojo:1:7:cmp_negate")
    assert_equal(lf.rows[0].path, "x.mojo")
    assert_equal(lf.rows[0].line, 1)
    assert_equal(lf.rows[0].col, 7)
    assert_equal(lf.rows[0].operator, "cmp_negate")
    assert_equal(lf.rows[0].description, "< -> >=")
    assert_equal(lf.rows[1].id, "x.mojo:1:9:const_inc")
    assert_equal(len(lf.suppressed), 1)
    assert_equal(lf.suppressed[0].id, "x.mojo:1:9:const_dec")
    assert_equal(lf.suppressed[0].kind, "equivalent")
    assert_equal(lf.suppressed[0].reason, "why")
    # a sample of 1 keeps one row and says so
    var one = parse_list(render_list(g.mutants, g.suppressed, 1, String("s")))
    assert_equal(len(one.rows), 1)
    assert_equal(one.header, "# mutate list: 2 mutants, 1 sampled, seed s")


def test_list_refusals() raises:
    var bad = List[String]()
    bad.append("a\tb\n")
    bad.append("i\tp\tx\t1\top\td\n")
    bad.append("i\tp\t1\t1\top\td")
    bad.append("# suppressed\tequivalent\tid\n")
    for i in range(len(bad)):
        var refused = False
        try:
            _ = parse_list(bad[i])
        except:
            refused = True
        assert_true(refused, bad[i])


def main() raises:
    test_fnv_vectors()
    test_all_when_zero_or_large()
    test_smallest_hashes_in_order()
    test_unrelated_mutant_moves_at_most_one()
    test_list_round_trip()
    test_list_refusals()
    print("test_sample: PASS")
