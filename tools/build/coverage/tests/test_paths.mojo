from std.testing import assert_equal, assert_true

from covcheck.paths import MAPPED, OUTSIDE, UNMAPPED, RepoFiles, is_test_source, map_path, package_of, parse_repo_files, repo_files_of

# From a report path to a repository file, in the documented order, with the
# path forms kcov really writes; and a file's package.


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("BUCK")
    l.append("README.md")
    l.append("src/komira_retry/BUCK")
    l.append("src/komira_retry/policy.mojo")
    l.append("src/komira_retry/tests/test_decide.mojo")
    l.append("src/komira_retry/inner/deep/x.mojo")
    l.append("src/other/BUCK")
    l.append("src/other/sub/BUCK")
    l.append("src/other/sub/y.mojo")
    l.append("tools/script.mojo")
    return repo_files_of(l)


def _no_prefixes() -> List[String]:
    return List[String]()


def _check(raw: String, pkgdir: String, prefixes: List[String], kind: Int, path: String) raises:
    var m = map_path(raw, pkgdir, prefixes, _repo())
    assert_equal(m.kind, kind, raw)
    assert_equal(m.path, path, raw)


def test_strip_prefix() raises:
    var p = List[String]()
    p.append("/worker/build/0123456789abcdef/root")
    _check(String("/worker/build/0123456789abcdef/root/src/komira_retry/policy.mojo"), String(""), p, MAPPED, String("src/komira_retry/policy.mojo"))


def test_longest_prefix_wins() raises:
    # With the shorter prefix the rest would be `checkout/src/...`, which is
    # outside; only the longer one maps it.
    var q = List[String]()
    q.append("/w")
    q.append("/w/checkout")
    _check(String("/w/checkout/src/komira_retry/policy.mojo"), String(""), q, MAPPED, String("src/komira_retry/policy.mojo"))
    var r = List[String]()
    r.append("/w/checkout/")
    r.append("/w")
    _check(String("/w/checkout/src/komira_retry/policy.mojo"), String(""), r, MAPPED, String("src/komira_retry/policy.mojo"))


def test_prefix_matches_only_at_a_segment_boundary() raises:
    var p = List[String]()
    p.append("/w/check")
    _check(String("/w/checkout/src/komira_retry/policy.mojo"), String(""), p, OUTSIDE, String("/w/checkout/src/komira_retry/policy.mojo"))


def test_buck_out_rewrite_real_kcov_form() raises:
    _check(
        String("buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/policy.mojo"),
        String(""), _no_prefixes(), MAPPED, String("src/komira_retry/policy.mojo"),
    )
    # Absolute, under the sandbox root, with no strip prefix given.
    _check(
        String("/worker/build/0123456789abcdef/root/buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/policy.mojo"),
        String(""), _no_prefixes(), MAPPED, String("src/komira_retry/policy.mojo"),
    )


def test_buck_out_needs_sixteen_hex_digits() raises:
    # 15 hex digits is not a content hash: no rewrite, and buck-out is not a
    # repository directory, so the path is outside.
    _check(
        String("buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba987654321/src/komira_retry/policy.mojo"),
        String(""), _no_prefixes(), OUTSIDE,
        String("buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba987654321/src/komira_retry/policy.mojo"),
    )


def test_relative_repo_path() raises:
    _check(String("src/komira_retry/policy.mojo"), String(""), _no_prefixes(), MAPPED, String("src/komira_retry/policy.mojo"))
    _check(String("./tools/script.mojo"), String(""), _no_prefixes(), MAPPED, String("tools/script.mojo"))


def test_pkgdir_resolves_kcov_test_paths() raises:
    _check(String("tests/test_decide.mojo"), String("src/komira_retry"), _no_prefixes(), MAPPED, String("src/komira_retry/tests/test_decide.mojo"))


def test_pkgdir_missing_file_is_unmapped() raises:
    _check(String("tests/test_gone.mojo"), String("src/komira_retry"), _no_prefixes(), UNMAPPED, String("src/komira_retry/tests/test_gone.mojo"))


def test_pkgdir_missing_one_segment_file_is_unmapped() raises:
    # A source directly in the package (no `/`) that is not a repository
    # file: unmapped, never set aside as outside.
    _check(String("gone.mojo"), String("src/komira_retry"), _no_prefixes(), UNMAPPED, String("src/komira_retry/gone.mojo"))
    _check(String("policy.mojo"), String("src/komira_retry"), _no_prefixes(), MAPPED, String("src/komira_retry/policy.mojo"))
    # Without PKGDIR a bare name names no repository directory: outside.
    _check(String("gone.mojo"), String(""), _no_prefixes(), OUTSIDE, String("gone.mojo"))


