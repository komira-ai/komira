# =============================================================================
# komira_contacts -- address books and cards for a simple contacts service.
# =============================================================================
#
#   store.mojo     ContactsStore[DB]: books, cards, the change feed, over any
#                  komira_db `Database`
#   access.mojo    Caller and the per-object rules (who reads and writes
#                  which book); the authorization port's resource kind and
#                  actions
#   validate.mojo  what a client may write
#   schema.mojo    the tables, the SQLite DDL and the document-backend index
#   errors.mojo    the refusal texts
# =============================================================================

from .access import (
    ACTION_ADMIN,
    ACTION_READ,
    ACTION_WRITE,
    AUTHZ_RESOURCE_KIND,
    Caller,
    can_read_book,
    check_create_book,
    check_read_book,
    check_write_book,
)
from .errors import (
    ERR_DEFAULT_TAKEN,
    ERR_FORBIDDEN,
    ERR_INVALID,
    ERR_NOT_FOUND,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
)
from .schema import (
    BOOKS,
    CARDS,
    CARD_UIDS,
    DEFAULT_BOOKS,
    CompositeIndex,
    composite_indexes,
    sqlite_schema,
)
from .store import ContactsStore
from .validate import check_book_name, check_card
