# =============================================================================
# komira_contacts/access.mojo -- who may read and write which address book.
# =============================================================================
#
# Two layers decide a request. The deployment's authorization port answers
# one coarse question per route: may this subject `read`, `write` or `admin`
# the resource `{kind: "app", id: <the deployment's client id>}`. It knows no
# book or card id. The per-object rules below are the app's own, and the
# store applies them on every call, so no handler can skip them:
#
#   book kind   read                  write a card in it      create it
#   PERSONAL    its owner only        its owner only          any subject, as owner
#   SHARED      every caller          an admin only           an admin only
#   DIRECTORY   every caller          nobody                  nobody (projected)
#
# A book the caller may not read is NOT FOUND, with the same text as a book
# that does not exist, so a guessed id reveals nothing. A book the caller may
# read but not write is FORBIDDEN.
#
# `Caller.admin` is the answer of the authorization port to `admin` on the
# app resource; the store does not ask the port itself.
# =============================================================================

from komira_contacts_proto.contacts import BookKind

from komira_contacts.errors import forbidden, invalid, not_found

# The authorization port's resource kind and actions for this app.
comptime AUTHZ_RESOURCE_KIND: StaticString = "app"
comptime ACTION_READ: StaticString = "read"
comptime ACTION_WRITE: StaticString = "write"
comptime ACTION_ADMIN: StaticString = "admin"


@fieldwise_init
struct Caller(Copyable, Movable):
    """The authenticated subject a request runs as, and whether the
    authorization port granted it `admin` on the app."""

    var subject: String
    var admin: Bool


def can_read_book(caller: Caller, kind: Int, owner: String) -> Bool:
    """True iff `caller` may read a book of `kind` owned by `owner`."""
    if kind == BookKind.PERSONAL:
        return caller.subject.byte_length() > 0 and owner == caller.subject
    if kind == BookKind.SHARED or kind == BookKind.DIRECTORY:
        return True
    return False


def check_read_book(caller: Caller, kind: Int, owner: String) raises:
    """Raise not-found unless `caller` may read the book."""
    if not can_read_book(caller, kind, owner):
        raise not_found()


def check_write_book(caller: Caller, kind: Int, owner: String) raises:
    """Raise not-found when `caller` may not read the book, forbidden when it
    may read but not write the cards in it."""
    check_read_book(caller, kind, owner)
    if kind == BookKind.PERSONAL:
        return
    if kind == BookKind.SHARED and caller.admin:
        return
    raise forbidden()


def check_create_book(caller: Caller, kind: Int) raises:
    """Raise unless `caller` may create a book of `kind`."""
    if caller.subject.byte_length() == 0:
        raise forbidden()
    if kind == BookKind.PERSONAL:
        return
    if kind == BookKind.SHARED:
        if caller.admin:
            return
        raise forbidden()
    if kind == BookKind.DIRECTORY:
        raise invalid("kind", "a DIRECTORY book is projected from the directory, not created")
    raise invalid("kind", "must be PERSONAL or SHARED")
