# =============================================================================
# komira_git/tests/test_ref_names.mojo -- check-ref-format rules.
# =============================================================================
#
# WHERE THE ROWS COME FROM:
#   * every `valid_ref` / `invalid_ref` / `valid_ref_normalized` /
#     `invalid_ref_normalized` row of git v2.47.0 t/t1402-check-ref-format.sh
#     (the `!MINGW` prerequisite dropped: it only skips rows on Windows),
#     with the options each row passes (`--allow-onelevel`,
#     `--refspec-pattern`, `--normalize`);
#   * `_GIT_ROWS`: further names checked with git 2.51.0
#     `git check-ref-format <name>` (no options), which printed the verdict
#     recorded beside each. These are committed vectors; a build-time
#     differential against a pinned git replaces them when the git oracle
#     package lands.
#
# WHAT EACH TEST CATCHES (mutants named in the PR):
#   * accepting a component ending in `.lock`: rows `heads/foo.lock`,
#     `foo.lock/bar`, `a/.lock` go valid;
#   * accepting `@{`: rows `heads/v@{ation`, `a/@{` go valid;
#   * test_messages pins each rule's refusal text.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import check_ref_format, check_ref_name, is_valid_ref_name, normalize_ref_name


def _ok(name: String, opts: String) -> Bool:
    var onelevel = "--allow-onelevel" in opts
    var pattern = "--refspec-pattern" in opts
    if "--normalize" in opts:
        try:
            _ = normalize_ref_name(name, onelevel, pattern)
        except:
            return False
        return True
    return is_valid_ref_name(name, onelevel, pattern)


def _row(valid: Bool, name: String, opts: String = "") raises:
    if _ok(name, opts) != valid:
        raise Error(
            "row disagrees with git: '" + name + "' " + opts + " should be "
            + ("valid" if valid else "invalid")
        )


def _bytes_ok(name: List[UInt8]) -> Bool:
    try:
        check_ref_name(Span(name))
    except:
        return False
    return True


def test_t1402_rows() raises:
    _row(False, "")
    _row(False, "/")
    _row(False, "/", "--allow-onelevel")
    _row(False, "/", "--normalize")
    _row(False, "/", "--allow-onelevel --normalize")
    _row(True, "foo/bar/baz")
    _row(True, "foo/bar/baz", "--normalize")
    _row(False, "refs///heads/foo")
    _row(True, "refs///heads/foo", "--normalize")
    _row(False, "heads/foo/")
    _row(False, "/heads/foo")
    _row(True, "/heads/foo", "--normalize")
    _row(False, "///heads/foo")
    _row(True, "///heads/foo", "--normalize")
    _row(False, "./foo")
    _row(False, "./foo/bar")
    _row(False, "foo/./bar")
    _row(False, "foo/bar/.")
    _row(False, ".refs/foo")
    _row(False, "refs/heads/foo.")
    _row(False, "heads/foo..bar")
    _row(False, "heads/foo?bar")
    _row(True, "foo./bar")
    _row(False, "heads/foo.lock")
    _row(False, "heads///foo.lock")
    _row(False, "foo.lock/bar")
    _row(False, "foo.lock///bar")
    _row(True, "heads/foo@bar")
    _row(False, "heads/v@{ation")
    _row(False, "heads/foo\\bar")
    _row(False, "heads/foo\t")
    _row(True, "heads/fuß")
    _row(True, "heads/*foo/bar", "--refspec-pattern")
    _row(True, "heads/foo*/bar", "--refspec-pattern")
    _row(True, "heads/f*o/bar", "--refspec-pattern")
    _row(False, "heads/f*o*/bar", "--refspec-pattern")
    _row(False, "heads/foo*/bar*", "--refspec-pattern")
    _row(False, "foo")
    _row(True, "foo", "--allow-onelevel")
    _row(False, "foo", "--refspec-pattern")
    _row(True, "foo", "--refspec-pattern --allow-onelevel")
    _row(False, "foo", "--normalize")
    _row(True, "foo", "--allow-onelevel --normalize")
    _row(True, "foo/bar")
    _row(True, "foo/bar", "--allow-onelevel")
    _row(True, "foo/bar", "--refspec-pattern")
    _row(True, "foo/bar", "--refspec-pattern --allow-onelevel")
    _row(True, "foo/bar", "--normalize")
    _row(False, "foo/*")
    _row(False, "foo/*", "--allow-onelevel")
    _row(True, "foo/*", "--refspec-pattern")
    _row(True, "foo/*", "--refspec-pattern --allow-onelevel")
    _row(False, "*/foo")
    _row(False, "*/foo", "--allow-onelevel")
    _row(True, "*/foo", "--refspec-pattern")
    _row(True, "*/foo", "--refspec-pattern --allow-onelevel")
    _row(False, "*/foo", "--normalize")
    _row(True, "*/foo", "--refspec-pattern --normalize")
    _row(False, "foo/*/bar")
    _row(False, "foo/*/bar", "--allow-onelevel")
    _row(True, "foo/*/bar", "--refspec-pattern")
    _row(True, "foo/*/bar", "--refspec-pattern --allow-onelevel")
    _row(False, "*")
    _row(False, "*", "--allow-onelevel")
    _row(False, "*", "--refspec-pattern")
    _row(True, "*", "--refspec-pattern --allow-onelevel")
    _row(False, "foo/*/*", "--refspec-pattern")
    _row(False, "foo/*/*", "--refspec-pattern --allow-onelevel")
    _row(False, "*/foo/*", "--refspec-pattern")
    _row(False, "*/foo/*", "--refspec-pattern --allow-onelevel")
    _row(False, "*/*/foo", "--refspec-pattern")
    _row(False, "*/*/foo", "--refspec-pattern --allow-onelevel")
    _row(False, "/foo")
    _row(False, "/foo", "--allow-onelevel")
    _row(False, "/foo", "--refspec-pattern")
    _row(False, "/foo", "--refspec-pattern --allow-onelevel")
    _row(False, "/foo", "--normalize")
    _row(True, "/foo", "--allow-onelevel --normalize")
    _row(False, "/foo", "--refspec-pattern --normalize")
    _row(True, "/foo", "--refspec-pattern --allow-onelevel --normalize")
    # "$(printf 'heads/foo\177')": DEL, built from bytes.
    var del_name = List[UInt8]("heads/foo".as_bytes())
    del_name.append(UInt8(0x7F))
    assert_false(_bytes_ok(del_name))


