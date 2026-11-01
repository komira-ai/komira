"""`komira_mail_store`: received mail as content-addressed objects, Maildir style.

One message is one immutable object in any `komira_objectstore`
`ConditionalWriteStore`:

    mailboxes/<recipient>/<content-hash>.eml             (INBOX)
    mailboxes/<recipient>/<folder>/<content-hash>.eml    (a named folder)

The library reads no environment and names no backend: the caller picks the
store. Everything crossing its API is a value (`String`, `List[UInt8]`,
`Bool`, `Int`) or one of the result structs below.
"""

from .keys import (
    DEFAULT_FOLDER,
    MAX_FOLDER_WEIGHT,
    MAX_RECIPIENT_BYTES,
    content_hash_hex,
    folder_message_key,
    is_default_folder,
    message_key,
    normalize_folder,
    normalize_recipient,
)
from .mail_store import (
    FetchOutcome,
    MailEntry,
    StoreOutcome,
    fetch_message,
    list_folder,
    list_folders,
    message_exists,
    store_message,
)
