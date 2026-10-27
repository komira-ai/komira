# =============================================================================
# test_mail_store_key_stability: stored keys never move
#
# Every (recipient, folder) below is an input the mapping was used with before
# this package existed. The expected key is what that mapping produced for it,
# worked out from its source by hand, byte for byte, and confirmed by a build
# that kept the original fold bodies and only lacked the dot-segment escapes
# and the empty-name refusals: this file stayed green there while the escape
# tests failed. A change to the fold of
# an ordinary name (a new escape for a character that used to pass, a changed
# case rule, a different treatment of a non-ASCII byte) moves a stored message
# out of reach and fails here. The content hash is pinned with the published
# FNV-1a-64 test vectors.
# =============================================================================

from std.testing import assert_equal

from komira_mail_store import (
    content_hash_hex,
    folder_message_key,
    message_key,
    normalize_folder,
    normalize_recipient,
)

comptime L = "af63dc4c8601ec8c"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _inbox(recipient: String, segment: String) raises:
    assert_equal(
        message_key(recipient, L),
        String("mailboxes/") + segment + String("/") + String(L) + ".eml",
        String("inbox key of ") + recipient,
    )
    assert_equal(
        folder_message_key(recipient, "INBOX", L),
        message_key(recipient, L),
        String("INBOX is the flat layout for ") + recipient,
    )


def _folder(folder: String, segment: String) raises:
    assert_equal(
        folder_message_key("a@b", folder, L),
        String("mailboxes/a_40b/") + segment + String("/") + String(L) + ".eml",
        String("folder key of ") + folder,
    )


def main() raises:
    # The content hash: FNV-1a-64 of "", "a" and "foobar".
    assert_equal(content_hash_hex(_bytes("")), String("cbf29ce484222325"))
    assert_equal(content_hash_hex(_bytes("a")), String(L))
    assert_equal(content_hash_hex(_bytes("foobar")), String("85944171f73967e8"))

    # Recipients: `[a-z0-9.-]` pass, A-Z fold, every other byte is `_hh`.
    _inbox("alice@example.com", "alice_40example.com")
    _inbox("Alice@Example.COM", "alice_40example.com")
    _inbox("a+b@example.com", "a_2bb_40example.com")
    _inbox("a_b@example.com", "a_5fb_40example.com")
    _inbox("first.last-name@mail.example.org", "first.last-name_40mail.example.org")
    _inbox("x y@z", "x_20y_40z")
    _inbox("a/b@x", "a_2fb_40x")
    _inbox("../../etc/passwd@x", ".._2f.._2fetc_2fpasswd_40x")
    _inbox("../bob", ".._2fbob")
    _inbox("unknown", "unknown")
    _inbox("@@@   ", "_40_40_40_20_20_20")
    _inbox("...", "...")
    _inbox("a..b", "a..b")
    # Non-ASCII bytes are escaped one by one, from the UTF-8 encoding.
    _inbox(String("Jos") + chr(0xE9) + "@example.com", "jos_c3_a9_40example.com")
    _inbox(
        String(chr(0x7528)) + chr(0x6237) + "@" + chr(0x4F8B) + ".cn",
        "_e7_94_a8_e6_88_b7_40_e4_be_8b.cn",
    )

    # Folders: INBOX in any case and with blanks is the flat layout.
    assert_equal(normalize_folder("INBOX"), String("INBOX"))
    assert_equal(normalize_folder("inbox"), String("INBOX"))
    assert_equal(normalize_folder(" Inbox "), String("INBOX"))
    assert_equal(
        folder_message_key("a@b", " Inbox ", L),
        String("mailboxes/a_40b/") + String(L) + ".eml",
    )

    # Named folders: A-Z fold, `[a-z0-9._-/]` pass, any other byte is `_`.
    _folder("Archive", "archive")
    _folder(" Archive ", "archive")
    _folder("Sent", "sent")
    _folder("Archive/2026", "archive/2026")
    _folder("INBOX/Sub", "inbox/sub")
    _folder("Sent Items", "sent_items")
    _folder("Drafts.old", "drafts.old")
    _folder("work_stuff", "work_stuff")
    _folder("A+B", "a_b")
    # A non-ASCII byte becomes two `_`: R, e-acute (2 bytes), union.
    _folder("Caf" + String(chr(0xE9)), "caf____")
    _folder(
        String("Projects/2026-Q1/R") + chr(0xE9) + "union",
        "projects/2026-q1/r____union",
    )

    # Every byte of a 3-byte character is two `_` too (U+65E5 is 3 bytes).
    _folder(String(chr(0x65E5)), "______")
    _folder(String("a") + chr(0x65E5) + "b", "a______b")

    # The two recipient segments the fix does not touch but that look close.
    assert_equal(normalize_recipient("..."), String("..."))
    assert_equal(normalize_recipient("a.b"), String("a.b"))

    print("test_mail_store_key_stability: ALL PASS")
