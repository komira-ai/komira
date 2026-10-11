# =============================================================================
# test_sqlite_erasure_bytes.mojo -- after an erasure on SQLite, the erased
#   text is in neither the database file nor its write-ahead log.
# =============================================================================
#
# Plan test (c). One database file in WAL mode, set up by
# `prepare_sql_connection` (secure_delete on). Alice, whose subject, display
# name, email and message text are distinctive strings, sends a message and
# an edited message; Bob sends a message, edits it, then deletes it. Alice is
# erased and `finish_sql_erasure` checkpoints the log. Then the bytes of
# `<db>` and `<db>-wal` are read and scanned:
#   * none of Alice's strings, and neither of the bodies of Bob's deleted
#     message (the original and the edit), may appear in either file;
#   * Bob's live message must appear in the bytes read. Without that
#     positive control an empty or unreadable file would pass.
# The connection stays open until after the scan, as a server's does: the
# close of the last connection checkpoints the log on its own.
# The scope is the file contents, not the storage device beneath them.
# =============================================================================

from std.os import getenv
from std.os.path import exists
from std.testing import assert_equal, assert_true

from komira_db import MigrationRunner
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatStore,
    NoSendProbe,
    chat_migrations,
    finish_sql_erasure,
    prepare_sql_connection,
)
from komira_chat_store_conformance import Rt, T0, new_rt

comptime ISS: StaticString = "https://issuer.example"
# Each erased string is unlike anything else the file holds.
comptime ALICE_SUB: StaticString = "subject-quince-7f3a91"
comptime ALICE_NAME: StaticString = "Alice Marmalade-Quokka"
comptime ALICE_EMAIL: StaticString = "alice.quokka@example.com"
comptime ALICE_BODY: StaticString = "alpha-secret-saffron-body"
comptime ALICE_ORIGINAL: StaticString = "beta-original-tamarind"
comptime ALICE_EDITED: StaticString = "beta-edited-cardamom"
comptime BOB_ORIGINAL: StaticString = "gamma-original-juniper"
comptime BOB_EDITED: StaticString = "gamma-edited-sumac"
comptime BOB_LIVE: StaticString = "delta-live-paprika-kept"


def _bytes_of(path: String) raises -> List[UInt8]:
    if not exists(path):
        return List[UInt8]()
    with open(path, "r") as f:
        return f.read_bytes()


def _contains(hay: List[UInt8], needle: StaticString) -> Bool:
    var n = needle.as_bytes()
    var m = len(n)
    if m == 0 or len(hay) < m:
        return False
    for i in range(len(hay) - m + 1):
        var j = 0
        while j < m and hay[i + j] == n[j]:
            j += 1
        if j == m:
            return True
    return False


def _absent(file: List[UInt8], wal: List[UInt8], s: StaticString, mut found: String):
    if _contains(file, s):
        found += String(" ") + String(s) + String(" (database file)")
    if _contains(wal, s):
        found += String(" ") + String(s) + String(" (write-ahead log)")


def main() raises:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var path = base + String("/chat_erasure.db")
    var rt = new_rt()
    ref reactor = rt.reactor()

    var db = SqliteDatabase(path)
    db.arm_for_concurrent_use[Rt](reactor, 5000)
    prepare_sql_connection[Rt, SqliteDatabase](db, reactor)
    var runner = MigrationRunner[SqliteDatabase](db^, String(CHAT_MIGRATION_LEDGER))
    _ = runner.run[Rt](reactor, chat_migrations())
    var s = ChatStore[SqliteDatabase, NoSendProbe](runner^.into_db(), NoSendProbe())

    _ = s.ensure_user[Rt](
        reactor, String("u-alice"), String(ISS), String(ALICE_SUB),
        String(ALICE_NAME), String(ALICE_EMAIL), T0,
    )
    _ = s.ensure_user[Rt](
        reactor, String("u-bob"), String(ISS), String("subject-bob"),
        String("Bob"), String(""), T0,
    )
    var bob_only = List[String]()
    bob_only.append(String("u-bob"))
    _ = s.create_channel[Rt](
        reactor, String("c-x"), CHANNEL_PUBLIC, String("x"), String(""),
        String("u-alice"), bob_only, T0,
    )
    var none = List[String]()
    _ = s.send_message[Rt](
        reactor, String("c-x"), String("u-alice"), String(ALICE_BODY), Int64(0),
        String("k-1"), none, False, none, T0 + 1,
    )
    var a2 = s.send_message[Rt](
        reactor, String("c-x"), String("u-alice"), String(ALICE_ORIGINAL), Int64(0),
        String(), none, False, none, T0 + 2,
    )
    _ = s.edit_message[Rt](
        reactor, String("c-x"), a2.seq, String("u-alice"), String(ALICE_EDITED), T0 + 3
    )
    var b1 = s.send_message[Rt](
        reactor, String("c-x"), String("u-bob"), String(BOB_ORIGINAL), Int64(0),
        String(), none, False, none, T0 + 4,
    )
    _ = s.edit_message[Rt](
        reactor, String("c-x"), b1.seq, String("u-bob"), String(BOB_EDITED), T0 + 5
    )
    _ = s.send_message[Rt](
        reactor, String("c-x"), String("u-bob"), String(BOB_LIVE), Int64(0),
        String(), none, False, none, T0 + 6,
    )
    _ = s.delete_message[Rt](reactor, String("c-x"), b1.seq, String("u-bob"), False, T0 + 7)

    var counts = s.erase_user[Rt](reactor, String("u-alice"))
    assert_equal(counts.bodies_redacted, 3, "two messages and one edit")
    finish_sql_erasure[Rt, SqliteDatabase](s.db(), reactor)

    var file = _bytes_of(path)
    var wal = _bytes_of(path + String("-wal"))
    assert_true(len(file) > 0, "the database file was read")
    assert_true(
        _contains(file, BOB_LIVE) or _contains(wal, BOB_LIVE),
        "positive control: a live message is in the bytes read",
    )
    var found = String()
    _absent(file, wal, ALICE_SUB, found)
    _absent(file, wal, ALICE_NAME, found)
    _absent(file, wal, ALICE_EMAIL, found)
    _absent(file, wal, ALICE_BODY, found)
    _absent(file, wal, ALICE_ORIGINAL, found)
    _absent(file, wal, ALICE_EDITED, found)
    _absent(file, wal, BOB_ORIGINAL, found)
    _absent(file, wal, BOB_EDITED, found)
    if found.byte_length() > 0:
        raise Error(String("erased text is still in the bytes:") + found)
    # The store, and so its connection, is used after the scan: closing the
    # last connection checkpoints the log itself, which would hide a missing
    # `finish_sql_erasure`. A server keeps its connections open.
    assert_equal(s.head_seq[Rt](reactor, String("c-x")), Int64(9))
    print(
        "PASS komira_chat_store_conformance sqlite erasure bytes ("
        + String(len(file))
        + " file bytes, "
        + String(len(wal))
        + " log bytes scanned)"
    )
