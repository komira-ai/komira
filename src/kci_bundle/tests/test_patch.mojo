# =============================================================================
# kci_bundle/tests/test_patch.mojo
#   — the comment-preserving patcher (set-field + append-block).
# =============================================================================
#
# The minimal-diff patcher is load-bearing: the `#` prose is the whole
# reason the format is textproto, so an edit MUST splice bytes in place and never
# re-serialize. These tests prove the two ops (set-field, append-block) change
# ONLY the target bytes — comments, ordering, indentation, and untouched fields
# survive verbatim — AND that the patched text still parses to the intended
# bundle (a re-parse is the strongest correctness check).
#
# Encapsulation: pure string patch + re-parse asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_bundle.patch import patch_set_field, patch_append_block
from kci_bundle.parser import parse_bundle


comptime _BASE: String = (
    "# orders bundle — do not delete this comment\n"
    "kind: APP_KIND_API\n"
    'name: "orders"\n'
    "spec {\n"
    '  image { digest: "sha256:old" }   # the pinned image\n'
    "  port: 8080\n"
    "}\n"
    "waves {\n"
    '  env: "dev"\n'
    "}\n"
)


def _path(a: String) -> List[String]:
    var p = List[String]()
    p.append(a)
    return p^


def _path2(a: String, b: String) -> List[String]:
    var p = List[String]()
    p.append(a)
    p.append(b)
    return p^


def _path3(a: String, b: String, c: String) -> List[String]:
    var p = List[String]()
    p.append(a)
    p.append(b)
    p.append(c)
    return p^


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def test_set_top_level_string_preserves_comments() raises:
    """Set-field on `name` replaces only the value; both comments survive."""
    var out = patch_set_field(_BASE, _path(String("name")), String("orders-v2"), True)
    assert_true(_contains(out, String('name: "orders-v2"')), "name updated")
    assert_true(
        _contains(out, String("# orders bundle — do not delete this comment")),
        "header comment preserved",
    )
    assert_true(
        _contains(out, String("# the pinned image")), "inline comment preserved"
    )
    # the re-parse reflects the change
    var b = parse_bundle(out)
    assert_equal(b.name, String("orders-v2"), "re-parsed name")
    print("  test_set_top_level_string_preserves_comments: PASS")


def test_set_nested_string_the_common_case() raises:
    """The 'use this new image digest' one-field edit: set spec.image.digest."""
    var out = patch_set_field(
        _BASE,
        _path3(String("spec"), String("image"), String("digest")),
        String("sha256:NEW"),
        True,
    )
    assert_true(_contains(out, String('digest: "sha256:NEW"')), "digest updated")
    assert_true(_contains(out, String("port: 8080")), "sibling port untouched")
    assert_true(_contains(out, String("# the pinned image")), "comment preserved")
    var b = parse_bundle(out)
    assert_equal(
        b.spec.value().image.value().digest.value(),
        String("sha256:NEW"),
        "re-parsed digest",
    )
    print("  test_set_nested_string_the_common_case: PASS")


def test_set_number_raw_no_quotes() raises:
    """A numeric scalar is spliced RAW (quote=False)."""
    var out = patch_set_field(
        _BASE, _path2(String("spec"), String("port")), String("9090"), False
    )
    assert_true(_contains(out, String("port: 9090")), "port updated raw")
    assert_true(not _contains(out, String('port: "9090"')), "port not quoted")
    var b = parse_bundle(out)
    assert_equal(b.spec.value().port, Int32(9090), "re-parsed port")
    print("  test_set_number_raw_no_quotes: PASS")


def test_append_top_level_block_at_eof() raises:
    """Append-block with an empty parent appends a top-level `waves` at EOF; the
    existing dev wave + all comments are preserved, order is [dev, prod]."""
    var block = String('waves {\n  env: "prod"\n}\n')
    var out = patch_append_block(_BASE, List[String](), block)
    assert_true(_contains(out, String("# orders bundle")), "header preserved")
    assert_true(_contains(out, String('env: "dev"')), "dev wave preserved")
    var b = parse_bundle(out)
    assert_equal(len(b.waves), 2, "two waves after append")
    assert_equal(b.waves[0].env, String("dev"), "order: dev first")
    assert_equal(b.waves[1].env, String("prod"), "order: prod appended")
    print("  test_append_top_level_block_at_eof: PASS")


def test_append_block_under_parent() raises:
    """Append-block under `spec` inserts an `env` block before spec's closing `}`,
    indented one level; port + image survive."""
    var block = String('env {\n  name: "LOG"\n  value: "info"\n}\n')
    var out = patch_append_block(_BASE, _path(String("spec")), block)
    var b = parse_bundle(out)
    assert_equal(len(b.spec.value().env), 1, "one env appended under spec")
    assert_equal(b.spec.value().env[0].name, String("LOG"), "env name")
    assert_equal(b.spec.value().env[0].value.value(), String("info"), "env value")
    assert_equal(b.spec.value().port, Int32(8080), "port survived")
    assert_true(_contains(out, String("# the pinned image")), "comment survived")
    print("  test_append_block_under_parent: PASS")


def test_set_field_unknown_path_raises() raises:
    """A set-field on a non-existent path is a clear, self-correctable error."""
    var raised = False
    var msg = String("")
    try:
        _ = patch_set_field(_BASE, _path(String("nonesuch")), String("x"), True)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "unknown path raises")
    assert_true(
        _contains(msg, String("field path 'nonesuch' not found")), "clear error"
    )
    print("  test_set_field_unknown_path_raises: PASS")


def main() raises:
    test_set_top_level_string_preserves_comments()
    test_set_nested_string_the_common_case()
    test_set_number_raw_no_quotes()
    test_append_top_level_block_at_eof()
    test_append_block_under_parent()
    test_set_field_unknown_path_raises()
    print("PASS test_patch")
