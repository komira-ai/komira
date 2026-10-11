# =============================================================================
# komira_contacts/errors.mojo -- the texts the store raises.
# =============================================================================
#
# Every refusal of the store is an `Error` whose text starts with one of the
# constants below, so a caller maps it to an HTTP status by prefix. The
# not-found text names no id: a card or book the caller may not read is
# refused with the same bytes as one that does not exist.
# =============================================================================

comptime ERR_NOT_FOUND: StaticString = "contacts: not found"
comptime ERR_FORBIDDEN: StaticString = "contacts: forbidden"
comptime ERR_VERSION_CONFLICT: StaticString = "contacts: version conflict"
comptime ERR_UID_TAKEN: StaticString = "contacts: uid is already used in this address book"
comptime ERR_DEFAULT_TAKEN: StaticString = "contacts: the owner already has a default address book"
comptime ERR_INVALID: StaticString = "contacts: invalid "


def invalid(field: StaticString, why: StaticString) -> Error:
    """`contacts: invalid <field>: <why>`."""
    return Error(String(ERR_INVALID) + String(field) + String(": ") + String(why))


def not_found() -> Error:
    return Error(String(ERR_NOT_FOUND))


def forbidden() -> Error:
    return Error(String(ERR_FORBIDDEN))
