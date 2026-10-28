# The DATA phase: message lines, dot-unstuffing, the size cap and the hand-off
# to the delivery.

from .connection import CommandResult, SmtpConnection
from .delivery import MailDelivery, SessionInfo, delivery_reply
from .limits import SmtpServerConfig

comptime _DOT: UInt8 = 0x2E


def session_info(conn: SmtpConnection, config: SmtpServerConfig) -> SessionInfo:
    """The connection as a delivery sees it."""
    return SessionInfo(
        conn.tls_active,
        conn.authed_user,
        config.submission,
        conn.peer,
        conn.helo,
        conn.conn_id,
        conn.declared_size,
        conn.body_8bit,
    )


def handle_data_line[
    D: MailDelivery
](
    mut conn: SmtpConnection,
    config: SmtpServerConfig,
    mut delivery: D,
    now_ms: Int,
) -> CommandResult:
    """Take the CRLF-terminated line `next_frame` found as message text.

    The line `.` alone ends the message: the delivery is called once with the
    dot-unstuffed text and its answer is the reply, and the transaction is
    over whatever the answer. Any other line loses one leading dot (RFC 5321
    section 4.5.2) and, with its CRLF, is added to the message. Past
    `max_message_bytes` nothing more is kept: the lines up to the terminator
    are read and dropped, and the reply is 552. Framing is strict (see
    `SmtpConnection.next_frame`), so a bare LF or CR never ends the message."""
    var start = conn.rx_off
    var end = conn.line_end
    var length = end - start
    if length == 1 and conn.rx[start] == _DOT:
        return _finish(conn, config, delivery, now_ms)
    if length >= 1 and conn.rx[start] == _DOT:
        start += 1
        length -= 1
    if conn.data_overflow:
        return CommandResult(String(""))
    if len(conn.data) + length + 2 > config.limits.max_message_bytes:
        conn.data_overflow = True
        conn.data = List[UInt8]()
        return CommandResult(String(""))
    conn.data.extend(Span(conn.rx)[start:end])
    conn.data.append(UInt8(0x0D))
    conn.data.append(UInt8(0x0A))
    return CommandResult(String(""))


def _finish[
    D: MailDelivery
](
    mut conn: SmtpConnection,
    config: SmtpServerConfig,
    mut delivery: D,
    now_ms: Int,
) -> CommandResult:
    if conn.data_overflow:
        conn.reset_transaction()
        return CommandResult(
            String("552 5.3.4 Message size exceeds fixed maximum\r\n")
        )
    if len(conn.recipients) == 0:
        # DATA is only entered with a recipient; this is a guard.
        conn.reset_transaction()
        return CommandResult(String("554 5.5.0 No valid recipients\r\n"))
    var info = session_info(conn, config)
    var result = delivery.deliver(
        info,
        conn.mail_from,
        conn.recipients,
        Span(conn.data),
        now_ms,
    )
    if result.code == 250:
        conn.messages_accepted += 1
    var reply = delivery_reply(result)
    conn.reset_transaction()
    return CommandResult(reply)
