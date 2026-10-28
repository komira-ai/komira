# Tagged completion lines: `<tag> OK|NO|BAD [code] text`.

from .connection import ImapConnection


def tagged_ok(mut conn: ImapConnection, tag: String, text: String):
    conn.enqueue(tag + " OK " + text + "\r\n")


def tagged_ok_code(
    mut conn: ImapConnection, tag: String, code: String, text: String
):
    conn.enqueue(tag + " OK [" + code + "] " + text + "\r\n")


def tagged_no(mut conn: ImapConnection, tag: String, text: String):
    conn.enqueue(tag + " NO " + text + "\r\n")


def tagged_no_code(
    mut conn: ImapConnection, tag: String, code: String, text: String
):
    conn.enqueue(tag + " NO [" + code + "] " + text + "\r\n")


def tagged_bad(mut conn: ImapConnection, tag: String, text: String):
    conn.enqueue(tag + " BAD " + text + "\r\n")


def tagged_bad_code(
    mut conn: ImapConnection, tag: String, code: String, text: String
):
    conn.enqueue(tag + " BAD [" + code + "] " + text + "\r\n")


def internal_error(mut conn: ImapConnection, tag: String):
    """A store failure while running a command. The text names nothing about
    the failure: store errors quote keys, and keys hold mailbox names."""
    tagged_no_code(conn, tag, "SERVERBUG", "Internal error, try again")
