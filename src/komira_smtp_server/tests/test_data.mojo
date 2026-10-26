# The DATA phase. What each case catches:
# - the message ends only at CRLF, dot, CRLF: a bare LF before the dot, a bare
#   LF after it, a bare CR and a dot line cut by a CR each close the
#   connection after a 500 and deliver nothing (LF-only or lenient framing
#   lets a message end where a stricter relay sees the middle of one);
# - a dot as the first line ends an empty message; a stuffed dot line (`..`)
#   is one dot of message text; one leading dot is removed, never two;
# - after the terminator the next line is a command again;
# - bytes above 0x7F are kept as sent (8BITMIME);
# - past the size cap nothing more is buffered: the lines up to the terminator
#   are dropped, the reply is 552, the delivery is not called, and the next
#   transaction is clean; a message of exactly the cap is delivered;
# - a message line over 1000 bytes with its CRLF closes the connection;
# - every one of those holds when the bytes arrive in pieces of 1, 2, 3 or 4095
#   (a CR at the end of one piece and the LF in the next, a terminator cut in
#   the middle, and the discard to the terminator after the size cap, also
#   with the terminator across the 4096-byte slice boundary);
# - nothing after a failing or discarded message is lost or run: the NOOP
#   after a 552 is answered, the text after a bare LF in the same chunk is
#   not run; a line `. ` or `.x` is text, not the end;
# - the clock value passed to `feed` reaches `deliver`.

from std.testing import assert_equal, assert_false, assert_true

from komira_smtp_server import (
    SMTP_STATE_DATA,
    SMTP_STATE_READY,
    SmtpLimits,
    SmtpServerConfig,
    SmtpTestSession,
)


def _in_data(var config: SmtpServerConfig) raises -> SmtpTestSession:
    var s = SmtpTestSession(config^)
    var r = s.send(
        String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\n")
    )
    assert_true(r.endswith("354 End data with <CR><LF>.<CR><LF>\r\n"))
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_DATA)
    return s^


def _plain() -> SmtpServerConfig:
    return SmtpServerConfig(String("mx.test"))


