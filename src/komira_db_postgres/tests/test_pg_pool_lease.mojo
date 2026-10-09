"""komira_db_postgres.pg_pool: PgPool's pg-named surface over Pool[PgDatabase].

NO NETWORK, NO SERVER. `PgPool.connect` dials a server, so this test builds
the pool from its parts instead: two OFFLINE `PgDatabase` values, each a
`PgConnection` over a socketpair fd and a never-handshaked client TLS
connection. No pgwire byte is sent on them; the pool only moves them, and
`close` makes the best-effort TLS shutdown call (its outcome ignored) and
sets the closed flag.

What it proves, one wrapper at a time (each forwards to the generic pool;
binding a wrapper to the wrong inner method fails an assertion below, except
take/vacate, which run the same code in Pool):

  * size / in_use_count / connects_made read the inner pool;
  * checkout hands out the lowest free lease and raises when exhausted;
  * return_conn frees a lease, and refuses a lease that is not out;
  * take empties the slot (is_vacated) and give_back refills it AND frees the
    lease; vacate empties it but KEEPS the lease and restore refills it
    without freeing the lease;
  * discard keeps a slot out of later checkouts;
  * close closes every connection still in its slot and skips a vacated one
    (whose holder owns it); a second close leaves a connection closed;
  * PgDatabase.into_conn hands back the same connection (same fd).
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_async.runtime.tcp_stream import TcpStream
from komira_collections.slab import Slab
from komira_db.pool import Pool, _FreeList
from komira_http_core.tls.s2n_shim import TlsConfig, TlsConnection

from komira_db_postgres.pg_driver import PgDatabase
from komira_db_postgres.pg_pool import PgPool
from komira_db_postgres.wire.connection import PgConfig, PgConnection
from komira_db_postgres.wire.pg_tls import PgReactorStream


comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and does not
    retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _offline_db(fd: Int32) raises -> PgDatabase:
    """A PgDatabase over `fd` (owned from here on by its TcpStream) and an
    unbound, never-handshaked client TLS connection."""
    var cfg = TlsConfig()
    var tls = TlsConnection.new_client(cfg)
    var stream = PgReactorStream(cfg^, tls^, TcpStream(fd))
    return PgDatabase(PgConnection(stream^))


def _config() -> PgConfig:
    return PgConfig(
        String("127.0.0.1"),
        UInt16(5432),
        String("u"),
        String("p"),
        String("d"),
    )


def _pool_of_two(fd_a: Int32, fd_b: Int32, connects: Int) raises -> PgPool:
    var slots = Slab[Optional[PgDatabase]](2)
    slots.append(Optional[PgDatabase](_offline_db(fd_a)))
    slots.append(Optional[PgDatabase](_offline_db(fd_b)))
    return PgPool(
        Pool[PgDatabase](slots^, _FreeList(2), _config(), connects)
    )


def _inspect(
    var db: PgDatabase, mut fd: Int32, mut closed: Bool
) -> PgDatabase:
    """Read `db`'s connection fd and closed flag (via into_conn), and return
    `db` re-wrapped around the same connection."""
    var conn = db^.into_conn()
    fd = conn.stream_fd()
    closed = conn.closed()
    return PgDatabase(conn^)


# =============================================================================
# 1. Introspection, checkout order, exhaustion, return_conn.
# =============================================================================
def test_checkout_and_return() raises:
    var pa = _socketpair()
    var pb = _socketpair()
    var pool = _pool_of_two(pa[0], pb[0], 7)
    assert_equal(pool.size(), 2)
    assert_equal(pool.in_use_count(), 0)
    assert_equal(pool.connects_made(), 7)

    var l0 = pool.checkout()
    var l1 = pool.checkout()
    assert_equal(l0, 0)
    assert_equal(l1, 1)
    assert_equal(pool.in_use_count(), 2)
    with assert_raises(contains="Pool exhausted: all 2 resources are in use"):
        _ = pool.checkout()

    pool.return_conn(l1)
    assert_equal(pool.in_use_count(), 1)
    with assert_raises(contains="was not checked out"):
        pool.return_conn(l1)
    # The freed lease is handed out again.
    assert_equal(pool.checkout(), 1)
    assert_equal(pool.connects_made(), 7)
    _ = pool^
    _close_fd(pa[1])
    _close_fd(pb[1])
    print("  [1] size/in_use/connects_made; checkout order, exhaustion OK")


# =============================================================================
# 2. take/give_back free the lease; vacate/restore keep it.
# =============================================================================
def test_take_vacate_cycles() raises:
    var pa = _socketpair()
    var pb = _socketpair()
    var pool = _pool_of_two(pa[0], pb[0], 2)
    var l0 = pool.checkout()
    var l1 = pool.checkout()

    # take -> the slot is empty; the moved-out db is slot 0's connection.
    var db0 = pool.take(l0)
    assert_true(pool.is_vacated(l0))
    assert_false(pool.is_vacated(l1))
    with assert_raises(contains="already vacated"):
        _ = pool.take(l0)
    var fd = Int32(-1)
    var closed = True
    db0 = _inspect(db0^, fd, closed)
    assert_equal(fd, pa[0])
    assert_false(closed)
    # give_back refills the slot AND frees the lease.
    pool.give_back(l0, db0^)
    assert_false(pool.is_vacated(l0))
    assert_equal(pool.in_use_count(), 1)

    # vacate -> slot empty, lease still out; restore refills, lease still out.
    var db1 = pool.vacate(l1)
    assert_true(pool.is_vacated(l1))
    assert_equal(pool.in_use_count(), 1)
    with assert_raises(contains="double-vacate"):
        _ = pool.vacate(l1)
    pool.restore(l1, db1^)
    assert_false(pool.is_vacated(l1))
    assert_equal(pool.in_use_count(), 1)
    pool.return_conn(l1)
    assert_equal(pool.in_use_count(), 0)
    with assert_raises(contains="out of range"):
        _ = pool.is_vacated(2)
    _ = pool^
    _close_fd(pa[1])
    _close_fd(pb[1])
    print("  [2] take/give_back frees the lease; vacate/restore keeps it OK")


# =============================================================================
# 3. discard; close skips a vacated slot; close is idempotent.
# =============================================================================
def test_discard_and_close() raises:
    var pa = _socketpair()
    var pb = _socketpair()
    var pool = _pool_of_two(pa[0], pb[0], 2)
    var l0 = pool.checkout()
    pool.discard(l0)
    pool.return_conn(l0)
    # Slot 0 is dead: the next checkout skips it.
    assert_equal(pool.checkout(), 1)
    with assert_raises(contains="Pool exhausted"):
        _ = pool.checkout()

    # Vacate slot 1, close the pool: slot 0 (live, in its slot) is closed,
    # the vacated connection is not.
    var held = pool.vacate(1)
    pool.close()
    var fd = Int32(-1)
    var closed = True
    held = _inspect(held^, fd, closed)
    assert_equal(fd, pb[0])
    assert_false(closed, "a vacated connection is its holder's to close")
    pool.restore(1, held^)

    var db0 = pool.take(0)
    closed = False
    db0 = _inspect(db0^, fd, closed)
    assert_equal(fd, pa[0])
    assert_true(closed, "close() closed the connection left in slot 0")
    # Closing an already-closed connection leaves it closed.
    db0.close()
    db0 = _inspect(db0^, fd, closed)
    assert_true(closed)
    pool.restore(0, db0^)  # slot 0 is not leased: restore, not give_back
    _ = pool^
    _close_fd(pa[1])
    _close_fd(pb[1])
    print("  [3] discard skips the slot; close skips vacated; idempotent OK")


def main() raises:
    print("== komira_db_postgres.pg_pool lease surface ==")
    test_checkout_and_return()
    test_take_vacate_cycles()
    test_discard_and_close()
    print("== PASSED ==")
