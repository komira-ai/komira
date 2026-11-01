# =============================================================================
# test_mail_store_normalize: the recipient mapping is injective
#
# Two addresses that differ in any byte other than the case of an ASCII letter
# must give different mailbox segments. A mapping that sends every unsafe byte
# to one placeholder sends `a+b@example.com` and `a_b@example.com` to one mailbox and
# delivers one person's mail to another. This file catches that: the collision
# pairs, the intended case fold, no `/` in a segment, a stable result, and a
# battery of distinct addresses with distinct keys.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_mail_store import message_key, normalize_recipient


def _contains_slash(s: String) -> Bool:
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        if Int(bs[i]) == ord("/"):
            return True
        i += 1
    return False


def main() raises:
    # Plus-addressing against a literal underscore.
    assert_true(
        normalize_recipient("a+b@example.com") != normalize_recipient("a_b@example.com"),
        "a+b@example.com and a_b@example.com must map to different mailbox keys",
    )
    assert_true(
        normalize_recipient("a@example.com") != normalize_recipient("a_example.com"),
        "a@example.com and a_example.com must map to different mailbox keys",
    )
    assert_true(
        normalize_recipient("x y@z") != normalize_recipient("x_y@z"),
        "x y@z and x_y@z must map to different mailbox keys",
    )

    # The intended case fold.
    assert_equal(
        normalize_recipient("Alice@example.com"),
        normalize_recipient("alice@example.com"),
        "Alice@ and alice@ are one mailbox",
    )
    assert_equal(
        normalize_recipient("bob@EXAMPLE.COM"),
        normalize_recipient("bob@example.com"),
        "the domain is lowercased like the local part",
    )

    # No `/` in a segment, and so exactly two `/` in a key.
    assert_false(
        _contains_slash(normalize_recipient("a/b@x")),
        "a `/` in the address must not appear in the segment",
    )
    var key = message_key("a/b@x", "deadbeefdeadbeef")
    var slashes = 0
    var kb = key.as_bytes()
    var i = 0
    while i < len(kb):
        if Int(kb[i]) == ord("/"):
            slashes += 1
        i += 1
    assert_equal(
        slashes,
        2,
        "mailboxes/<one segment>/<leaf>.eml has exactly two `/`",
    )
    assert_false(
        _contains_slash(normalize_recipient("../../etc/passwd@x")),
        "a traversal address must not emit a `/`",
    )

    # Stable.
    assert_equal(
        normalize_recipient("a+b@example.com"),
        normalize_recipient("a+b@example.com"),
        "same input, same output",
    )

    # An address made only of unsafe bytes is still a non-empty, slash-free
    # segment.
    var allsym = normalize_recipient("@@@   ")
    assert_true(len(allsym.as_bytes()) > 0, "all-unsafe input is non-empty")
    assert_false(_contains_slash(allsym), "all-unsafe input has no `/`")

    # A battery of distinct addresses with distinct segments.
    var k1 = normalize_recipient("a.b@example.com")
    var k2 = normalize_recipient("a-b@example.com")
    var k3 = normalize_recipient("a_b@example.com")
    var k4 = normalize_recipient("a b@example.com")
    var k5 = normalize_recipient("a+b@example.com")
    assert_true(k1 != k2, "a.b vs a-b distinct")
    assert_true(k1 != k3, "a.b vs a_b distinct")
    assert_true(k2 != k3, "a-b vs a_b distinct")
    assert_true(k3 != k4, "a_b vs 'a b' distinct")
    assert_true(k3 != k5, "a_b vs a+b distinct")
    assert_true(k4 != k5, "'a b' vs a+b distinct")

    print("test_mail_store_normalize: ALL PASS")