def _repeat(c: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += c
    return out^


def _expect_closed_undelivered(text: String, size: Int = 0) raises:
    var s = _in_data(_plain())
    var r: String
    if size == 0:
        r = s.send(text)
    else:
        r = s.send_chunks(text, size)
    assert_equal(r, "500 5.5.2 Bare CR or LF in message data, closing\r\n")
    assert_true(s.outcome.closing)
    assert_true(s.reg.is_closing(s.conn_id))
    assert_equal(s.delivery.delivery_count, 0)
    assert_equal(s.reg.data_len(s.conn_id), 0)
    # Nothing more is run on that connection.
    assert_equal(s.send(String("NOOP\r\n.\r\n")), "")
    assert_equal(s.delivery.delivery_count, 0)


def test_terminator_corpus_bare_line_ends_close() raises:
    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(1)
    sizes.append(2)
    sizes.append(3)
    sizes.append(4095)
    for k in range(len(sizes)):
        var n = sizes[k]
        _expect_closed_undelivered(String("a\n.\r\n"), n)  # LF before the dot
        _expect_closed_undelivered(String("a\r\n.\n"), n)  # LF after the dot
        _expect_closed_undelivered(String("a\r.\r\n"), n)  # CR before the dot
        _expect_closed_undelivered(String("a\r\n.\rb\r\n"), n)  # CR, not LF
        _expect_closed_undelivered(String(".\n"), n)  # first line, LF only
        _expect_closed_undelivered(String("\n.\r\n"), n)  # empty line, LF only
        _expect_closed_undelivered(String("a\r\nb\n.\n"), n)  # LF-only message


def test_bare_lf_in_data_runs_nothing_after_it() raises:
    # Same chunk: the terminator after the bad byte must not deliver, and the
    # command text behind it must not run.
    var s = _in_data(_plain())
    var before = len(s.delivery.calls)
    var r = s.send(String("a\nMAIL FROM:<x@y.test>\r\n.\r\nNOOP\r\n"))
    assert_equal(r, "500 5.5.2 Bare CR or LF in message data, closing\r\n")
    assert_true(s.outcome.closing)
    assert_equal(s.delivery.delivery_count, 0)
    assert_equal(len(s.delivery.calls), before)


def test_terminator_corpus_good_ends() raises:
    # A first line "." ends an empty message.
    var s = _in_data(_plain())
    assert_equal(s.send(String(".\r\n")), "250 2.0.0 Ok: queued as q1\r\n")
    assert_equal(s.delivery.delivery_count, 1)
    assert_equal(len(s.delivery.messages[0]), 0)
    # An ordinary message.
    var t = _in_data(_plain())
    assert_equal(
        t.send(String("a\r\n.\r\n")), "250 2.0.0 Ok: queued as q1\r\n"
    )
    assert_equal(t.delivery.message_text(0), "a\r\n")
    assert_equal(t.reg.state_of(t.conn_id), SMTP_STATE_READY)
    # An empty line is a line.
    var e = _in_data(_plain())
    _ = e.send(String("\r\n\r\n.\r\n"))
    assert_equal(e.delivery.message_text(0), "\r\n\r\n")


def test_dot_lines_that_are_not_the_end() raises:
    # A dot followed by anything is text: only the lone dot ends the message.
    var s = _in_data(_plain())
    assert_equal(s.send(String(". \r\n.\r\n")), "250 2.0.0 Ok: queued as q1\r\n")
    assert_equal(s.delivery.message_text(0), " \r\n")
    var t = _in_data(_plain())
    _ = t.send(String(".x\r\n..\r\n.\r\n"))
    assert_equal(t.delivery.message_text(0), "x\r\n.\r\n")
    assert_equal(t.delivery.delivery_count, 1)
    # After a first-line dot the message is over: one delivery, and the next
    # line is a command (here an unknown one).
    var u = _in_data(_plain())
    var r = u.send(String(".\r\nfoo\r\n"))
    assert_equal(u.delivery.delivery_count, 1)
    assert_equal(len(u.delivery.messages[0]), 0)
    assert_equal(r, "250 2.0.0 Ok: queued as q1\r\n500 5.5.1 Command unrecognized\r\n")


def test_good_terminators_in_pieces() raises:
    var sizes = List[Int]()
    sizes.append(1)
    sizes.append(2)
    sizes.append(3)
    for k in range(len(sizes)):
        # A CR at the end of one piece and `\n.\r\n` in the next is the end.
        var s = _in_data(_plain())
        var r = s.send_chunks(String("a\r\n.\r\nNOOP\r\n"), sizes[k])
        assert_equal(r, "250 2.0.0 Ok: queued as q1\r\n250 2.0.0 Ok\r\n")
        assert_equal(s.delivery.message_text(0), "a\r\n")
        var e = _in_data(_plain())
        assert_equal(
            e.send_chunks(String(".\r\n"), sizes[k]), "250 2.0.0 Ok: queued as q1\r\n"
        )
        assert_equal(len(e.delivery.messages[0]), 0)


def test_dot_unstuffing() raises:
    var s = _in_data(_plain())
    _ = s.send(String("..\r\n...\r\n.x\r\n..x\r\nx.\r\n.\r\n"))
    assert_equal(s.delivery.message_text(0), ".\r\n..\r\nx\r\n.x\r\nx.\r\n")
    # A line that is only stuffed dots does not end the message.
    assert_equal(s.delivery.delivery_count, 1)


def test_command_mode_after_the_terminator() raises:
    var s = _in_data(_plain())
    var r = s.send(String("x\r\n.\r\nNOOP\r\nRSET\r\n"))
    assert_equal(
        r, "250 2.0.0 Ok: queued as q1\r\n250 2.0.0 Ok\r\n250 2.0.0 Ok\r\n"
    )
    assert_equal(s.delivery.delivery_count, 1)
    # The transaction is over: a new one starts with MAIL.
    assert_true(s.send(String("DATA\r\n")).startswith("503"))
    assert_equal(s.send(String("MAIL FROM:<a@x.test>\r\n")), "250 2.1.0 Ok\r\n")


def test_eight_bit_bytes_are_kept() raises:
    var s = _in_data(_plain())
    var raw = List[UInt8]()
    raw.append(0xC3)
    raw.append(0xA9)
    raw.append(0xFF)
    raw.append(0x00)
    raw.append(0x0D)
    raw.append(0x0A)
    raw.append(0x2E)
    raw.append(0x0D)
    raw.append(0x0A)
    _ = s.send_bytes(Span(raw))
    assert_equal(s.delivery.delivery_count, 1)
    var m = s.delivery.messages[0].copy()
    assert_equal(len(m), 6)
    assert_equal(Int(m[0]), 0xC3)
    assert_equal(Int(m[1]), 0xA9)
    assert_equal(Int(m[2]), 0xFF)
    assert_equal(Int(m[3]), 0x00)


def test_size_cap_discards_to_the_terminator() raises:
    var limits = SmtpLimits()
    limits.max_message_bytes = 100
    var line = _repeat("x", 8) + "\r\n"  # 10 bytes with the CRLF
    # Exactly the cap is delivered.
    var ok = _in_data(SmtpServerConfig(String("mx.test"), limits=limits))
    var exact = _repeat(line, 10) + ".\r\n"
    assert_equal(ok.send(exact), "250 2.0.0 Ok: queued as q1\r\n")
    assert_equal(len(ok.delivery.messages[0]), 100)
    # One more line is over.
    var over = _in_data(SmtpServerConfig(String("mx.test"), limits=limits))
    var r = over.send(_repeat(line, 10) + "y\r\n.\r\n")
    assert_equal(r, "552 5.3.4 Message size exceeds fixed maximum\r\n")
    assert_equal(over.delivery.delivery_count, 0)
    assert_equal(over.reg.state_of(over.conn_id), SMTP_STATE_READY)
    assert_false(over.outcome.closing)
    # A long stream is read and dropped, with the buffer held at the cap.
    var big = _in_data(SmtpServerConfig(String("mx.test"), limits=limits))
    var long_line = _repeat("z", 48) + "\r\n"
    var peak = 0
    for _ in range(100):
        _ = big.send(_repeat(long_line, 200))
        var held = big.reg.data_len(big.conn_id)
        if held > peak:
            peak = held
    assert_true(peak <= 100)
    assert_equal(big.reg.data_len(big.conn_id), 0)
    assert_true(big.reg.rx_peak(big.conn_id) <= 4096 + 1000 + 2048)
    var done = big.send(String(".\r\n"))
    assert_equal(done, "552 5.3.4 Message size exceeds fixed maximum\r\n")
    assert_equal(big.delivery.delivery_count, 0)
    # The next transaction on that connection is clean and small.
    var next = big.send(
        String("MAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\nok\r\n.\r\n")
    )
    assert_true(next.endswith("250 2.0.0 Ok: queued as q1\r\n"))
    assert_equal(big.delivery.message_text(0), "ok\r\n")


def _small_cap() -> SmtpServerConfig:
    var limits = SmtpLimits()
    limits.max_message_bytes = 100
    return SmtpServerConfig(String("mx.test"), limits=limits)


def test_size_cap_discard_in_pieces() raises:
    var line = _repeat("x", 8) + "\r\n"
    var over = _repeat(line, 10) + "y\r\n" + _repeat(line, 5) + ".\r\nNOOP\r\n"
    var expected = "552 5.3.4 Message size exceeds fixed maximum\r\n250 2.0.0 Ok\r\n"
    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(1)
    sizes.append(2)
    sizes.append(3)
    sizes.append(4095)
    for k in range(len(sizes)):
        var s = _in_data(_small_cap())
        var r: String
        if sizes[k] == 0:
            r = s.send(over)
        else:
            r = s.send_chunks(over, sizes[k])
        # The NOOP behind the discarded message is answered, and nothing was
        # delivered or kept.
        assert_equal(r, expected)
        assert_equal(s.delivery.delivery_count, 0)
        assert_equal(s.reg.data_len(s.conn_id), 0)
        assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
        assert_false(s.outcome.closing)


def test_size_cap_discard_terminator_across_the_slice_boundary() raises:
    # The terminator line `.\r\n` starts at byte 4093 to 4096 of one write, so
    # it is cut by the 4096-byte slice in every possible place.
    var hundred = _repeat("x", 98) + "\r\n"
    for k in range(4):
        var remainder = 4093 + k - 4000
        var text = _repeat(hundred, 40) + _repeat("z", remainder - 2) + "\r\n"
        assert_equal(text.byte_length(), 4093 + k)
        var s = _in_data(_small_cap())
        var r = s.send(text + ".\r\nNOOP\r\n")
        assert_equal(
            r, "552 5.3.4 Message size exceeds fixed maximum\r\n250 2.0.0 Ok\r\n"
        )
        assert_equal(s.delivery.delivery_count, 0)


def test_message_line_cap_is_1000_with_crlf() raises:
    var ok = _in_data(_plain())
    var longest = _repeat("m", 998)
    assert_equal(
        ok.send(longest + "\r\n.\r\n"), "250 2.0.0 Ok: queued as q1\r\n"
    )
    assert_equal(len(ok.delivery.messages[0]), 1000)
    var over = _in_data(_plain())
    var r = over.send(_repeat("m", 999) + "\r\n.\r\n")
    assert_equal(r, "500 5.5.2 Line too long\r\n")
    assert_true(over.outcome.closing)
    assert_equal(over.delivery.delivery_count, 0)
    # A long stream of message text with no line end is bounded too.
    var endless = _in_data(_plain())
    for _ in range(50):
        _ = endless.send(_repeat("m", 3000))
    assert_true(endless.outcome.closing)
    assert_true(endless.reg.rx_peak(endless.conn_id) <= 4096 + 1000)
    assert_equal(endless.delivery.delivery_count, 0)


def test_the_delivery_gets_the_clock() raises:
    var s = _in_data(_plain())
    s.now_ms = 424242
    _ = s.send(String("x\r\n.\r\n"))
    assert_equal(s.delivery.message_now[0], 424242)
    assert_equal(s.delivery.message_from[0], "a@x.test")
    assert_equal(s.delivery.message_helos[0], "c.test")
    assert_equal(s.delivery.message_peers[0], "192.0.2.1")


def main() raises:
    test_terminator_corpus_bare_line_ends_close()
    test_bare_lf_in_data_runs_nothing_after_it()
    test_terminator_corpus_good_ends()
    test_dot_lines_that_are_not_the_end()
    test_good_terminators_in_pieces()
    test_dot_unstuffing()
    test_command_mode_after_the_terminator()
    test_eight_bit_bytes_are_kept()
    test_size_cap_discards_to_the_terminator()
    test_size_cap_discard_in_pieces()
    test_size_cap_discard_terminator_across_the_slice_boundary()
    test_message_line_cap_is_1000_with_crlf()
    test_the_delivery_gets_the_clock()
    print("test_data: OK")
