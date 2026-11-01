# =============================================================================
# test_mail_store_escape_folder: a folder never climbs out or aliases another
#
# A folder keeps `/` (a hierarchy such as `Archive/2026`), so `../bob` used to
# become a `..` segment: `mailboxes/<recipient>/../bob/<leaf>.eml`, which the
# object store's path parser refused only by raising. And `a//b`, `/a` and `a/`
# used to key like `a/b`, `a` and `a` because that parser collapses empty
# segments. The mapping must give every such folder a key of its own.
# Catches: `.`, `..`, `../bob` and `a/../b` reaching the key unescaped; an empty
# segment collapsing into another folder; an empty or blank folder mapped to
# INBOX's name instead of being refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore.path import Path

from komira_mail_store import folder_message_key, normalize_folder

comptime LEAF = "0123456789abcdef"


def _refused(folder: String) -> Bool:
    try:
        _ = normalize_folder(folder)
        return False
    except:
        return True


def _key_parses_with_expected_depth(
    folder: String, folder_segments: Int
) raises -> Bool:
    """The key for `folder` survives the object store's parser unchanged, and
    has `folder_segments` folder segments between `mailboxes/<recipient>/` and the
    leaf."""
    var key = folder_message_key("r@x", folder, LEAF)
    var parsed = Path.parse(key).raw()
    if parsed != key:
        return False
    var slashes = 0
    var bs = key.as_bytes()
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("/")):
            slashes += 1
    return slashes == folder_segments + 2


def main() raises:
    # The exact dot segments, alone and inside a hierarchy.
    assert_equal(normalize_folder("."), String("%2e"), "'.'")
    assert_equal(normalize_folder(".."), String("%2e."), "'..'")
    assert_equal(normalize_folder("../bob"), String("%2e./bob"), "'../bob'")
    assert_equal(normalize_folder("a/../b"), String("a/%2e./b"), "'a/../b'")
    assert_equal(normalize_folder("a/./b"), String("a/%2e/b"), "'a/./b'")
    assert_equal(normalize_folder("a/.."), String("a/%2e."), "'a/..'")

    # Each of them gives a key the parser accepts unchanged, with the
    # segments the folder named (not fewer: no climb, no collapse).
    assert_true(_key_parses_with_expected_depth(".", 1), "'.'")
    assert_true(_key_parses_with_expected_depth("..", 1), "'..'")
    assert_true(_key_parses_with_expected_depth("../bob", 2), "'../bob'")
    assert_true(_key_parses_with_expected_depth("a/../b", 3), "'a/../b'")

    # The escapes rest on the parser keeping `%` as written: it must hand back
    # `%2e.` and `%` untouched, not decode them to `..` and a byte.
    assert_equal(Path.parse("a/%2e./b").raw(), String("a/%2e./b"), "%2e. kept")
    assert_equal(Path.parse("a/%/b").raw(), String("a/%/b"), "% kept")

    # Empty segments do not collapse into another folder.
    assert_equal(normalize_folder("a//b"), String("a/%/b"), "'a//b'")
    assert_equal(normalize_folder("/a"), String("%/a"), "'/a'")
    assert_equal(normalize_folder("a/"), String("a/%"), "'a/'")
    assert_equal(normalize_folder("/"), String("%/%"), "'/'")
    assert_true(
        normalize_folder("a//b") != normalize_folder("a/b"), "a//b vs a/b"
    )
    assert_true(normalize_folder("/a") != normalize_folder("a"), "/a vs a")
    assert_true(normalize_folder("a/") != normalize_folder("a"), "a/ vs a")
    assert_true(_key_parses_with_expected_depth("a//b", 3), "'a//b'")

    # Distinct from the folders whose names spell the escapes: `%` is never
    # emitted by the fold, so a name holding `%` becomes `_`.
    assert_equal(normalize_folder("%2e"), String("_2e"), "'%2e' literal")
    assert_true(normalize_folder("%2e") != normalize_folder("."), "%2e vs .")
    assert_true(normalize_folder("%") != normalize_folder("/"), "% vs /")
    assert_true(normalize_folder(".") != normalize_folder(".."), ". vs ..")
    assert_true(normalize_folder("...") != normalize_folder(".."), "... vs ..")
    assert_equal(normalize_folder("..."), String("..."), "'...'")

    # An empty or blank folder is refused; it is not INBOX.
    assert_true(_refused(""), "an empty folder must be refused")
    assert_true(_refused("   "), "a blank folder must be refused")
    assert_true(_refused("\t\r\n"), "a whitespace folder must be refused")
    var refused_key = False
    try:
        _ = folder_message_key("r@x", "", LEAF)
    except:
        refused_key = True
    assert_true(refused_key, "a key for an empty folder must be refused")

    print("test_mail_store_escape_folder: ALL PASS")
