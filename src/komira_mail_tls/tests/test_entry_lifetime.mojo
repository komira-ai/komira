# The table's entries: created once, freed exactly once, found by id.
# What each case catches:
# - churn: one id added and dropped 1000 times frees an entry at every drop (a
#   leak, a deferred free or a double free of the Slab[OwnedPointer[...]] slot
#   moves the tallies off the loop count);
# - growth and removal from the middle: twelve live entries force the slab to
#   reallocate; dropping a middle, the first and the last entry frees one each,
#   and every other id still resolves (a swap_remove that leaves the id list
#   out of step answers for the wrong connection);
# - a table destroyed with live entries frees them all;
# - an unknown id: drop, drive_handshake_burst, recv and send touch nothing and
#   answer ERROR;
# - pending plaintext at begin_upgrade is refused with no entry created (the
#   STARTTLS command-injection guard), and a repeated begin_upgrade for one id
#   makes one entry;
# - an id that is reused without a drop, with a different socket, is refused
#   and the entry keeps its first socket (TLS bytes must never go to a recycled
#   descriptor);
# - recv with a zero or negative byte limit is an error, never a
#   (DONE, 0) that would read as the peer's close_notify;
# - a bad key raises without echoing the key text.

from std.testing import assert_equal, assert_false, assert_true
from std.pathlib import Path

from komira_async.reactor.socket_setup import close_fd, socket_tcp_nonblocking
from komira_mail_tls import (
    MailTlsTable,
    TLS_OUTCOME_ERROR,
    tls_entries_created,
    tls_entries_freed,
)


def _cert() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


def _table() raises -> MailTlsTable:
    return MailTlsTable.from_cert_pem(_cert(), _key())


def _hold_live_entries(fd: Int32, n: Int) raises:
    var table = _table()
    for i in range(n):
        table.begin_upgrade(i, fd, 0)
    assert_equal(table.tls_conn_count(), n)


def test_churn_frees_each_entry_once() raises:
    var fd = socket_tcp_nonblocking()
    var table = _table()
    var created0 = tls_entries_created()
    var freed0 = tls_entries_freed()
    for i in range(1000):
        table.begin_upgrade(7, fd, 0)
        assert_true(table.is_tls(7))
        assert_equal(tls_entries_created() - created0, i + 1)
        assert_equal(tls_entries_freed() - freed0, i)
        table.drop(7)
        assert_false(table.is_tls(7))
        assert_equal(table.tls_conn_count(), 0)
        assert_equal(tls_entries_freed() - freed0, i + 1)
    assert_equal(tls_entries_created() - created0, 1000)
    assert_equal(tls_entries_freed() - freed0, 1000)
    close_fd(fd)


def test_growth_and_removal_from_the_middle() raises:
    var fd = socket_tcp_nonblocking()
    var table = _table()
    var created0 = tls_entries_created()
    var freed0 = tls_entries_freed()
    # Each id gets its own number as the bound socket, so a removal that frees
    # or keeps the wrong entry shows in `conn_fd`. s2n only records the number.
    for i in range(12):
        table.begin_upgrade(100 + i, Int32(1000 + i), 0)
    assert_equal(table.tls_conn_count(), 12)
    assert_equal(tls_entries_created() - created0, 12)
    assert_equal(tls_entries_freed() - freed0, 0)

    table.drop(105)  # a middle entry
    table.drop(100)  # the first
    table.drop(111)  # the last
    assert_equal(tls_entries_freed() - freed0, 3)
    assert_equal(table.tls_conn_count(), 9)
    assert_false(table.is_tls(105))
    assert_false(table.is_tls(100))
    assert_false(table.is_tls(111))
    for id in [101, 102, 103, 104, 106, 107, 108, 109, 110]:
        assert_true(table.is_tls(id))
        assert_equal(Int(table.conn_fd(id)), 1000 + id - 100)
    assert_equal(Int(table.conn_fd(105)), -1)
    # A dropped id is free to be used again, and is a new entry.
    table.begin_upgrade(105, Int32(2105), 0)
    assert_true(table.is_tls(105))
    assert_equal(Int(table.conn_fd(105)), 2105)
    assert_equal(tls_entries_created() - created0, 13)

    for id in [101, 102, 103, 104, 105, 106, 107, 108, 109, 110]:
        table.drop(id)
    assert_equal(table.tls_conn_count(), 0)
    assert_equal(tls_entries_created() - created0, 13)
    assert_equal(tls_entries_freed() - freed0, 13)
    close_fd(fd)


