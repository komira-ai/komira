# The command dispatcher: one complete line in, replies queued, an action out.
#
# CAPABILITY, NOOP, LOGOUT, STARTTLS and LOGIN are here; SELECT, EXAMINE,
# LIST and CLOSE are in mailbox.mojo, FETCH in fetch.mojo, STORE and EXPUNGE
# in search_store.mojo. A command this server does not implement is answered
# `NO [CANNOT]` (a real IMAP4rev1 command) or `BAD` (not a command), never
# with a dropped connection. No socket, no clock: the time is a parameter, the
# connection is a value.

from komira_mail_auth import MailAuthVerifier
from komira_mail_store import normalize_recipient
from komira_objectstore.store import CloneableConditionalWriteStore

from .connection import (
    IMAP_ACTION_CLOSE,
    IMAP_ACTION_CONTINUE,
    IMAP_ACTION_START_TLS,
    IMAP_STATE_AUTH,
    IMAP_STATE_NOTAUTH,
    IMAP_STATE_SELECTED,
    ImapConnection,
)
from .fetch import handle_fetch
from .limits import ImapServerConfig
from .mailbox import handle_close, handle_list, handle_select
from .parse import (
    ArgCursor,
    is_printable_ascii,
    literal_tail,
    split_command,
    split_word,
    upper_ascii,
    valid_tag,
)
from .reply import (
    tagged_bad,
    tagged_bad_code,
    tagged_no,
    tagged_no_code,
    tagged_ok,
    tagged_ok_code,
)
from .search_store import handle_expunge, handle_store

# What `_classify` says about a command word.
comptime _UNKNOWN: Int = 0
comptime _SUPPORTED: Int = 1
comptime _UNSUPPORTED: Int = 2


def capability_text(config: ImapServerConfig, tls_active: Bool) -> String:
    """The capability list: IMAP4rev1; STARTTLS while the channel is clear
    and a certificate is configured; LOGINDISABLED while LOGIN needs TLS and
    the channel is clear (RFC 3501 section 7.2.1 and RFC 2595)."""
    var out = String("IMAP4rev1")
    if config.offer_starttls and not tls_active:
        out += String(" STARTTLS")
    if config.require_tls_for_login and not tls_active:
        out += String(" LOGINDISABLED")
    return out^


def greeting(config: ImapServerConfig, tls_active: Bool) -> String:
    """The untagged OK a connection starts with."""
    return (
        String("* OK [CAPABILITY ")
        + capability_text(config, tls_active)
        + "] "
        + config.hostname
        + " IMAP4rev1 ready\r\n"
    )


def _classify(cmd: String) -> Int:
    if (
        cmd == "CAPABILITY"
        or cmd == "NOOP"
        or cmd == "LOGOUT"
        or cmd == "STARTTLS"
        or cmd == "LOGIN"
        or cmd == "SELECT"
        or cmd == "EXAMINE"
        or cmd == "LIST"
        or cmd == "CLOSE"
        or cmd == "FETCH"
        or cmd == "STORE"
        or cmd == "EXPUNGE"
        or cmd == "UID"
    ):
        return _SUPPORTED
    if (
        cmd == "SEARCH"
        or cmd == "APPEND"
        or cmd == "CREATE"
        or cmd == "DELETE"
        or cmd == "RENAME"
        or cmd == "SUBSCRIBE"
        or cmd == "UNSUBSCRIBE"
        or cmd == "LSUB"
        or cmd == "STATUS"
        or cmd == "COPY"
        or cmd == "CHECK"
        or cmd == "IDLE"
        or cmd == "AUTHENTICATE"
        or cmd == "NAMESPACE"
        or cmd == "UNSELECT"
        or cmd == "MOVE"
        or cmd == "ENABLE"
        or cmd == "ID"
    ):
        return _UNSUPPORTED
    return _UNKNOWN