def test_t1402_normalized() raises:
    assert_equal(normalize_ref_name("heads/foo"), "heads/foo")
    assert_equal(normalize_ref_name("refs///heads/foo"), "refs/heads/foo")
    assert_equal(normalize_ref_name("/heads/foo"), "heads/foo")
    assert_equal(normalize_ref_name("///heads/foo"), "heads/foo")
    _row(False, "foo", "--normalize")
    _row(False, "/foo", "--normalize")
    _row(False, "heads/foo/../bar", "--normalize")
    _row(False, "heads/./foo", "--normalize")
    _row(False, "heads\\foo", "--normalize")
    _row(False, "heads/foo.lock", "--normalize")
    _row(False, "heads///foo.lock", "--normalize")
    _row(False, "foo.lock/bar", "--normalize")
    _row(False, "foo.lock///bar", "--normalize")


def test_git_rows() raises:
    _row(False, "@")
    _row(True, "a/@")
    _row(True, "refs/heads/@")
    _row(True, "a/@b")
    _row(True, "a/b@")
    _row(True, "a/{@")
    _row(False, "a/@{")
    _row(False, "a/b~1")
    _row(False, "a/b^")
    _row(False, "a/b:c")
    _row(False, "a/b[c")
    _row(False, "a b/c")
    _row(True, "a/b.lock.x")
    _row(False, "a/.lock")
    _row(False, "a/b..")
    _row(True, "refs/heads/main")
    _row(True, "refs/tags/v1.0")
    _row(True, "refs/heads/feature/x-y_z")
    _row(False, "a/b.")
    _row(True, "a./b")
    _row(True, "a/-b")
    _row(False, "refs/heads/.hidden")


def _msg(name: String, onelevel: Bool = False, pattern: Bool = False) -> String:
    try:
        check_ref_format(name, onelevel, pattern)
    except e:
        return String(e)
    return String("OK")


def test_messages() raises:
    var p = "komira_git: bad ref name: "
    assert_equal(_msg("refs/heads/main"), "OK")
    assert_equal(_msg("@"), p + "is '@'")
    assert_equal(_msg("heads/foo..bar"), p + "contains '..'")
    assert_equal(_msg("heads/v@{ation"), p + "contains '@{'")
    assert_equal(_msg("heads/foo\t"), p + "contains byte 0x09")
    assert_equal(_msg("heads/foo\\bar"), p + "contains byte 0x5c")
    assert_equal(_msg("heads/foo?bar"), p + "contains byte 0x3f")
    assert_equal(_msg("foo/*"), p + "contains '*'")
    assert_equal(_msg("heads/f*o*/bar", False, True), p + "contains more than one '*'")
    assert_equal(_msg("heads/foo/"), p + "has an empty component")
    assert_equal(_msg(""), p + "has an empty component")
    assert_equal(_msg("./foo"), p + "has a component starting with '.'")
    assert_equal(_msg("heads/foo.lock"), p + "has a component ending with '.lock'")
    assert_equal(_msg("refs/heads/foo."), p + "ends with '.'")
    assert_equal(_msg("foo"), p + "has one component (allow_onelevel is off)")
    assert_true(is_valid_ref_name("foo", True))


def main() raises:
    test_t1402_rows()
    test_t1402_normalized()
    test_git_rows()
    test_messages()
    print("komira_git ref name tests passed")
