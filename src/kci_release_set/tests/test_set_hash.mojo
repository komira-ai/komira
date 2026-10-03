# =============================================================================
# src/kci_release_set/tests/test_set_hash.mojo
#   The release set hash: a golden vector, independent of input order, and
#   changed by any one field of any one line.
# =============================================================================
#
# The golden value was computed outside Mojo:
#   python3 -c 'import hashlib; print(hashlib.sha256("".join(sorted(L)).encode()).hexdigest())'
# over the three lines of `_lines()` below. A change to the line format, the
# separator, the sort or the hash breaks it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set import SetHashLine, bytewise_less, set_hash_of_lines, set_hash_text

comptime _GOLDEN = "59bb8e78e2a6d922054394d1a1a60a46f1488b1d2f6da3aaea89b2880fbb1089"
comptime _A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
comptime _B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
comptime _C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
comptime _BUILD = "h01234567_7"


def _line(name: String, sha: String) -> SetHashLine:
    return SetHashLine(name.copy(), String("1.0.0"), String(_BUILD), sha.copy())


def _lines() -> List[SetHashLine]:
    var l = List[SetHashLine]()
    l.append(_line(String("komira_hash"), String(_A)))
    l.append(_line(String("komira_name_registry"), String(_B)))
    l.append(_line(String("komira"), String(_C)))
    return l^


def test_golden_vector() raises:
    assert_equal(set_hash_of_lines(_lines()), String(_GOLDEN))


def test_text_is_sorted_tab_separated_lines() raises:
    assert_equal(
        set_hash_text(_lines()),
        String("komira\t1.0.0\th01234567_7\t") + String(_C) + String("\n")
        + String("komira_hash\t1.0.0\th01234567_7\t") + String(_A) + String("\n")
        + String("komira_name_registry\t1.0.0\th01234567_7\t") + String(_B) + String("\n"),
    )


def test_every_permutation_gives_the_golden() raises:
    var base = _lines()
    var orders = List[List[Int]]()
    orders.append([0, 1, 2])
    orders.append([0, 2, 1])
    orders.append([1, 0, 2])
    orders.append([1, 2, 0])
    orders.append([2, 0, 1])
    orders.append([2, 1, 0])
    for o in range(len(orders)):
        var l = List[SetHashLine]()
        for k in range(3):
            l.append(base[orders[o][k]].copy())
        assert_equal(set_hash_of_lines(l), String(_GOLDEN))


def test_any_one_field_of_any_one_line_changes_it() raises:
    for i in range(3):
        for field in range(4):
            var l = _lines()
            if field == 0:
                l[i].name += String("x")
            elif field == 1:
                l[i].version = String("1.0.1")
            elif field == 2:
                l[i].build = String("h01234567_8")
            else:
                l[i].sha256_hex = String("d") + String(l[i].sha256_hex[byte = 1:])
            assert_true(
                set_hash_of_lines(l) != String(_GOLDEN),
                String("line ") + String(i) + String(" field ") + String(field),
            )


def _refusal(lines: List[SetHashLine]) -> String:
    try:
        _ = set_hash_of_lines(lines)
    except e:
        return String(e)
    return String("<hashed>")


def test_refusals() raises:
    assert_equal(_refusal(List[SetHashLine]()), String("release set hash: the set is EMPTY"))
    var tab = _lines()
    tab[1].version = String("1.0\t0")
    assert_equal(
        _refusal(tab), String("release set hash: komira_name_registry: version holds a TAB or a newline")
    )
    var nl = _lines()
    nl[0].build = String("h\n")
    assert_equal(_refusal(nl), String("release set hash: komira_hash: build holds a TAB or a newline"))
    var upper = _lines()
    upper[2].sha256_hex = String(_C).upper()
    assert_equal(
        _refusal(upper), String("release set hash: komira: sha256 is not 64 lowercase hex characters")
    )


def test_bytewise_less() raises:
    assert_true(bytewise_less(String("komira\t"), String("komira_")))
    assert_true(bytewise_less(String("Z"), String("a")))
    assert_true(bytewise_less(String("ab"), String("abc")))
    assert_false(bytewise_less(String("abc"), String("abc")))
    assert_false(bytewise_less(String("b"), String("a")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
