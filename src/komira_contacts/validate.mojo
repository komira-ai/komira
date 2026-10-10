# =============================================================================
# komira_contacts/validate.mojo -- what a client may write.
# =============================================================================
#
# The store calls these before any write; each raises `contacts: invalid
# <field>: <why>` (errors.mojo). The server-written fields of a card (`id`,
# `address_book_id`, `version`, `modseq`) are not checked: the store
# overwrites them.
#
#   book name   1 to MAX_NAME_BYTES bytes, one line
#   card kind   INDIVIDUAL, ORG or GROUP
#   uid         at most MAX_UID_BYTES bytes, one line (empty: the store mints one)
#   members     only on a GROUP card
#   pref        0 to 100 on every email, phone and address (RFC 6350 §5.3)
# =============================================================================

from komira_contacts_proto.contacts import Card, CardKind

from komira_contacts.errors import invalid

comptime MAX_NAME_BYTES: Int = 255
comptime MAX_UID_BYTES: Int = 1024
comptime MAX_PREF: UInt32 = 100


def _has_line_break(s: String) -> Bool:
    for b in s.as_bytes():
        if b == UInt8(ord("\n")) or b == UInt8(ord("\r")):
            return True
    return False


def check_book_name(name: String) raises:
    if name.byte_length() == 0:
        raise invalid("name", "required")
    if name.byte_length() > MAX_NAME_BYTES:
        raise invalid("name", "longer than 255 bytes")
    if _has_line_break(name):
        raise invalid("name", "must be one line")


def check_card(card: Card) raises:
    var kind = card.kind.value
    if kind != CardKind.INDIVIDUAL and kind != CardKind.ORG and kind != CardKind.GROUP:
        raise invalid("kind", "must be INDIVIDUAL, ORG or GROUP")
    if card.uid.byte_length() > MAX_UID_BYTES:
        raise invalid("uid", "longer than 1024 bytes")
    if _has_line_break(card.uid):
        raise invalid("uid", "must be one line")
    if len(card.members) > 0 and kind != CardKind.GROUP:
        raise invalid("members", "only a GROUP card has members")
    for i in range(len(card.emails)):
        if card.emails[i].pref > MAX_PREF:
            raise invalid("emails", "pref must be 0 to 100")
    for i in range(len(card.phones)):
        if card.phones[i].pref > MAX_PREF:
            raise invalid("phones", "pref must be 0 to 100")
    for i in range(len(card.addresses)):
        if card.addresses[i].pref > MAX_PREF:
            raise invalid("addresses", "pref must be 0 to 100")
