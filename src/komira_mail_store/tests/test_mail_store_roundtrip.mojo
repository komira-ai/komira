# =============================================================================
# test_mail_store_roundtrip: store, fetch, exists and list on real stores
#
# The same scenarios run on two in-process stores: SharedInMemoryConditionalStore
# (lists every key under a prefix) and DelimiterFaithfulConditionalStore (lists
# like an object store: a sub-folder's keys come back only as a common prefix).
# Catches: stored bytes changed on the way in or out; a duplicate store
# reported as created or stored twice; a missing message not reported as
# missing; listings that miss a message, show another folder's, or come back
# in the store's order instead of leaf order; a folder list that finds no
# sub-folder on an object-store listing; non-ASCII and dot-segment names that
# alias one another; a hash collision silently dropping a message; a leaf
# that names another folder's object; a refused name that is accepted.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_mail_store import (
    content_hash_hex,
    fetch_message,
    list_folder,
    list_folders,
    message_exists,
    store_message,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _lt(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return len(ab) < len(bb)


def _refused_store[
    S: ConditionalWriteStore
](mut s: S, recipient: String, folder: String) -> Bool:
    try:
        _ = store_message(s, recipient, folder, _bytes("x"))
        return False
    except:
        return True


def _scenario[S: ConditionalWriteStore](mut s: S) raises:
    # ---- store then fetch: the bytes come back exactly --------------------
    var binary = List[UInt8]()
    for i in range(256):
        binary.append(UInt8(i))
    var first = store_message(s, "alice@example.com", "INBOX", binary)
    assert_true(first.created, "first store creates")
    assert_equal(first.leaf, content_hash_hex(binary), "leaf is the hash")
    assert_equal(
        first.key,
        String("mailboxes/alice_40example.com/") + first.leaf + ".eml",
        "INBOX key is flat",
    )
    var got = fetch_message(s, "alice@example.com", "INBOX", first.leaf)
    assert_true(got.found, "stored message is found")
    assert_true(got.bytes == binary, "bytes come back verbatim")
    assert_true(
        message_exists(s, "alice@example.com", "INBOX", first.leaf), "exists"
    )
    # The recipient's case and the folder's case and blanks do not matter.
    assert_true(
        fetch_message(s, "ALICE@Example.com", " inbox ", first.leaf).found,
        "case-folded recipient and INBOX spelling reach the same message",
    )

    # ---- a duplicate store: same key, not created, one object ----------------
    var again = store_message(s, "alice@example.com", "INBOX", binary)
    assert_false(again.created, "second store is a duplicate")
    assert_equal(again.key, first.key, "same key")
    assert_equal(
        len(list_folder(s, "alice@example.com", "INBOX")), 1, "still one"
    )
    # The same bytes in another folder or for another recipient are separate.
    var other_folder = store_message(s, "alice@example.com", "Sent", binary)
    assert_true(other_folder.created, "another folder is a new message")
    var other_rcpt = store_message(s, "bob@example.com", "INBOX", binary)
    assert_true(other_rcpt.created, "another recipient is a new message")

    # ---- a missing message ---------------------------------------------------
    var missing = fetch_message(s, "alice@example.com", "INBOX", "0000000000000000")
    assert_false(missing.found, "an absent leaf is not found")
    assert_equal(len(missing.bytes), 0, "and has no bytes")
    assert_false(
        message_exists(s, "alice@example.com", "INBOX", "0000000000000000"),
        "an absent leaf does not exist",
    )
    assert_false(
        fetch_message(s, "carol@example.com", "INBOX", first.leaf).found,
        "another recipient does not see it",
    )
    assert_false(
        fetch_message(s, "alice@example.com", "Archive", first.leaf).found,
        "another folder does not hold it",
    )

    # ---- a leaf is one file name --------------------------------------------
    var bad_leaf = False
    try:
        _ = fetch_message(s, "alice@example.com", "INBOX", "sent/" + first.leaf)
    except:
        bad_leaf = True
    assert_true(bad_leaf, "a leaf with a slash is refused")
    bad_leaf = False
    try:
        _ = message_exists(s, "alice@example.com", "INBOX", "")
    except:
        bad_leaf = True
    assert_true(bad_leaf, "an empty leaf is refused")

    # ---- list after several stores: complete and in leaf order -----------------
    var stored = List[String]()
    var sizes = List[Int]()
    for n in range(40):
        var body = _bytes("Subject: m" + String(n) + "\r\n\r\nbody " + String(n * 7))
        var o = store_message(s, "dana@example.com", "INBOX", body)
        assert_true(o.created, "distinct bodies are distinct messages")
        stored.append(o.leaf)
        sizes.append(len(body))
    var descents = 0
    for i in range(1, len(stored)):
        if _lt(stored[i], stored[i - 1]):
            descents += 1
    assert_true(descents > 0, "the insertion order is not already sorted")
    var listed = list_folder(s, "dana@example.com", "INBOX")
    assert_equal(len(listed), 40, "all forty are listed")
    for i in range(1, len(listed)):
        assert_true(
            _lt(listed[i - 1].leaf, listed[i].leaf),
            "entries are in strictly ascending leaf order",
        )
    for i in range(len(stored)):
        var found_at = -1
        for j in range(len(listed)):
            if listed[j].leaf == stored[i]:
                found_at = j
        assert_true(found_at >= 0, "stored message is listed")
        assert_equal(listed[found_at].size, sizes[i], "listed size")
    # Short lists sort too (the merge starts from runs of one).
    for count in range(0, 6):
        var rcpt = "short" + String(count) + "@x"
        for n in range(count):
            _ = store_message(s, rcpt, "INBOX", _bytes("s" + String(n * 31 + count)))
        var l = list_folder(s, rcpt, "INBOX")
        assert_equal(len(l), count, "short list length")
        for i in range(1, len(l)):
            assert_true(_lt(l[i - 1].leaf, l[i].leaf), "short list order")
    assert_equal(len(list_folder(s, "nobody@example.com", "INBOX")), 0, "empty")

    # ---- folders -------------------------------------------------------------
    var m_inbox = store_message(s, "erin@example.com", "INBOX", _bytes("in"))
    var m_arch = store_message(s, "erin@example.com", "Archive", _bytes("arch"))
    var m_arch26 = store_message(s, "erin@example.com", "Archive/2026", _bytes("a26"))
    var m_sent = store_message(s, "erin@example.com", "Sent", _bytes("sent"))
    assert_equal(
        m_arch.key,
        String("mailboxes/erin_40example.com/archive/") + m_arch.leaf + ".eml",
        "a named folder is a path segment",
    )
    var l_inbox = list_folder(s, "erin@example.com", "INBOX")
    assert_equal(len(l_inbox), 1, "INBOX lists only its own")
    assert_equal(l_inbox[0].leaf, m_inbox.leaf, "INBOX message")
    var l_arch = list_folder(s, "erin@example.com", "archive")
    assert_equal(len(l_arch), 1, "a folder does not list its sub-folders")
    assert_equal(l_arch[0].leaf, m_arch.leaf, "Archive message")
    var l_arch26 = list_folder(s, "erin@example.com", "Archive/2026")
    assert_equal(len(l_arch26), 1, "sub-folder")
    assert_equal(l_arch26[0].leaf, m_arch26.leaf, "sub-folder message")
    var names = list_folders(s, "erin@example.com")
    assert_equal(len(names), 4, "INBOX and three folders")
    assert_equal(names[0], String("INBOX"), "INBOX first")
    assert_equal(names[1], String("archive"), "then byte order")
    assert_equal(names[2], String("archive/2026"), "sub-folder")
    assert_equal(names[3], String("sent"), "last")
    var only_inbox = list_folders(s, "nobody@example.com")
    assert_equal(len(only_inbox), 1, "INBOX exists with no messages")
    assert_equal(only_inbox[0], String("INBOX"), "and is the only one")
    assert_true(
        fetch_message(s, "erin@example.com", "Sent", m_sent.leaf).found, "sent"
    )

    # ---- non-ASCII recipients and folders -----------------------------------
    var jose = String("Jos") + chr(0xE9) + "@example.com"
    var cafe = String("Caf") + chr(0xE9)
    var cjk = String(chr(0x7528)) + chr(0x6237) + "@" + chr(0x4F8B) + ".cn"
    var u1 = store_message(s, jose, "INBOX", _bytes("u1"))
    var u2 = store_message(s, jose, cafe, _bytes("u2"))
    var u3 = store_message(s, cjk, "INBOX", _bytes("u3"))
    assert_equal(
        u1.key,
        String("mailboxes/jos_c3_a9_40example.com/") + u1.leaf + ".eml",
        "non-ASCII recipient key",
    )
    assert_true(fetch_message(s, jose, "INBOX", u1.leaf).found, "jose inbox")
    assert_true(fetch_message(s, jose, cafe, u2.leaf).found, "jose cafe")
    assert_false(
        fetch_message(s, "Jos@example.com", "INBOX", u1.leaf).found,
        "a different address does not reach it",
    )
    assert_true(fetch_message(s, cjk, "INBOX", u3.leaf).found, "cjk inbox")
    assert_equal(len(list_folder(s, jose, cafe)), 1, "cafe lists its message")
    var jnames = list_folders(s, jose)
    assert_equal(len(jnames), 2, "INBOX and the non-ASCII folder")
    assert_equal(jnames[1], String("caf____"), "its normalized name")

    # ---- dot segments and empty segments stay apart -------------------------
    var d1 = store_message(s, ".", "INBOX", _bytes("dot"))
    var d2 = store_message(s, "..", "INBOX", _bytes("dotdot"))
    var d3 = store_message(s, "..", "..", _bytes("dotdot-in-dotdot"))
    var d4 = store_message(s, "carl@x", "../bob", _bytes("climb"))
    var d5 = store_message(s, "carl@x", "bob", _bytes("bob"))
    var d6 = store_message(s, "carl@x", "a//b", _bytes("empty-seg"))
    var d7 = store_message(s, "carl@x", "a/b", _bytes("plain"))
    assert_equal(len(list_folder(s, ".", "INBOX")), 1, "one in '.'")
    assert_equal(len(list_folder(s, "..", "INBOX")), 1, "one in '..'")
    assert_true(fetch_message(s, ".", "INBOX", d1.leaf).found, "dot")
    assert_false(fetch_message(s, "..", "INBOX", d1.leaf).found, "dot is not dotdot")
    assert_true(fetch_message(s, "..", "INBOX", d2.leaf).found, "dotdot")
    assert_true(fetch_message(s, "..", "..", d3.leaf).found, "dotdot folder")
    assert_equal(len(list_folder(s, "carl@x", "bob")), 1, "bob has only its own")
    assert_equal(list_folder(s, "carl@x", "bob")[0].leaf, d5.leaf, "bob")
    assert_equal(len(list_folder(s, "carl@x", "../bob")), 1, "../bob has its own")
    assert_equal(list_folder(s, "carl@x", "../bob")[0].leaf, d4.leaf, "../bob")
    assert_equal(list_folder(s, "carl@x", "a//b")[0].leaf, d6.leaf, "a//b")
    assert_equal(list_folder(s, "carl@x", "a/b")[0].leaf, d7.leaf, "a/b")
    assert_equal(len(list_folder(s, "carl@x", "a/b")), 1, "a/b has only its own")
    # The folder listing names each of them apart, escapes included.
    var dnames = list_folders(s, "carl@x")
    assert_equal(len(dnames), 5, "INBOX and four folders")
    assert_equal(dnames[0], String("INBOX"), "INBOX first")
    assert_equal(dnames[1], String("%2e./bob"), "../bob")
    assert_equal(dnames[2], String("a/%/b"), "a//b")
    assert_equal(dnames[3], String("a/b"), "a/b")
    assert_equal(dnames[4], String("bob"), "bob")
    var dd = list_folders(s, "..")
    assert_equal(len(dd), 2, "INBOX and the '..' folder")
    assert_equal(dd[1], String("%2e."), "the '..' folder")
    assert_equal(len(list_folders(s, ".")), 1, "'.' holds only INBOX mail")

    # ---- the refused names ---------------------------------------------------
    assert_true(_refused_store(s, "", "INBOX"), "empty recipient")
    assert_true(_refused_store(s, "x@y", ""), "empty folder")
    assert_true(_refused_store(s, "x@y", "  "), "blank folder")
    var refused = False
    try:
        _ = list_folder(s, "x@y", "")
    except:
        refused = True
    assert_true(refused, "listing an empty folder is refused")
    refused = False
    try:
        _ = list_folders(s, "")
    except:
        refused = True
    assert_true(refused, "listing the folders of an empty recipient is refused")
    refused = False
    try:
        _ = fetch_message(s, "", "INBOX", first.leaf)
    except:
        refused = True
    assert_true(refused, "fetching for an empty recipient is refused")

    # ---- an object that is not a message is not listed ------------------------
    _ = s.put(Path.parse("mailboxes/frank_40x/notes.txt"), _bytes("hi"))
    var fm = store_message(s, "frank@x", "INBOX", _bytes("real"))
    var fl = list_folder(s, "frank@x", "INBOX")
    assert_equal(len(fl), 1, "only the .eml object is a message")
    assert_equal(fl[0].leaf, fm.leaf, "the message")
    # In a sub-folder, a non-message object makes no folder.
    _ = s.put(Path.parse("mailboxes/frank_40x/stray/notes.txt"), _bytes("hi"))
    _ = s.put(Path.parse("mailboxes/frank_40x/stray/deep/notes.txt"), _bytes("hi"))
    var frank_folders = list_folders(s, "frank@x")
    assert_equal(len(frank_folders), 1, "a non-.eml object makes no folder")
    assert_equal(frank_folders[0], String("INBOX"), "only INBOX")
    _ = store_message(s, "frank@x", "stray", _bytes("kept"))
    assert_equal(len(list_folders(s, "frank@x")), 2, "a message makes it one")
    assert_equal(len(list_folder(s, "frank@x", "stray")), 1, "notes.txt skipped")

    # ---- two different messages with one hash are not merged -------------------
    var victim = _bytes("victim")
    var key = String("mailboxes/gina_40x/") + content_hash_hex(victim) + ".eml"
    _ = s.put(Path.parse(key), _bytes("an impostor with the same key"))
    var collided = False
    try:
        _ = store_message(s, "gina@x", "INBOX", victim)
    except:
        collided = True
    assert_true(collided, "same hash, different bytes: refused")
    assert_true(
        s.get(Path.parse(key)) == _bytes("an impostor with the same key"),
        "the existing object is left as it was",
    )


def main() raises:
    var a = SharedInMemoryConditionalStore()
    _scenario(a)
    var b = DelimiterFaithfulConditionalStore()
    _scenario(b)
    print("test_mail_store_roundtrip: ALL PASS")
