# Line framing, tags, and the connection table, without a socket. What each
# case catches:
# - the line cap: a stream far larger than `max_line` with no line end closes
#   the connection and the receive buffer never holds more than the cap plus
#   one 4096-byte slice (a cap checked after the line was buffered, or none,
#   fails); the boundary is exact: a line of `max_line` bytes with its CRLF
#   runs, one byte more is refused (a `>=` for `>` fails);
# - literals: a line ending in `{n}` is BAD and nothing of it runs, a line
#   ending in `{n+}` is BAD and ends the connection so the n bytes behind it
#   cannot run as commands; braces anywhere else are not a literal;
# - strict CRLF: a bare LF or a bare CR ends the connection with a `* BYE`,
#   while a CRLF split across two reads is one line (a framer that accepts
#   LF alone, or that cuts a split CRLF in two, fails);
# - input split anywhere and input pipelined give the same replies;
# - tags: a tag with a character the server could not echo safely, an empty
#   one or an over-long one is `* BAD`; a line with a control byte or a byte
#   over 0x7F is `* BAD` and does not reach a parser;
# - the reply queue cap: a peer that pipelines commands and reads nothing is
#   told `* BYE` and closed once the unread replies pass `max_tx_bytes`;
# - the registry: `max_conns` refuses the next connection and a dropped slot
#   is usable again; a thousand connections that hold buffered bytes can be
#   added and dropped (no leak, no double free); a dropped id answers as
#   closed;
# - expiry: `expired_ids` reports a connection one millisecond after
#   `idle_ms`, `max_session_ms` or (before LOGIN) `max_unauth_ms`, not before,
#   whatever the others say, and a logged-in connection is not subject to
#   `max_unauth_ms`.

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import (
    IMAP_STATE_CLOSING,
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
)


def _server(
    limits: ImapLimits = ImapLimits(),
) -> ImapTestServer[SharedInMemoryConditionalStore]:
    var config = ImapServerConfig(
        String("imap.test"), False, True, limits.copy()
    )
    var s = ImapTestServer[SharedInMemoryConditionalStore](
        config^, SharedInMemoryConditionalStore()
    )
    s.add_user(String("alice@example.com"), String("s3cret"))
    return s^


