# =============================================================================
# tests/test_path_uri.mojo — Path/URI acceptance gate
# =============================================================================
#
# The acceptance tests for `komira_objectstore`'s Path and URI parser.
#
# Coverage:
#   * URI parse — happy paths for s3://, gs://, az://, abfs://, file://
#   * URI parse — fail-fast on unknown scheme / missing ://
#   * URI parse — empty authority on cloud schemes rejected
#   * Path parse — normalization (leading slash, // collapse, trailing slash)
#   * Path parse — `.` / `..` segments rejected
#   * Path joins (child), prefix_matches, filename, is_dir
#   * Path equality
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore import (
    ObjectStoreUri,
    Path,
    Scheme,
    parse,
)


# -----------------------------------------------------------------------------
# URI parsing — happy paths
# -----------------------------------------------------------------------------


def test_uri_s3_full() raises:
    """s3://bucket/a/b/c.parquet -> scheme=s3, auth=bucket, path=a/b/c.parquet."""
    var u = parse(String("s3://bucket/a/b/c.parquet"))
    assert_true(u.scheme.is_s3(), "scheme is s3")
    assert_equal(u.authority, String("bucket"))
    assert_equal(u.path.raw(), String("a/b/c.parquet"))
    assert_false(u.path.is_root())
    assert_false(u.path.is_dir())


def test_uri_s3_bucket_only_no_slash() raises:
    """s3://bucket -> path is root (empty)."""
    var u = parse(String("s3://bucket"))
    assert_true(u.scheme.is_s3())
    assert_equal(u.authority, String("bucket"))
    assert_true(u.path.is_root())


def test_uri_s3_bucket_only_with_trailing_slash() raises:
    """s3://bucket/ -> path is root (empty); trailing slash is consumed."""
    var u = parse(String("s3://bucket/"))
    assert_true(u.scheme.is_s3())
    assert_equal(u.authority, String("bucket"))
    assert_true(u.path.is_root())


def test_uri_s3_directory_prefix_trailing_slash() raises:
    """s3://bucket/dir/ -> path=dir/, is_dir=True (list_with_delimiter)."""
    var u = parse(String("s3://bucket/dir/"))
    assert_equal(u.authority, String("bucket"))
    assert_equal(u.path.raw(), String("dir/"))
    assert_true(u.path.is_dir())


def test_uri_gs() raises:
    """gs://my-bucket/path/to/object."""
    var u = parse(String("gs://my-bucket/path/to/object"))
    assert_true(u.scheme.is_gs())
    assert_equal(u.authority, String("my-bucket"))
    assert_equal(u.path.raw(), String("path/to/object"))


def test_uri_az() raises:
    """az://account/container/blob."""
    var u = parse(String("az://acct/container/blob"))
    assert_true(u.scheme.is_az())
    assert_equal(u.authority, String("acct"))
    assert_equal(u.path.raw(), String("container/blob"))


def test_uri_abfs() raises:
    """abfs://account/container/blob — Azure DataLakeGen2 alias."""
    var u = parse(String("abfs://acct/container/blob"))
    assert_true(u.scheme.is_abfs())
    assert_equal(u.authority, String("acct"))
    assert_equal(u.path.raw(), String("container/blob"))


def test_uri_file_three_slashes() raises:
    """file:///abs/path -> auth="" (empty host)."""
    var u = parse(String("file:///abs/path"))
    assert_true(u.scheme.is_file())
    assert_false(u.scheme.is_remote())
    assert_equal(u.authority, String(""))
    assert_equal(u.path.raw(), String("abs/path"))


def test_uri_file_with_host() raises:
    """file://host/abs/path -> auth=host."""
    var u = parse(String("file://host/abs/path"))
    assert_true(u.scheme.is_file())
    assert_equal(u.authority, String("host"))
    assert_equal(u.path.raw(), String("abs/path"))


def test_uri_scheme_is_remote_flag() raises:
    """is_remote() is True for cloud schemes, False for file://."""
    var u_s3 = parse(String("s3://b/k"))
    assert_true(u_s3.scheme.is_remote())
    var u_gs = parse(String("gs://b/k"))
    assert_true(u_gs.scheme.is_remote())
    var u_az = parse(String("az://b/k"))
    assert_true(u_az.scheme.is_remote())
    var u_abfs = parse(String("abfs://b/k"))
    assert_true(u_abfs.scheme.is_remote())
    var u_file = parse(String("file:///k"))
    assert_false(u_file.scheme.is_remote())