def test_without_pkgdir_a_package_relative_path_is_outside() raises:
    # `tests` is not a top-level directory of the repository.
    _check(String("tests/test_decide.mojo"), String(""), _no_prefixes(), OUTSIDE, String("tests/test_decide.mojo"))


def test_repo_directory_but_no_file_is_unmapped() raises:
    _check(String("src/komira_retry/gone.mojo"), String(""), _no_prefixes(), UNMAPPED, String("src/komira_retry/gone.mojo"))
    _check(
        String("buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/gone.mojo"),
        String(""), _no_prefixes(), UNMAPPED, String("src/komira_retry/gone.mojo"),
    )


def test_stdlib_relative_is_outside() raises:
    _check(String("oss/modular/mojo/stdlib/std/collections/list.mojo"), String(""), _no_prefixes(), OUTSIDE, String("oss/modular/mojo/stdlib/std/collections/list.mojo"))
    _check(String("oss/modular/mojo/stdlib/std/collections/list.mojo"), String("src/komira_retry"), _no_prefixes(), OUTSIDE, String("oss/modular/mojo/stdlib/std/collections/list.mojo"))


def test_absolute_without_prefix_is_outside() raises:
    _check(String("/opt/mojo/lib/std/builtin.mojo"), String(""), _no_prefixes(), OUTSIDE, String("/opt/mojo/lib/std/builtin.mojo"))


def test_package_is_nearest_buck() raises:
    var r = _repo()
    assert_equal(package_of(String("src/komira_retry/policy.mojo"), r), "src/komira_retry")
    assert_equal(package_of(String("src/komira_retry/inner/deep/x.mojo"), r), "src/komira_retry")
    assert_equal(package_of(String("src/other/sub/y.mojo"), r), "src/other/sub")
    assert_equal(package_of(String("tools/script.mojo"), r), "(root)")


def test_no_buck_anywhere_is_an_error() raises:
    var l = List[String]()
    l.append("src/a/x.mojo")
    var raised = False
    try:
        _ = package_of(String("src/a/x.mojo"), repo_files_of(l))
    except e:
        raised = True
        assert_true(String(e).find("no BUCK file") >= 0)
    assert_true(raised)


def test_test_sources() raises:
    assert_true(is_test_source(String("src/komira_retry/tests/test_decide.mojo"), String("src/komira_retry")))
    assert_true(not is_test_source(String("src/komira_retry/policy.mojo"), String("src/komira_retry")))
    assert_true(not is_test_source(String("src/komira_retry/inner/tests/x.mojo"), String("src/komira_retry")))


def _bytes(s: String) -> List[UInt8]:
    """`s` with every `|` a NUL byte."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(UInt8(0) if b[i] == UInt8(124) else b[i])
    return out^


def test_ls_files_z() raises:
    var r = parse_repo_files(_bytes(String("BUCK|src/a b/x.mojo|")), String("files"))
    assert_true(r.has_file(String("src/a b/x.mojo")))
    assert_true(r.has_dir(String("src/a b")))
    assert_true(r.has_buck(String("(root)")))
    var raised = False
    try:
        _ = parse_repo_files(_bytes(String("BUCK\nsrc/x")), String("files"))
    except:
        raised = True
    assert_true(raised)


def main() raises:
    test_strip_prefix()
    test_longest_prefix_wins()
    test_prefix_matches_only_at_a_segment_boundary()
    test_buck_out_rewrite_real_kcov_form()
    test_buck_out_needs_sixteen_hex_digits()
    test_relative_repo_path()
    test_pkgdir_resolves_kcov_test_paths()
    test_pkgdir_missing_file_is_unmapped()
    test_pkgdir_missing_one_segment_file_is_unmapped()
    test_without_pkgdir_a_package_relative_path_is_outside()
    test_repo_directory_but_no_file_is_unmapped()
    test_stdlib_relative_is_outside()
    test_absolute_without_prefix_is_outside()
    test_package_is_nearest_buck()
    test_no_buck_anywhere_is_an_error()
    test_test_sources()
    test_ls_files_z()
    print("test_paths: PASS")