def _spaces(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += String(" ")
    return out^


def test_a_stream_without_a_line_end_is_cut_at_the_cap() raises:
    var limits = ImapLimits()
    limits.max_line = 64
    var s = _server(limits.copy())
    var id = s.connect()
    _ = s.take(id)
    var junk = List[UInt8]()
    for _ in range(1024 * 1024):
        junk.append(UInt8(0x41))
    var outcome = s.feed_bytes(id, Span(junk))
    assert_true(outcome.closing)
    assert_true(s.reg.is_closing(id))
    # Only the first slice was taken; the other megabyte was never read.
    assert_true(outcome.consumed <= 4096)
    assert_equal(s.take(id), "* BYE Command line too long\r\n")
    # The bound the cap gives: its own size plus one slice, never the stream.
    assert_true(s.reg.rx_peak(id) <= 64 + 4096)
    # A closing connection runs nothing more.
    var again = s.feed_bytes(id, String("a1 NOOP\r\n").as_bytes())
    assert_true(again.closing)
    assert_equal(s.take(id), "")


def test_the_line_cap_boundary_is_exact() raises:
    var limits = ImapLimits()
    limits.max_line = 64
    # 62 bytes of line and the CRLF: 64, which is allowed.
    var s = _server(limits.copy())
    var id = s.connect()
    _ = s.take(id)
    var exact = String("a1 NOOP") + _spaces(62 - 7) + "\r\n"
    assert_equal(exact.byte_length(), 64)
    assert_equal(s.send(id, exact), "a1 OK NOOP completed\r\n")
    assert_false(s.reg.is_closing(id))
    # 63 bytes of line: 65 with the CRLF, one too many.
    var s2 = _server(limits.copy())
    var id2 = s2.connect()
    _ = s2.take(id2)
    var over = String("a1 NOOP") + _spaces(63 - 7) + "\r\n"
    assert_equal(over.byte_length(), 65)
    assert_equal(s2.send(id2, over), "* BYE Command line too long\r\n")
    assert_true(s2.reg.is_closing(id2))


def test_a_literal_announcement_is_bad_and_nothing_runs() raises:
    var s = _server()
    var id = s.connect()
    _ = s.login(id, String("alice@example.com"), String("s3cret"))
    # `{5}`: the client waits for `+`; it gets BAD and the connection stays.
    assert_equal(
        s.send(id, String("a1 SELECT {5}\r\n")),
        "a1 BAD [CLIENTBUG] Literals are not supported\r\n",
    )
    assert_false(s.reg.is_closing(id))
    assert_equal(s.reg.pending_rx_bytes(id), 0)
    assert_equal(s.reg.view_count(id), 0)
    assert_equal(
        s.send(id, String("a2 LOGIN {4}\r\n")),
        "a2 BAD [CLIENTBUG] Literals are not supported\r\n",
    )
    # The connection is still usable.
    assert_equal(s.send(id, String("a3 NOOP\r\n")), "a3 OK NOOP completed\r\n")


def test_a_non_synchronizing_literal_ends_the_connection() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    # The 5 bytes of the literal are already on the way, here as a command
    # that would log in. None of it may run.
    var r = s.send(
        id, String("a1 LOGIN {5+}\r\nb1 LOGIN alice@example.com s3cret\r\n")
    )
    assert_equal(
        r,
        "a1 BAD [CLIENTBUG] Literals are not supported\r\n"
        "* BYE Literals are not supported\r\n",
    )
    assert_true(s.reg.is_closing(id))
    assert_equal(s.reg.username_of(id), "")


def test_braces_elsewhere_are_not_a_literal() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    # Not at the end of the line, or not a number: an ordinary (bad) command.
    var r = s.send(id, String("a1 NOOP {5} x\r\n"))
    assert_equal(r, "a1 BAD NOOP takes no arguments\r\n")
    r = s.send(id, String("a2 NOOP {x}\r\n"))
    assert_equal(r, "a2 BAD NOOP takes no arguments\r\n")
    r = s.send(id, String("a3 NOOP {}\r\n"))
    assert_equal(r, "a3 BAD NOOP takes no arguments\r\n")
    assert_false(s.reg.is_closing(id))


def test_a_bare_lf_or_cr_ends_the_connection() raises:
    var texts = List[String]()
    texts.append(String("a1 NOOP\n"))
    texts.append(String("a1 NOOP\ra2 NOOP\r\n"))
    texts.append(String("a1 NOOP\r"))
    for i in range(len(texts)):
        var s = _server()
        var id = s.connect()
        _ = s.take(id)
        var r = s.send(id, texts[i])
        if i == 2:
            # A CR at the end of the data may still be followed by its LF.
            assert_equal(r, "")
            assert_false(s.reg.is_closing(id))
            assert_equal(s.send(id, String("x")), "* BYE Bare CR or LF is not allowed\r\n")
        else:
            assert_equal(r, "* BYE Bare CR or LF is not allowed\r\n")
        assert_true(s.reg.is_closing(id))


def test_a_crlf_split_across_reads_is_one_line() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    assert_equal(s.send(id, String("a1 NOOP\r")), "")
    assert_equal(s.send(id, String("\n")), "a1 OK NOOP completed\r\n")
    assert_false(s.reg.is_closing(id))


def test_split_and_pipelined_input_agree() raises:
    var text = String("a1 CAPABILITY\r\na2 NOOP\r\na3 FOO\r\na4 LOGOUT\r\n")
    var whole = _server()
    var id = whole.connect()
    _ = whole.take(id)
    var expected = whole.send(id, text)
    assert_true(expected.startswith("* CAPABILITY IMAP4rev1 STARTTLS\r\na1 OK CAPABILITY completed\r\n"))
    assert_true(expected.find("a3 BAD Command not recognized\r\n") >= 0)
    assert_true(expected.endswith("* BYE imap.test logging out\r\na4 OK LOGOUT completed\r\n"))
    var sizes = List[Int]()
    sizes.append(1)
    sizes.append(2)
    sizes.append(3)
    sizes.append(7)
    sizes.append(4096)
    for k in range(len(sizes)):
        var s = _server()
        var cid = s.connect()
        _ = s.take(cid)
        assert_equal(s.send_chunks(cid, text, sizes[k]), expected)


def test_bytes_after_logout_are_not_run() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    var r = s.send(id, String("a1 LOGOUT\r\na2 NOOP\r\n"))
    assert_false(r.find("a2") >= 0)
    assert_true(s.reg.is_closing(id))
    assert_equal(s.reg.state_of(id), IMAP_STATE_CLOSING)


def test_bad_tags_are_refused() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    var bad = List[String]()
    bad.append(String(" NOOP\r\n"))  # no tag at all
    bad.append(String("a+b NOOP\r\n"))  # `+` is the continuation marker
    bad.append(String("a\"b NOOP\r\n"))
    bad.append(String("a(b NOOP\r\n"))
    bad.append(String("a{b NOOP\r\n"))
    bad.append(String("a%b NOOP\r\n"))
    bad.append(String("a*b NOOP\r\n"))
    bad.append(String("a\\b NOOP\r\n"))
    bad.append(String("+ NOOP\r\n"))
    bad.append(String("x") * 65 + " NOOP\r\n")
    for i in range(len(bad)):
        var r = s.send(id, bad[i])
        assert_equal(r, "* BAD Missing or invalid tag\r\n")
        assert_false(s.reg.is_closing(id))
    # 64 bytes is the longest tag; `.` `-` `_` and `]` are fine in one.
    var ok_tag = String("x") * 64
    assert_equal(
        s.send(id, ok_tag + " NOOP\r\n"), ok_tag + " OK NOOP completed\r\n"
    )
    assert_equal(
        s.send(id, String("A.b-c_1] NOOP\r\n")), "A.b-c_1] OK NOOP completed\r\n"
    )


def test_a_line_that_is_not_printable_ascii_is_bad() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    var lines = List[List[UInt8]]()
    var tab = List[UInt8]()
    tab.extend(String("a1 NOOP\tx\r\n").as_bytes())
    lines.append(tab^)
    var nul = List[UInt8]()
    nul.extend(String("a1 NO").as_bytes())
    nul.append(UInt8(0))
    nul.extend(String("OP\r\n").as_bytes())
    lines.append(nul^)
    var high = List[UInt8]()
    high.extend(String("a1 SELECT ").as_bytes())
    high.append(UInt8(0xE9))
    high.extend(String("\r\n").as_bytes())
    lines.append(high^)
    var delete_byte = List[UInt8]()
    delete_byte.extend(String("a1 NOOP").as_bytes())
    delete_byte.append(UInt8(0x7F))
    delete_byte.extend(String("\r\n").as_bytes())
    lines.append(delete_byte^)
    for i in range(len(lines)):
        _ = s.feed_bytes(id, Span(lines[i]))
        assert_equal(
            s.take(id),
            "* BAD Command lines are ASCII text without control characters\r\n",
        )
        assert_false(s.reg.is_closing(id))


def test_empty_and_unknown_commands() raises:
    var s = _server()
    var id = s.connect()
    _ = s.take(id)
    assert_equal(s.send(id, String("a1\r\n")), "a1 BAD Missing command\r\n")
    assert_equal(s.send(id, String("\r\n")), "* BAD Missing or invalid tag\r\n")
    assert_equal(
        s.send(id, String("a2 FROBNICATE x\r\n")),
        "a2 BAD Command not recognized\r\n",
    )
    # Commands of IMAP4rev1 that this part does not do are NO, not BAD.
    assert_equal(
        s.send(id, String("a3 SEARCH ALL\r\n")),
        "a3 NO [CANNOT] This command is not supported\r\n",
    )
    assert_equal(
        s.send(id, String("a4 APPEND INBOX\r\n")),
        "a4 NO [CANNOT] This command is not supported\r\n",
    )
    # Command words are not case sensitive.
    assert_equal(s.send(id, String("a5 noop\r\n")), "a5 OK NOOP completed\r\n")
    assert_false(s.reg.is_closing(id))


def test_unread_replies_past_the_cap_close_the_connection() raises:
    var limits = ImapLimits()
    limits.max_tx_bytes = 100
    var s = _server(limits.copy())
    var id = s.connect()
    _ = s.take(id)
    var text = String("")
    for i in range(20):
        text += String("a") + String(i) + " NOOP\r\n"
    var outcome = s.feed_bytes(id, text.as_bytes())
    assert_true(outcome.closing)
    var r = s.take(id)
    assert_true(r.endswith("* BYE Too many unread replies, closing\r\n"))
    # It stopped at the line that passed the cap: not all twenty ran.
    assert_true(outcome.lines < 20)
    assert_true(outcome.lines > 1)


def test_max_conns_refuses_and_a_dropped_slot_is_reusable() raises:
    var limits = ImapLimits()
    limits.max_conns = 2
    var s = _server(limits.copy())
    var a = s.connect()
    var b = s.reg.accept(Int32(8), s.config, s.now_ms)
    assert_true(Bool(b))
    var c = s.reg.accept(Int32(9), s.config, s.now_ms)
    assert_false(Bool(c))
    assert_equal(s.reg.conn_count(), 2)
    assert_equal(s.reg.drop(a), Int32(7))
    assert_false(s.reg.has(a))
    var d = s.reg.accept(Int32(10), s.config, s.now_ms)
    assert_true(Bool(d))
    assert_equal(s.reg.conn_count(), 2)
    # A dropped id is closed to every query.
    assert_true(s.reg.is_closing(a))
    assert_equal(s.reg.state_of(a), IMAP_STATE_CLOSING)
    assert_equal(s.reg.drop(a), Int32(-1))


def test_a_thousand_connections_with_buffered_bytes_come_and_go() raises:
    var limits = ImapLimits()
    limits.max_conns = 100000
    var s = _server(limits.copy())
    var ids = List[Int]()
    for i in range(1000):
        var id = s.reg.accept(Int32(i + 100), s.config, s.now_ms)
        ids.append(id.value())
        # Half a line each, so every connection owns a non-empty buffer.
        _ = s.feed_bytes(ids[i], String("a1 NOO").as_bytes())
    assert_equal(s.reg.conn_count(), 1000)
    for i in range(0, 1000, 2):
        assert_equal(s.reg.drop(ids[i]), Int32(i + 100))
    assert_equal(s.reg.conn_count(), 500)
    for i in range(1000, 1500):
        var id = s.reg.accept(Int32(i + 100), s.config, s.now_ms)
        _ = s.feed_bytes(id.value(), String("a1 NOO").as_bytes())
    assert_equal(s.reg.conn_count(), 1000)
    # What is left still works: the half line is completed.
    var survivor = ids[1]
    _ = s.take(survivor)
    assert_equal(s.send(survivor, String("P\r\n")), "a1 OK NOOP completed\r\n")
    var all = s.reg.all_conn_ids()
    for i in range(len(all)):
        _ = s.reg.drop(all[i])
    assert_equal(s.reg.conn_count(), 0)


def test_expiry_is_strict_and_exact() raises:
    var limits = ImapLimits()
    limits.idle_ms = 1000
    limits.max_session_ms = 5000
    limits.max_unauth_ms = 3000
    var s = _server(limits.copy())
    s.now_ms = 10000
    var id = s.connect()
    # Idle: alive at +1000, expired at +1001.
    assert_equal(len(s.reg.expired_ids(10000 + 1000, s.config)), 0)
    assert_equal(len(s.reg.expired_ids(10000 + 1001, s.config)), 1)
    # Bytes move the idle clock but not the session clock.
    s.now_ms = 10900
    _ = s.send(id, String("a1 NOOP\r\n"))
    assert_equal(len(s.reg.expired_ids(10900 + 1000, s.config)), 0)
    assert_equal(len(s.reg.expired_ids(10900 + 1001, s.config)), 1)
    # Before LOGIN the connection may live max_unauth_ms from its accept,
    # however often it sends: alive at accept+3000, expired at +3001.
    s.now_ms = 12500
    _ = s.send(id, String("a2 NOOP\r\n"))
    assert_equal(len(s.reg.expired_ids(13000, s.config)), 0)
    assert_equal(len(s.reg.expired_ids(13001, s.config)), 1)
    # After LOGIN that limit no longer applies; the session limit does:
    # alive at accept+5000, expired at +5001, though it sent a moment ago.
    _ = s.send(id, String("a3 LOGIN alice@example.com s3cret\r\n"))
    s.now_ms = 14500
    _ = s.send(id, String("a4 NOOP\r\n"))
    assert_equal(len(s.reg.expired_ids(14500 + 500, s.config)), 0)
    assert_equal(len(s.reg.expired_ids(15001 - 1, s.config)), 0)
    assert_equal(len(s.reg.expired_ids(15001, s.config)), 1)
    # A zero turns the session and the unauthenticated limits off.
    var off = ImapLimits()
    off.idle_ms = 1000
    off.max_session_ms = 0
    off.max_unauth_ms = 0
    var t = _server(off.copy())
    t.now_ms = 0
    var tid = t.connect()
    t.now_ms = 900
    _ = t.send(tid, String("a1 NOOP\r\n"))
    assert_equal(len(t.reg.expired_ids(900 + 1000, t.config)), 0)


def main() raises:
    test_a_stream_without_a_line_end_is_cut_at_the_cap()
    test_the_line_cap_boundary_is_exact()
    test_a_literal_announcement_is_bad_and_nothing_runs()
    test_a_non_synchronizing_literal_ends_the_connection()
    test_braces_elsewhere_are_not_a_literal()
    test_a_bare_lf_or_cr_ends_the_connection()
    test_a_crlf_split_across_reads_is_one_line()
    test_split_and_pipelined_input_agree()
    test_bytes_after_logout_are_not_run()
    test_bad_tags_are_refused()
    test_a_line_that_is_not_printable_ascii_is_bad()
    test_empty_and_unknown_commands()
    test_unread_replies_past_the_cap_close_the_connection()
    test_max_conns_refuses_and_a_dropped_slot_is_reusable()
    test_a_thousand_connections_with_buffered_bytes_come_and_go()
    test_expiry_is_strict_and_exact()
    print("test_framing: OK")
