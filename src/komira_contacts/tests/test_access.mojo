# =============================================================================
# test_access.mojo -- the per-object rules of access.mojo, as a table.
# =============================================================================
#
# Every (book kind, caller) pair and its verdict for read, write and create.
# The verdict is the exact refusal text: a PERSONAL book of another subject is
# NOT FOUND (its existence is not revealed), a readable but unwritable book is
# FORBIDDEN. What each row would catch:
#   - other subject reads/writes a PERSONAL book: the owner comparison
#     dropped or inverted (an IDOR);
#   - an empty subject against a PERSONAL book whose owner is empty: the
#     "subject must be non-empty" term dropped;
#   - a non-admin writes a SHARED book: the admin term dropped;
#   - anyone writes a DIRECTORY book: the read-only rule dropped;
#   - an UNSPECIFIED kind: a default-allow fall-through.
# =============================================================================

from std.testing import assert_equal

from komira_contacts_proto.contacts import BookKind

from komira_contacts import (
    Caller,
    ERR_FORBIDDEN,
    ERR_NOT_FOUND,
    check_create_book,
    check_read_book,
    check_write_book,
)

comptime OK = "ok"


def _verdict_read(c: Caller, kind: Int, owner: String) -> String:
    try:
        check_read_book(c, kind, owner)
        return String(OK)
    except e:
        return String(e)


def _verdict_write(c: Caller, kind: Int, owner: String) -> String:
    try:
        check_write_book(c, kind, owner)
        return String(OK)
    except e:
        return String(e)


def _verdict_create(c: Caller, kind: Int) -> String:
    try:
        check_create_book(c, kind)
        return String(OK)
    except e:
        return String(e)


def test_read_write_table() raises:
    var alice = Caller(String("alice"), False)
    var bob = Caller(String("bob"), False)
    var admin = Caller(String("root"), True)
    var nobody = Caller(String(""), False)
    var P = BookKind.PERSONAL
    var S = BookKind.SHARED
    var D = BookKind.DIRECTORY
    var U = BookKind.BOOK_KIND_UNSPECIFIED

    # PERSONAL: the owner only, admin or not.
    assert_equal(_verdict_read(alice, P, "alice"), OK, "owner reads own")
    assert_equal(_verdict_write(alice, P, "alice"), OK, "owner writes own")
    assert_equal(_verdict_read(bob, P, "alice"), ERR_NOT_FOUND, "other subject reads")
    assert_equal(_verdict_write(bob, P, "alice"), ERR_NOT_FOUND, "other subject writes")
    assert_equal(_verdict_read(admin, P, "alice"), ERR_NOT_FOUND, "admin reads another's")
    assert_equal(_verdict_write(admin, P, "alice"), ERR_NOT_FOUND, "admin writes another's")
    assert_equal(_verdict_read(nobody, P, ""), ERR_NOT_FOUND, "empty subject, empty owner")

    # SHARED: everyone reads, an admin writes.
    assert_equal(_verdict_read(bob, S, ""), OK, "anyone reads shared")
    assert_equal(_verdict_write(bob, S, ""), ERR_FORBIDDEN, "non-admin writes shared")
    assert_equal(_verdict_write(admin, S, ""), OK, "admin writes shared")

    # DIRECTORY: everyone reads, nobody writes.
    assert_equal(_verdict_read(bob, D, ""), OK, "anyone reads the directory")
    assert_equal(_verdict_write(admin, D, ""), ERR_FORBIDDEN, "admin writes the directory")

    # An unknown kind is unreadable.
    assert_equal(_verdict_read(admin, U, ""), ERR_NOT_FOUND, "unspecified kind")
    assert_equal(_verdict_write(admin, U, ""), ERR_NOT_FOUND, "unspecified kind write")


def test_create_table() raises:
    var bob = Caller(String("bob"), False)
    var admin = Caller(String("root"), True)
    var nobody = Caller(String(""), True)
    assert_equal(_verdict_create(bob, BookKind.PERSONAL), OK)
    assert_equal(_verdict_create(bob, BookKind.SHARED), ERR_FORBIDDEN)
    assert_equal(_verdict_create(admin, BookKind.SHARED), OK)
    assert_equal(_verdict_create(nobody, BookKind.PERSONAL), ERR_FORBIDDEN)
    assert_equal(
        _verdict_create(admin, BookKind.DIRECTORY),
        "contacts: invalid kind: a DIRECTORY book is projected from the directory, not created",
    )
    assert_equal(
        _verdict_create(admin, BookKind.BOOK_KIND_UNSPECIFIED),
        "contacts: invalid kind: must be PERSONAL or SHARED",
    )


def main() raises:
    test_read_write_table()
    test_create_table()
    print("PASS komira_contacts access")
