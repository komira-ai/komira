# =============================================================================
# test_mail_store_escape_recipient: a recipient never becomes a dot segment
#
# `mailboxes/<recipient>/<leaf>.eml`: a recipient of exactly `.` or `..` used to
# pass through and become a `.` or `..` path segment, which only the object
# store's path parser stopped. The mapping must itself give such a recipient a
# segment that is neither, and give no other recipient the same segment.
# Catches: `.` or `..` passing through; the escaped form colliding with another
# address; an empty recipient mapped to the placeholder `unknown` (shared with
# the real address `unknown`) instead of being refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_mail_store import message_key, normalize_recipient


def _refused(addr: String) -> Bool:
    try:
        _ = normalize_recipient(addr)
        return False
    except:
        return True


def _has_dot_segment(key: String) -> Bool:
    """True iff some `/`-separated segment of `key` is `.` or `..`."""
    var bs = key.as_bytes()
    var seg_start = 0
    var i = 0
    while i <= len(bs):
        if i == len(bs) or bs[i] == UInt8(ord("/")):
            var n = i - seg_start
            if n == 1 and bs[seg_start] == UInt8(ord(".")):
                return True
            if (
                n == 2
                and bs[seg_start] == UInt8(ord("."))
                and bs[seg_start + 1] == UInt8(ord("."))
            ):
                return True
            seg_start = i + 1
        i += 1
    return False


def main() raises:
    # The exact dot segments are escaped.
    assert_equal(normalize_recipient("."), String("_2e"), "'.'")
    assert_equal(normalize_recipient(".."), String("_2e."), "'..'")

    # Neither becomes a dot segment in a key.
    assert_false(
        _has_dot_segment(message_key(".", "0123456789abcdef")),
        "recipient '.' must not give a '.' segment",
    )
    assert_false(
        _has_dot_segment(message_key("..", "0123456789abcdef")),
        "recipient '..' must not give a '..' segment",
    )

    # `../bob` carries a `/`, which is escaped, so it was never a dot segment:
    # its segment is the single segment `.._2fbob`, unchanged by the fix.
    assert_equal(
        normalize_recipient("../bob"), String(".._2fbob"), "'../bob'"
    )
    assert_false(
        _has_dot_segment(message_key("../bob", "0123456789abcdef")),
        "recipient '../bob' must not give a dot segment",
    )

    # Dots inside a longer name are untouched.
    assert_equal(normalize_recipient("..."), String("..."), "'...'")
    assert_equal(normalize_recipient("a..b"), String("a..b"), "'a..b'")
    assert_equal(normalize_recipient(".a"), String(".a"), "'.a'")
    assert_equal(normalize_recipient("a."), String("a."), "'a.'")

    # Injective: no other address reaches the escaped segments. The nearest
    # candidates are the spellings of the escape itself.
    assert_true(normalize_recipient("_2e") != normalize_recipient("."), "_2e")
    assert_true(normalize_recipient("_2e.") != normalize_recipient(".."), "_2e.")
    assert_equal(normalize_recipient("_2e"), String("_5f2e"), "'_2e' literal")
    assert_true(normalize_recipient(".") != normalize_recipient(".."), ". vs ..")
    assert_true(normalize_recipient(".") != normalize_recipient("..."), ". vs ...")
    assert_true(normalize_recipient("..") != normalize_recipient("..."), ".. vs ...")

    # The empty recipient is refused, and the real address `unknown` still
    # has its own segment.
    assert_true(_refused(""), "an empty recipient must be refused")
    assert_equal(normalize_recipient("unknown"), String("unknown"), "unknown")
    var refused_key = False
    try:
        _ = message_key("", "0123456789abcdef")
    except:
        refused_key = True
    assert_true(refused_key, "a key for an empty recipient must be refused")

    print("test_mail_store_escape_recipient: ALL PASS")
