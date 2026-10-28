# =============================================================================
# test_mail_store_length_bounds: a name that would not fit a key is refused
#
# A store that keeps one object per file (the local file system store) writes
# the whole key, `/` as `%2F`, as ONE file name, and Linux caps a file name at
# 255 bytes. Escaping can triple a recipient, so a legal 254-byte address would
# be accepted here and fail later inside the store. The mappings refuse a name
# that cannot fit, at the call that names it:
#   * a normalized recipient is at most MAX_RECIPIENT_BYTES (128) bytes;
#   * a normalized folder weighs at most MAX_FOLDER_WEIGHT (80), where each
#     byte weighs 1 and each `/` or `%` weighs 3 (their file-name spelling).
# Catches: a limit removed or moved by one; a longest key whose file name
# passes 255 bytes; an oversize name written before it is refused.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore import SharedInMemoryConditionalStore

from komira_mail_store import (
    MAX_FOLDER_WEIGHT,
    MAX_RECIPIENT_BYTES,
    folder_message_key,
    list_folder,
    normalize_folder,
    normalize_recipient,
    store_message,
)

comptime LEAF = "0123456789abcdef"


def _rep(unit: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += unit
    return out^


def _recipient_refused(addr: String) -> Bool:
    try:
        _ = normalize_recipient(addr)
        return False
    except:
        return True


def _folder_refused(name: String) -> Bool:
    try:
        _ = normalize_folder(name)
        return False
    except:
        return True


def _file_name_len(key: String) -> Int:
    """Length of `key` as one file name: `/` and `%` are 3 bytes (`%2F`,
    `%25`), every other byte of these keys (`[a-z0-9._-]`) is 1."""
    var bs = key.as_bytes()
    var n = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("/")) or bs[i] == UInt8(ord("%")):
            n += 3
        else:
            n += 1
    return n


def main() raises:
    assert_equal(MAX_RECIPIENT_BYTES, 128, "the documented recipient limit")
    assert_equal(MAX_FOLDER_WEIGHT, 80, "the documented folder limit")

    # Recipient: 128 normalized bytes pass, 129 are refused.
    assert_equal(
        normalize_recipient(_rep("a", 128)).byte_length(), 128, "128 letters"
    )
    assert_true(_recipient_refused(_rep("a", 129)), "129 letters")
    # Escapes count at their normalized size: 42 `@` (3 bytes each) + 2 letters.
    assert_equal(
        normalize_recipient(_rep("@", 42) + "ab").byte_length(), 128, "42 @"
    )
    assert_true(_recipient_refused(_rep("@", 43)), "43 @ is 129 bytes")
    # A legal 254-byte address of letters is refused up front.
    assert_true(_recipient_refused(_rep("a", 254)), "254 letters")
    assert_true(
        _recipient_refused(_rep("a", 64) + "@" + _rep("b", 63) + ".example"),
        "a long but legal address",
    )

    # Folder: weight 80 passes, 81 is refused.
    assert_equal(normalize_folder(_rep("a", 80)), _rep("a", 80), "80 letters")
    assert_true(_folder_refused(_rep("a", 81)), "81 letters")
    # `a` and 19 times `/a`: 1 + 19 * 4 = 77; 20 times: 81.
    assert_equal(
        normalize_folder("a" + _rep("/a", 19)), "a" + _rep("/a", 19), "77"
    )
    assert_true(_folder_refused("a" + _rep("/a", 20)), "81 with slashes")
    # An escape weighs its output: `%2e` is 3 + 2 bytes, after a `/` of 3.
    assert_equal(
        normalize_folder(_rep("a", 72) + "/.").byte_length(),
        72 + 1 + 3,
        "an escaped segment, weight 80",
    )
    assert_true(_folder_refused(_rep("a", 73) + "/."), "weight 81")
    # INBOX is the flat layout whatever its spelling: no limit applies.
    assert_equal(normalize_folder(" inbox "), String("INBOX"), "INBOX")

    # The longest keys the limits allow are one file name of at most 255 bytes
    # (`mailboxes/` + recipient + `/` + folder + `/` + 16 + `.eml`, each `/`
    # three bytes): 12 + 128 + 3 + 80 + 3 + 20 = 246 at the limits.
    var heaviest = "aaaa" + _rep("/a", 19)  # weight 4 + 19 * 4 = 80
    var key = folder_message_key(_rep("a", 128), heaviest, LEAF)
    assert_equal(_file_name_len(key), 246, "heavy folder file name")
    var flat = folder_message_key(_rep("a", 128), _rep("a", 80), LEAF)
    assert_equal(_file_name_len(flat), 246, "long folder file name")
    assert_true(_file_name_len(key) <= 255, "fits NAME_MAX")

    # Refused names are refused by store_message and list_folder, and nothing
    # is written for them.
    var s = SharedInMemoryConditionalStore()
    var refused = False
    try:
        _ = store_message(s, _rep("a", 129), "INBOX", List[UInt8]())
    except:
        refused = True
    assert_true(refused, "an oversize recipient is not stored")
    refused = False
    try:
        _ = store_message(s, "a@x", _rep("b", 81), List[UInt8]())
    except:
        refused = True
    assert_true(refused, "an oversize folder is not stored")
    refused = False
    try:
        _ = list_folder(s, "a@x", _rep("b", 81))
    except:
        refused = True
    assert_true(refused, "an oversize folder is not listed")
    assert_equal(len(list_folder(s, "a@x", "INBOX")), 0, "nothing was written")

    print("test_mail_store_length_bounds: ALL PASS")
