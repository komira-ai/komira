# =============================================================================
# src/kci_release_set/tests/test_set_hash.mojo
#   The release set hash (kci.release_set major 2): a golden vector,
#   independent of input order, and changed by any one field of any one
#   line, by the revision and by the platform.
# =============================================================================
#
# The golden value was computed outside Mojo:
#   python3 -c 'import hashlib; print(hashlib.sha256((H + "".join(sorted(L))).encode()).hexdigest())'
# with H = "release_set\t2\t<_REV>\tlinux-x86_64\n" and L the three lines of
# `_lines()` below, each
#   <name>\t<platform>\t<version>\t<build>\t<subdir>\t<artifact_type>\t<sha256>\n.
# A change to the header, the line format, the separator, the sort or the
# hash breaks it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set import SetHashLine, bytewise_less, set_hash_of_lines, set_hash_text

comptime _GOLDEN = "7a85e80aabbb553803809d3c2b516b8eaaeae467668051498fbeb82790682efe"
comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _PLAT = "linux-x86_64"
comptime _A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
comptime _B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
comptime _C = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
comptime _BUILD = "h01234567_7"


def _line(name: String, sha: String) -> SetHashLine:
    return SetHashLine(
        name.copy(), String(_PLAT), String("1.0.0"), String(_BUILD), String("linux-64"),
        String("CONDA"), sha.copy(),
    )


def _lines() -> List[SetHashLine]:
    var l = List[SetHashLine]()
    l.append(_line(String("komira_hash"), String(_A)))
    l.append(_line(String("komira_name_registry"), String(_B)))
    l.append(_line(String("komira"), String(_C)))
    return l^


def _hash(lines: List[SetHashLine]) raises -> String:
    return set_hash_of_lines(String(_REV), String(_PLAT), lines)


def test_golden_vector() raises:
    assert_equal(_hash(_lines()), String(_GOLDEN))


def test_text_is_a_header_then_sorted_tab_separated_lines() raises:
    var tail = String("\tlinux-x86_64\t1.0.0\th01234567_7\tlinux-64\tCONDA\t")
    assert_equal(
        set_hash_text(String(_REV), String(_PLAT), _lines()),
        String("release_set\t2\t") + String(_REV) + String("\tlinux-x86_64\n")
        + String("komira") + tail + String(_C) + String("\n")
        + String("komira_hash") + tail + String(_A) + String("\n")
        + String("komira_name_registry") + tail + String(_B) + String("\n"),
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
        assert_equal(_hash(l), String(_GOLDEN))


def test_any_one_field_of_any_one_line_changes_it() raises:
    for i in range(3):
        for field in range(7):
            var l = _lines()
            if field == 0:
                l[i].name += String("x")
            elif field == 1:
                l[i].platform = String("noarch")
            elif field == 2:
                l[i].version = String("1.0.1")
            elif field == 3:
                l[i].build = String("h01234567_8")
            elif field == 4:
                l[i].subdir = String("noarch")
            elif field == 5:
                l[i].artifact_type = String("PYTHON")
            else:
                l[i].sha256_hex = String("d") + String(l[i].sha256_hex[byte = 1:])
            assert_true(
                _hash(l) != String(_GOLDEN),
                String("line ") + String(i) + String(" field ") + String(field),
            )


def test_the_revision_and_the_platform_are_in_the_hash() raises:
    var other_rev = String("1123456789abcdef0123456789abcdef01234567")
    assert_true(set_hash_of_lines(other_rev, String(_PLAT), _lines()) != String(_GOLDEN))
    # the platform is in the header even when no member line changes
    var noarch = List[SetHashLine]()
    for i in range(3):
        var l = _lines()[i].copy()
        l.platform = String("noarch")
        l.subdir = String("noarch")
        noarch.append(l^)
    var t1 = set_hash_text(String(_REV), String(_PLAT), noarch)
    assert_true(t1.startswith(String("release_set\t2\t") + String(_REV) + String("\tlinux-x86_64\n")))


def _refusal(lines: List[SetHashLine], rev: String = String(_REV), plat: String = String(_PLAT)) -> String:
    try:
        _ = set_hash_of_lines(rev, plat, lines)
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
    var sub = _lines()
    sub[0].subdir = String("linux\t64")
    assert_equal(_refusal(sub), String("release set hash: komira_hash: subdir holds a TAB or a newline"))
    var upper = _lines()
    upper[2].sha256_hex = String(_C).upper()
    assert_equal(
        _refusal(upper), String("release set hash: komira: sha256 is not 64 lowercase hex characters")
    )
    assert_true(_refusal(_lines(), rev=String("0123abc")).find(String("is not a full commit id")) >= 0)
    assert_true(_refusal(_lines(), plat=String("darwin-arm64")).find(String("is not released")) >= 0)
    assert_true(_refusal(_lines(), plat=String("noarch")).find(String("never a release's")) >= 0)


def test_bytewise_less() raises:
    assert_true(bytewise_less(String("komira\t"), String("komira_")))
    assert_true(bytewise_less(String("Z"), String("a")))
    assert_true(bytewise_less(String("ab"), String("abc")))
    assert_false(bytewise_less(String("abc"), String("abc")))
    assert_false(bytewise_less(String("b"), String("a")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