# -----------------------------------------------------------------------------
# URI parsing — fail-fast
# -----------------------------------------------------------------------------


def test_uri_missing_scheme_sep_raises() raises:
    """A string without '://' must raise."""
    var raised = False
    try:
        var _u = parse(String("bucket/key"))
    except e:
        raised = True
    assert_true(raised, "expected raise on missing ://")


def test_uri_unknown_scheme_raises() raises:
    """An unknown scheme (e.g. http) must raise."""
    var raised = False
    try:
        var _u = parse(String("http://example.com/path"))
    except e:
        raised = True
    assert_true(raised, "expected raise on unknown scheme http")


def test_uri_empty_string_raises() raises:
    """An empty URI must raise."""
    var raised = False
    try:
        var _u = parse(String(""))
    except e:
        raised = True
    assert_true(raised, "expected raise on empty URI")


def test_uri_cloud_empty_authority_raises() raises:
    """s3:///key — empty bucket — must raise."""
    var raised = False
    try:
        var _u = parse(String("s3:///key"))
    except e:
        raised = True
    assert_true(raised, "expected raise on empty cloud authority")


def test_uri_path_with_dotdot_raises() raises:
    """The path normalizer rejects '..' segments — propagates to URI parse."""
    var raised = False
    try:
        var _u = parse(String("s3://bucket/a/../b"))
    except e:
        raised = True
    assert_true(raised, "expected raise on '..' segment")


def test_uri_path_with_single_dot_raises() raises:
    """The path normalizer rejects '.' segments — propagates to URI parse."""
    var raised = False
    try:
        var _u = parse(String("s3://bucket/./b"))
    except e:
        raised = True
    assert_true(raised, "expected raise on '.' segment")


# -----------------------------------------------------------------------------
# Path normalization
# -----------------------------------------------------------------------------


def test_path_parse_strips_leading_slash() raises:
    var p = Path.parse(String("/a/b/c"))
    assert_equal(p.raw(), String("a/b/c"))


def test_path_parse_strips_multiple_leading_slashes() raises:
    var p = Path.parse(String("///a/b"))
    assert_equal(p.raw(), String("a/b"))


def test_path_parse_collapses_double_slash() raises:
    var p = Path.parse(String("a//b///c"))
    assert_equal(p.raw(), String("a/b/c"))


def test_path_parse_preserves_trailing_slash() raises:
    var p = Path.parse(String("a/b/"))
    assert_equal(p.raw(), String("a/b/"))
    assert_true(p.is_dir())


def test_path_parse_empty_is_root() raises:
    var p = Path.parse(String(""))
    assert_true(p.is_root())
    assert_true(p.is_dir())


def test_path_parse_all_slashes_is_root() raises:
    var p = Path.parse(String("///"))
    assert_true(p.is_root())


def test_path_parse_rejects_dot() raises:
    var raised = False
    try:
        var _p = Path.parse(String("a/./b"))
    except e:
        raised = True
    assert_true(raised, "expected raise on '.' segment")


def test_path_parse_rejects_dotdot() raises:
    var raised = False
    try:
        var _p = Path.parse(String("a/../b"))
    except e:
        raised = True
    assert_true(raised, "expected raise on '..' segment")


def test_path_parse_rejects_leading_dotdot() raises:
    var raised = False
    try:
        var _p = Path.parse(String("../a"))
    except e:
        raised = True
    assert_true(raised, "expected raise on leading '..'")


# -----------------------------------------------------------------------------
# Path operations
# -----------------------------------------------------------------------------


def test_path_child_from_root() raises:
    var root = Path.parse(String(""))
    var c = root.child(String("a"))
    assert_equal(c.raw(), String("a"))


def test_path_child_appends_segment() raises:
    var p = Path.parse(String("a/b"))
    var c = p.child(String("c"))
    assert_equal(c.raw(), String("a/b/c"))


def test_path_child_appends_to_dir() raises:
    var p = Path.parse(String("a/b/"))
    var c = p.child(String("c"))
    # is_dir + child gives a non-dir leaf at "a/b/c" (single slash, no double)
    assert_equal(c.raw(), String("a/b/c"))


def test_path_child_rejects_slash_segment() raises:
    var p = Path.parse(String("a"))
    var raised = False
    try:
        var _c = p.child(String("b/c"))
    except e:
        raised = True
    assert_true(raised, "expected raise on segment with '/'")