def handle_line[
    S: CloneableConditionalWriteStore,
    V: MailAuthVerifier,
](
    mut conn: ImapConnection,
    line: Span[UInt8, _],
    config: ImapServerConfig,
    verifier: V,
    mut store: S,
    now_ms: Int,
) -> UInt8:
    """Run one command line (CRLF excluded). Returns what the serving loop
    does next: continue, close after the replies are written, or start TLS.

    Checked before the command: the line is printable ASCII (a control byte
    or a byte over 0x7F is BAD, so a password with a non-ASCII byte never
    reaches the verifier), the tag is a valid tag, and the line does not
    end in a literal announcement (`{n}` is BAD, `{n+}` is BAD and closes the
    connection, since its bytes are already on the way and would run as
    commands)."""
    if not is_printable_ascii(line):
        conn.enqueue(
            String("* BAD Command lines are ASCII text without control characters\r\n")
        )
        return IMAP_ACTION_CONTINUE
    var text = String(unsafe_from_utf8=line)
    var parsed = split_command(text)
    if not valid_tag(parsed.tag):
        conn.enqueue(String("* BAD Missing or invalid tag\r\n"))
        return IMAP_ACTION_CONTINUE
    var tag = parsed.tag
    var literal = literal_tail(line)
    if literal >= 0:
        tagged_bad_code(conn, tag, "CLIENTBUG", "Literals are not supported")
        if literal == 1:
            conn.enqueue(String("* BYE Literals are not supported\r\n"))
            return IMAP_ACTION_CLOSE
        return IMAP_ACTION_CONTINUE
    var cmd = parsed.cmd
    var args = parsed.args
    if cmd.byte_length() == 0:
        tagged_bad(conn, tag, "Missing command")
        return IMAP_ACTION_CONTINUE

    # Valid in every state.
    if cmd == "CAPABILITY":
        if args.byte_length() > 0:
            tagged_bad(conn, tag, "CAPABILITY takes no arguments")
            return IMAP_ACTION_CONTINUE
        conn.enqueue(
            String("* CAPABILITY ")
            + capability_text(config, conn.tls_active)
            + "\r\n"
        )
        tagged_ok(conn, tag, "CAPABILITY completed")
        return IMAP_ACTION_CONTINUE
    if cmd == "NOOP":
        if args.byte_length() > 0:
            tagged_bad(conn, tag, "NOOP takes no arguments")
            return IMAP_ACTION_CONTINUE
        tagged_ok(conn, tag, "NOOP completed")
        return IMAP_ACTION_CONTINUE
    if cmd == "LOGOUT":
        if args.byte_length() > 0:
            tagged_bad(conn, tag, "LOGOUT takes no arguments")
            return IMAP_ACTION_CONTINUE
        conn.enqueue(String("* BYE ") + config.hostname + " logging out\r\n")
        tagged_ok(conn, tag, "LOGOUT completed")
        return IMAP_ACTION_CLOSE
    if cmd == "STARTTLS":
        return _starttls(conn, config, tag, args)
    if cmd == "LOGIN":
        return _login(conn, config, verifier, tag, args)

    var kind = _classify(cmd)
    if kind == _UNKNOWN:
        tagged_bad(conn, tag, "Command not recognized")
        return IMAP_ACTION_CONTINUE
    if cmd == "SEARCH":
        _search(conn, tag, args, False)
        return IMAP_ACTION_CONTINUE
    if kind == _UNSUPPORTED:
        tagged_no_code(conn, tag, "CANNOT", "This command is not supported")
        return IMAP_ACTION_CONTINUE
    if conn.state == IMAP_STATE_NOTAUTH:
        tagged_no(conn, tag, "Log in first")
        return IMAP_ACTION_CONTINUE

    # Valid once logged in.
    if cmd == "SELECT" or cmd == "EXAMINE":
        handle_select(conn, store, config, tag, args, cmd == "EXAMINE")
        return IMAP_ACTION_CONTINUE
    if cmd == "LIST":
        handle_list(conn, store, tag, args)
        return IMAP_ACTION_CONTINUE

    # Valid once a folder is selected.
    if conn.state != IMAP_STATE_SELECTED:
        tagged_no(conn, tag, "No mailbox is selected")
        return IMAP_ACTION_CONTINUE
    if cmd == "CLOSE":
        handle_close(
            conn, store, config.limits.compact_flag_log_at, tag, args
        )
    elif cmd == "FETCH":
        handle_fetch(conn, store, config, tag, args, False)
    elif cmd == "STORE":
        handle_store(
            conn, store, config.limits.compact_flag_log_at, tag, args, False
        )
    elif cmd == "EXPUNGE":
        handle_expunge(
            conn, store, config.limits.compact_flag_log_at, tag, args
        )
    else:
        # UID <command> <arguments>
        var words = split_word(args)
        var sub = upper_ascii(words.first)
        if sub == "FETCH":
            handle_fetch(conn, store, config, tag, words.rest, True)
        elif sub == "STORE":
            handle_store(
                conn, store, config.limits.compact_flag_log_at, tag, words.rest, True
            )
        elif sub == "SEARCH":
            _search(conn, tag, words.rest, True)
        elif sub == "EXPUNGE" or sub == "COPY" or sub == "MOVE":
            tagged_no_code(
                conn, tag, "CANNOT", "This UID command is not supported"
            )
        else:
            tagged_bad(conn, tag, "Unknown UID command")
    return IMAP_ACTION_CONTINUE


