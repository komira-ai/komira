# =============================================================================
# komira_vcard -- vCard (RFC 6350) reading and writing on the shared
# content-line layer (komira_content_line).
# =============================================================================
#
# Reads vCard 4.0, 3.0 (RFC 2426) and 2.1 (quoted-printable values, bare
# parameters); writes vCard 4.0. Two levels:
#
# - `parse_vcards(bytes, limits)` gives raw cards: every line lexed, in order
#   (card.mojo says what is refused).
# - `parse_contacts(bytes, limits)` maps each card to a `Contact`, the RFC
#   9555-guided subset (contact.mojo), keeping every unmapped property in
#   `Contact.extra`; `emit_contacts` writes them back as vCard 4.0.
#
#     from komira_vcard import parse_contacts, emit_contacts
#     var got = parse_contacts("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Jane\r\n"
#                              "END:VCARD\r\n".as_bytes())
#     var text = emit_contacts(got.contacts)
# =============================================================================

from .card import DEFAULT_MAX_CARDS, VCard, VCardLimits, VCardLine, parse_vcards
from .contact import Contact, ContactAddress, ContactImport, ContactValue
from .read import contact_from_vcard, parse_contacts
from .write import emit_contact, emit_contacts