def test_path_child_rejects_empty_segment() raises:
    var p = Path.parse(String("a"))
    var raised = False
    try:
        var _c = p.child(String(""))
    except e:
        raised = True
    assert_true(raised, "expected raise on empty segment")


def test_path_child_rejects_dot() raises:
    var p = Path.parse(String("a"))
    var raised = False
    try:
        var _c = p.child(String("."))
    except e:
        raised = True
    assert_true(raised, "expected raise on '.'")


def test_path_prefix_matches_root_matches_all() raises:
    var root = Path.parse(String(""))
    var p = Path.parse(String("a/b/c"))
    assert_true(p.prefix_matches(root))


def test_path_prefix_matches_segment_boundary() raises:
    var prefix = Path.parse(String("foo"))
    var matches = Path.parse(String("foo/bar"))
    var doesnt = Path.parse(String("foobar"))
    assert_true(matches.prefix_matches(prefix))
    assert_false(doesnt.prefix_matches(prefix))


def test_path_prefix_matches_self() raises:
    var p = Path.parse(String("a/b/c"))
    assert_true(p.prefix_matches(p))


def test_path_prefix_matches_dir_prefix() raises:
    """Directory prefix `foo/` matches paths under it."""
    var dir_prefix = Path.parse(String("foo/"))
    var under = Path.parse(String("foo/bar"))
    assert_true(under.prefix_matches(dir_prefix))


def test_path_filename_leaf() raises:
    var p = Path.parse(String("a/b/c.parquet"))
    assert_equal(p.filename(), String("c.parquet"))


def test_path_filename_root_is_empty() raises:
    var root = Path.parse(String(""))
    assert_equal(root.filename(), String(""))


def test_path_filename_directory_is_empty() raises:
    var d = Path.parse(String("a/b/"))
    assert_equal(d.filename(), String(""))


def test_path_equality() raises:
    var a = Path.parse(String("a/b/c"))
    var b = Path.parse(String("//a//b/c"))
    assert_true(a == b)
    var d = Path.parse(String("a/b"))
    assert_true(a != d)


def test_path_is_dir_root_true() raises:
    var root = Path.parse(String(""))
    assert_true(root.is_dir())


def test_path_is_dir_trailing_slash_true() raises:
    var d = Path.parse(String("a/"))
    assert_true(d.is_dir())


def test_path_is_dir_no_trailing_slash_false() raises:
    var p = Path.parse(String("a/b"))
    assert_false(p.is_dir())


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    # URI happy paths
    test_uri_s3_full()
    test_uri_s3_bucket_only_no_slash()
    test_uri_s3_bucket_only_with_trailing_slash()
    test_uri_s3_directory_prefix_trailing_slash()
    test_uri_gs()
    test_uri_az()
    test_uri_abfs()
    test_uri_file_three_slashes()
    test_uri_file_with_host()
    test_uri_scheme_is_remote_flag()
    # URI fail-fast
    test_uri_missing_scheme_sep_raises()
    test_uri_unknown_scheme_raises()
    test_uri_empty_string_raises()
    test_uri_cloud_empty_authority_raises()
    test_uri_path_with_dotdot_raises()
    test_uri_path_with_single_dot_raises()
    # Path normalization
    test_path_parse_strips_leading_slash()
    test_path_parse_strips_multiple_leading_slashes()
    test_path_parse_collapses_double_slash()
    test_path_parse_preserves_trailing_slash()
    test_path_parse_empty_is_root()
    test_path_parse_all_slashes_is_root()
    test_path_parse_rejects_dot()
    test_path_parse_rejects_dotdot()
    test_path_parse_rejects_leading_dotdot()
    # Path ops
    test_path_child_from_root()
    test_path_child_appends_segment()
    test_path_child_appends_to_dir()
    test_path_child_rejects_slash_segment()
    test_path_child_rejects_empty_segment()
    test_path_child_rejects_dot()
    test_path_prefix_matches_root_matches_all()
    test_path_prefix_matches_segment_boundary()
    test_path_prefix_matches_self()
    test_path_prefix_matches_dir_prefix()
    test_path_filename_leaf()
    test_path_filename_root_is_empty()
    test_path_filename_directory_is_empty()
    test_path_equality()
    test_path_is_dir_root_true()
    test_path_is_dir_trailing_slash_true()
    test_path_is_dir_no_trailing_slash_false()
    print("OK")