def _search(mut conn: ImapConnection, tag: String, args: String, by_uid: Bool):
    """`SEARCH` and `UID SEARCH`: the one place a later part implements them.
    Until then both are refused, whatever the state."""
    var what = String("This command is not supported")
    if by_uid:
        what = String("This UID command is not supported")
    tagged_no_code(conn, tag, "CANNOT", what)


def _starttls(
    mut conn: ImapConnection,
    config: ImapServerConfig,
    tag: String,
    args: String,
) -> UInt8:
    if args.byte_length() > 0:
        tagged_bad(conn, tag, "STARTTLS takes no arguments")
        return IMAP_ACTION_CONTINUE
    if conn.tls_active:
        tagged_no(conn, tag, "TLS is already active")
        return IMAP_ACTION_CONTINUE
    if not config.offer_starttls:
        tagged_no_code(conn, tag, "CANNOT", "STARTTLS is not available")
        return IMAP_ACTION_CONTINUE
    if conn.state != IMAP_STATE_NOTAUTH:
        tagged_bad(conn, tag, "STARTTLS is only valid before LOGIN")
        return IMAP_ACTION_CONTINUE
    tagged_ok(conn, tag, "Begin TLS negotiation now")
    conn.starttls_pending = True
    return IMAP_ACTION_START_TLS


def _login[
    V: MailAuthVerifier,
](
    mut conn: ImapConnection,
    config: ImapServerConfig,
    verifier: V,
    tag: String,
    args: String,
) -> UInt8:
    """`LOGIN <user> <password>`. Refused on a clear connection when LOGIN
    needs TLS (`NO [PRIVACYREQUIRED]`, before the arguments are looked at and
    without counting as a failure). The credential goes to the verifier and
    nowhere else. A failed attempt is `NO [AUTHENTICATIONFAILED]`; the one
    that reaches `max_login_failures` also ends the connection. On success
    the user's mailbox is the one `normalize_recipient(user)` names, or
    none if the name cannot be one; there is no shared default mailbox."""
    if conn.state != IMAP_STATE_NOTAUTH:
        tagged_bad(conn, tag, "Already logged in")
        return IMAP_ACTION_CONTINUE
    if config.require_tls_for_login and not conn.tls_active:
        tagged_no_code(
            conn, tag, "PRIVACYREQUIRED", "LOGIN is disabled until STARTTLS"
        )
        return IMAP_ACTION_CONTINUE
    var cur = ArgCursor(args)
    var user = cur.next_astring()
    var password = cur.next_astring()
    if not cur.ok or cur.rest().byte_length() > 0:
        tagged_bad(conn, tag, "LOGIN takes a user name and a password")
        return IMAP_ACTION_CONTINUE
    if not verifier.verify(user, password):
        conn.login_failures += 1
        tagged_no_code(
            conn, tag, "AUTHENTICATIONFAILED", "Authentication failed"
        )
        if conn.login_failures >= config.limits.max_login_failures:
            conn.enqueue(String("* BYE Too many failed login attempts\r\n"))
            return IMAP_ACTION_CLOSE
        return IMAP_ACTION_CONTINUE
    var mailbox = String("")
    try:
        _ = normalize_recipient(user)
        mailbox = user
    except:
        mailbox = String("")
    conn.username = user
    conn.mailbox = mailbox
    conn.state = IMAP_STATE_AUTH
    tagged_ok_code(
        conn,
        tag,
        String("CAPABILITY ") + capability_text(config, conn.tls_active),
        "LOGIN completed",
    )
    return IMAP_ACTION_CONTINUE