def test_destroyed_table_frees_live_entries() raises:
    var fd = socket_tcp_nonblocking()
    var created0 = tls_entries_created()
    var freed0 = tls_entries_freed()
    _hold_live_entries(fd, 5)
    assert_equal(tls_entries_created() - created0, 5)
    assert_equal(tls_entries_freed() - freed0, 5)
    close_fd(fd)


def test_unknown_id_touches_nothing() raises:
    var fd = socket_tcp_nonblocking()
    var table = _table()
    table.drop(99)  # empty table
    table.begin_upgrade(1, fd, 0)
    var freed0 = tls_entries_freed()
    table.drop(99)  # not the id held
    assert_equal(tls_entries_freed() - freed0, 0)
    assert_equal(table.tls_conn_count(), 1)
    assert_true(table.is_tls(1))

    assert_false(table.is_tls(99))
    assert_false(table.handshake_done(99))
    assert_equal(Int(table.drive_handshake_burst(99)), Int(TLS_OUTCOME_ERROR))
    var into = List[UInt8]()
    var r = table.recv(99, into, 100)
    assert_equal(Int(r[0]), Int(TLS_OUTCOME_ERROR))
    assert_equal(r[1], -1)
    assert_equal(len(into), 0)
    var data = List[UInt8](length=3, fill=UInt8(65))
    var s = table.send(99, Span[UInt8](data))
    assert_equal(Int(s[0]), Int(TLS_OUTCOME_ERROR))
    assert_equal(s[1], -1)
    table.drop(1)
    close_fd(fd)


def test_pending_plaintext_refused_and_duplicate_ignored() raises:
    var fd = socket_tcp_nonblocking()
    var table = _table()
    var created0 = tls_entries_created()
    var refused = False
    try:
        table.begin_upgrade(1, fd, 5)
    except:
        refused = True
    assert_true(refused)
    assert_false(table.is_tls(1))
    assert_equal(table.tls_conn_count(), 0)
    assert_equal(tls_entries_created() - created0, 0)

    table.begin_upgrade(1, fd, 0)
    table.begin_upgrade(1, fd, 0)  # the same id again
    assert_equal(table.tls_conn_count(), 1)
    assert_equal(tls_entries_created() - created0, 1)
    # Even a repeated call is refused while plaintext is buffered.
    var refused_again = False
    try:
        table.begin_upgrade(1, fd, 1)
    except:
        refused_again = True
    assert_true(refused_again)
    table.drop(1)
    close_fd(fd)


def test_reused_id_with_another_fd_is_refused() raises:
    var table = _table()
    var created0 = tls_entries_created()
    table.begin_upgrade(1, Int32(500), 0)
    var refused = False
    try:
        table.begin_upgrade(1, Int32(501), 0)
    except:
        refused = True
    assert_true(refused)
    assert_equal(Int(table.conn_fd(1)), 500)
    assert_equal(table.tls_conn_count(), 1)
    assert_equal(tls_entries_created() - created0, 1)
    table.begin_upgrade(1, Int32(500), 0)  # the same socket: still a no-op
    assert_equal(tls_entries_created() - created0, 1)
    table.drop(1)
    # After a drop the id may take a new socket.
    table.begin_upgrade(1, Int32(501), 0)
    assert_equal(Int(table.conn_fd(1)), 501)
    table.drop(1)


def test_recv_with_no_room_is_an_error() raises:
    var table = _table()
    table.begin_upgrade(1, Int32(500), 0)
    var into = List[UInt8]()
    for limit in [0, -5]:
        var r = table.recv(1, into, limit)
        assert_equal(Int(r[0]), Int(TLS_OUTCOME_ERROR))
        assert_equal(r[1], -1)
        assert_equal(len(into), 0)
    table.drop(1)


def test_bad_key_raises_without_echo() raises:
    var bad_key = String("this is not a private key")
    var raised = False
    var message = String("")
    try:
        _ = MailTlsTable.from_cert_pem(_cert(), bad_key)
    except e:
        raised = True
        message = String(e)
    assert_true(raised)
    assert_false("this is not a private key" in message)


def main() raises:
    test_churn_frees_each_entry_once()
    test_growth_and_removal_from_the_middle()
    test_destroyed_table_frees_live_entries()
    test_unknown_id_touches_nothing()
    test_pending_plaintext_refused_and_duplicate_ignored()
    test_reused_id_with_another_fd_is_refused()
    test_recv_with_no_room_is_an_error()
    test_bad_key_raises_without_echo()
    print("test_entry_lifetime: OK")
