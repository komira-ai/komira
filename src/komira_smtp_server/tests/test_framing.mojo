# Line framing and the connection table. What each case catches:
# - a command line of exactly 512 bytes (CRLF included) is run and one byte
#   more is answered 500 and closes (a cap off by one either way, or no cap);
# - a stream of megabytes with no line end keeps the receive buffer within a
#   constant (a buffer that grows with the stream, or a cap checked after the
#   whole read was buffered);
# - a bare LF or bare CR in a command is answered 500 5.5.2 and the rest of
#   that line is dropped, so a command hidden behind it never runs (LF-only
#   framing, or resuming at the byte after the bad one);
# - a CR at the end of one read and the LF at the start of the next make one
#   line, and the same script gives the same replies whatever the chunking;
# - tens of thousands of pipelined lines move bytes in the buffer only in
#   proportion to the bytes received (a rebuild of the buffer per line);
# - a thousand connections added and dropped, with buffered bytes, leave the
#   survivors' data intact and are dropped exactly once (the heap buffers of a
#   connection in the table);
# - bare LF and CR lines pay for their reply: a stream of them is cut off by
#   the reply-queue cap and the command cap like any other command (a cheap
#   input that earns a larger reply, with no limit on the queue);
# - the reply queue of a slow reader is compacted at a cost proportional to
#   the bytes written (a compaction on every small write);
# - the connection limit, the idle list, the session and DATA deadlines (a peer
#   that sends one byte at a time is never idle, but it is reported) and the
#   reply-queue cap.

from std.testing import assert_equal, assert_false, assert_true

from komira_smtp_server import (
    SMTP_STATE_GREETED,
    SMTP_STATE_READY,
    SmtpLimits,
    SmtpServerConfig,
    SmtpTestSession,
)


def _session() -> SmtpTestSession:
    return SmtpTestSession(SmtpServerConfig(String("mx.test")))


def _repeat(c: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += c
    return out^


def test_greeting() raises:
    var s = _session()
    assert_equal(s.greeting, "220 mx.test ESMTP ready\r\n")


def test_command_line_cap_is_512_with_crlf() raises:
    # "NOOP " + padding: 510 content bytes + CRLF = 512, the longest allowed.
    var ok = _session()
    var line = String("NOOP ") + _repeat("x", 505)
    assert_equal(line.byte_length(), 510)
    assert_equal(ok.send(line + "\r\n"), "250 2.0.0 Ok\r\n")
    assert_false(ok.outcome.closing)
    # One more byte: 513 with the CRLF.
    var over = _session()
    var long = String("NOOP ") + _repeat("x", 506)
    assert_equal(over.send(long + "\r\n"), "500 5.5.2 Line too long\r\n")
    assert_true(over.outcome.closing)
    assert_true(over.reg.is_closing(over.conn_id))
    # The same boundary when the bytes come one at a time.
    var slow = _session()
    assert_equal(slow.send_chunks(line + "\r\n", 1), "250 2.0.0 Ok\r\n")
    var slow_over = _session()
    assert_equal(
        slow_over.send_chunks(long + "\r\n", 1), "500 5.5.2 Line too long\r\n"
    )


def test_stream_without_line_end_is_bounded() raises:
    var s = _session()
    var chunk = _repeat("a", 1000)
    var replies = String("")
    for _ in range(300):
        replies += s.send(chunk)
    assert_equal(replies, "500 5.5.2 Line too long\r\n")
    assert_true(s.outcome.closing)
    assert_true(s.reg.rx_peak(s.conn_id) <= 512 + 4096)
    assert_equal(s.reg.pending_rx_bytes(s.conn_id), 0)
    # One enormous read is cut into slices as well.
    var big = _session()
    var megabyte = _repeat(chunk, 1000)
    assert_equal(megabyte.byte_length(), 1000000)
    assert_equal(big.send(megabyte), "500 5.5.2 Line too long\r\n")
    assert_true(big.reg.rx_peak(big.conn_id) <= 512 + 4096)
    assert_true(big.outcome.consumed < 1000000)
    # A closed connection takes nothing more.
    assert_equal(big.send(String("NOOP\r\n")), "")
    assert_true(big.outcome.closing)


def test_bare_lf_in_command() raises:
    var s = _session()
    _ = s.send(String("EHLO c.test\r\n"))
    # The LF hides a second command behind it: nothing of the line runs.
    var r = s.send(String("MAIL FROM:<a@x.test>\nRCPT TO:<b@y.test>\r\n"))
    assert_equal(r, "500 5.5.2 Bare CR or LF is not allowed\r\n")
    assert_false(s.outcome.closing)
    assert_equal(s.reg.state_of(s.conn_id), SMTP_STATE_READY)
    assert_equal(s.reg.mail_from_of(s.conn_id), "")
    assert_equal(len(s.delivery.calls), 0)
    # The connection carries on with the next proper line.
    assert_equal(s.send(String("NOOP\r\n")), "250 2.0.0 Ok\r\n")


def test_bare_cr_in_command() raises:
    var s = _session()
    _ = s.send(String("EHLO c.test\r\n"))
    var r = s.send(String("NOOP\rRSET\r\nNOOP\r\n"))
    assert_equal(
        r, "500 5.5.2 Bare CR or LF is not allowed\r\n250 2.0.0 Ok\r\n"
    )
    assert_false(s.outcome.closing)
    # The skipped line may arrive over several reads.
    var t = _session()
    _ = t.send(String("EHLO c.test\r\n"))
    var first = t.send(String("MAIL\nFROM:<a@x.test"))
    assert_equal(first, "500 5.5.2 Bare CR or LF is not allowed\r\n")
    assert_equal(t.send(String(">\r")), "")
    assert_equal(t.send(String("\nNOOP\r\n")), "250 2.0.0 Ok\r\n")
    assert_equal(t.reg.mail_from_of(t.conn_id), "")


def test_cr_and_lf_in_separate_reads() raises:
    var s = _session()
    assert_equal(s.send(String("NOOP\r")), "")
    assert_equal(s.send(String("\n")), "250 2.0.0 Ok\r\n")


def _script() -> String:
    return (
        String("EHLO c.test\r\n")
        + "MAIL FROM:<a@x.test>\r\n"
        + "RCPT TO:<b@y.test>\r\n"
        + "RCPT TO:<c@y.test>\r\n"
        + "DATA\r\n"
        + "Subject: hi\r\n\r\n.dotted\r\n..\r\nbody\r\n.\r\n"
        + "NOOP\r\n"
        + "QUIT\r\n"
    )


def test_chunking_does_not_change_the_replies() raises:
    var whole = _session()
    var expected = whole.send(_script())
    assert_true(expected.byte_length() > 100)
    assert_equal(whole.delivery.delivery_count, 1)
    assert_equal(
        whole.delivery.message_text(0), "Subject: hi\r\n\r\ndotted\r\n.\r\nbody\r\n"
    )
    var sizes = List[Int]()
    sizes.append(1)
    sizes.append(2)
    sizes.append(3)
    sizes.append(7)
    sizes.append(64)
    sizes.append(5000)
    for k in range(len(sizes)):
        var s = _session()
        var got = s.send_chunks(_script(), sizes[k])
        assert_equal(got, expected)
        assert_equal(s.delivery.delivery_count, 1)
        assert_equal(
            s.delivery.message_text(0),
            "Subject: hi\r\n\r\ndotted\r\n.\r\nbody\r\n",
        )
        assert_true(s.reg.is_closing(s.conn_id))


def test_pipelined_commands_answer_in_order() raises:
    var s = _session()
    var r = s.send(_script())
    assert_true(r.startswith("250-mx.test greets you\r\n"))
    assert_true(r.endswith("250 2.0.0 Ok\r\n221 2.0.0 mx.test closing connection\r\n"))
    assert_true(s.outcome.closing)
    assert_equal(s.reg.messages_accepted_of(s.conn_id), 1)


def test_receive_buffer_cost_is_linear() raises:
    var limits = SmtpLimits()
    limits.max_commands = 10000000
    limits.max_tx_bytes = 100000000
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    var script = String("")
    for _ in range(30000):
        script += "NOOP\r\n"
    var fed = script.byte_length()
    assert_equal(fed, 180000)
    var r = s.send(script)
    assert_equal(r.byte_length(), 30000 * 14)
    assert_true(s.reg.rx_moved(s.conn_id) <= fed)
    assert_true(s.reg.rx_peak(s.conn_id) <= 4096 + 2048 + 512)


def test_table_lifetime_churn() raises:
    var config = SmtpServerConfig(String("mx.test"))
    var s = SmtpTestSession(config.copy())
    var reg = s.reg.conn_count()
    assert_equal(reg, 1)
    # Five survivors, each holding a different partial line.
    var ids = List[Int]()
    for i in range(5):
        var id = s.reg.accept(Int32(10 + i), config, 1000, String("p") + String(i))
        ids.append(id.value())
        var part = String("MAIL FROM:<u") + String(i) + "@x.test"
        _ = s.reg.feed(
            id.value(),
            part.as_bytes(),
            config,
            s.verifier,
            s.delivery,
            1000,
        )
    # A thousand short-lived connections come and go in between.
    for r in range(1000):
        var id = s.reg.accept(Int32(100), config, 1000)
        var junk = String("RCPT TO:<churn") + String(r) + "@x.test"
        _ = s.reg.feed(
            id.value(), junk.as_bytes(), config, s.verifier, s.delivery, 1000
        )
        assert_equal(s.reg.drop(id.value()), Int32(100))
        if r == 400:
            # A survivor leaves from the middle of the table.
            assert_equal(s.reg.drop(ids[2]), Int32(12))
    assert_equal(s.reg.conn_count(), 5)  # the session's and four survivors
    assert_false(s.reg.has(ids[2]))
    assert_equal(s.reg.drop(ids[2]), Int32(-1))
    for i in range(5):
        if i == 2:
            continue
        assert_true(s.reg.has(ids[i]))
        assert_equal(s.reg.fd_of(ids[i]), Int32(10 + i))
        var rest = String(">\r\n")
        _ = s.reg.feed(
            ids[i], rest.as_bytes(), config, s.verifier, s.delivery, 1000
        )
        # The state machine answers the line it was holding: MAIL before
        # EHLO is out of sequence, which shows the bytes survived intact.
        var out = s.reg.tx_copy(ids[i], 4096)
        assert_equal(
            String(unsafe_from_utf8=Span(out)),
            "220 mx.test ESMTP ready\r\n503 5.5.1 Bad sequence of commands\r\n",
        )
        assert_equal(s.reg.state_of(ids[i]), SMTP_STATE_GREETED)


def test_connection_limit() raises:
    var limits = SmtpLimits()
    limits.max_conns = 2
    var config = SmtpServerConfig(String("mx.test"), limits=limits)
    var s = SmtpTestSession(config.copy())
    var second = s.reg.accept(Int32(8), config, 1000)
    assert_true(Bool(second))
    assert_false(Bool(s.reg.accept(Int32(9), config, 1000)))
    assert_equal(s.reg.conn_count(), 2)
    _ = s.reg.drop(second.value())
    assert_true(Bool(s.reg.accept(Int32(9), config, 1000)))


def test_idle_connections() raises:
    var limits = SmtpLimits()
    limits.idle_ms = 500
    var config = SmtpServerConfig(String("mx.test"), limits=limits)
    var s = SmtpTestSession(config.copy())
    assert_equal(len(s.reg.idle_ids(1500, 500)), 0)
    var idle = s.reg.idle_ids(1501, 500)
    assert_equal(len(idle), 1)
    assert_equal(idle[0], s.conn_id)
    s.now_ms = 1400
    _ = s.send(String("NOOP\r\n"))
    assert_equal(len(s.reg.idle_ids(1900, 500)), 0)
    assert_equal(len(s.reg.idle_ids(1901, 500)), 1)


def test_unread_replies_are_capped() raises:
    var limits = SmtpLimits()
    limits.max_tx_bytes = 100
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    var script = String("")
    for _ in range(50):
        script += "NOOP\r\n"
    var r = s.send(script)
    assert_true(r.endswith("421 4.7.0 Too many unread replies, closing\r\n"))
    assert_true(s.outcome.closing)
    assert_true(r.byte_length() < 50 * 14)


def test_bare_lines_are_capped_by_the_reply_queue() raises:
    var limits = SmtpLimits()
    limits.max_tx_bytes = 100
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    var script = String("")
    for _ in range(50):
        script += "\n\r\n"
    assert_equal(script.byte_length(), 150)
    var r = s.send(script)
    assert_true(r.endswith("421 4.7.0 Too many unread replies, closing\r\n"))
    assert_true(s.outcome.closing)
    assert_true(r.byte_length() < 10 * 38)
    # A peer that never reads: the queue stays bounded across many feeds.
    var t = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    for _ in range(200):
        _ = t.reg.feed(
            t.conn_id, script.as_bytes(), t.config, t.verifier, t.delivery, 1000
        )
    assert_true(t.reg.is_closing(t.conn_id))
    assert_true(t.reg.tx_len(t.conn_id) < 100 + 38 + 60)


def test_bare_lines_count_as_commands() raises:
    var limits = SmtpLimits()
    limits.max_commands = 5
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    var script = String("")
    for _ in range(10):
        script += "\n\r\n"
    var r = s.send(script)
    assert_true(r.endswith("421 4.7.0 Too many commands, closing\r\n"))
    assert_true(s.outcome.closing)
    var bare = String("500 5.5.2 Bare CR or LF is not allowed\r\n")
    # The sixth line is the one over the cap: its own 500, then the 421.
    assert_equal(r.find("421"), 6 * bare.byte_length())


def test_reply_queue_compaction_cost_is_linear() raises:
    var limits = SmtpLimits()
    limits.max_commands = 10000000
    limits.max_tx_bytes = 100000000
    var s = SmtpTestSession(SmtpServerConfig(String("mx.test"), limits=limits))
    var script = String("")
    for _ in range(20000):
        script += "NOOP\r\n"
    _ = s.reg.feed(
        s.conn_id, script.as_bytes(), s.config, s.verifier, s.delivery, 1000
    )
    var queued = s.reg.tx_len(s.conn_id)
    assert_equal(queued, 20000 * 14)
    # A writer takes 3000 bytes at a time from the long queue.
    var written = 0
    while s.reg.tx_len(s.conn_id) > 0:
        var part = s.reg.tx_copy(s.conn_id, 3000)
        written += len(part)
        s.reg.tx_consume(s.conn_id, len(part))
    assert_equal(written, queued)
    assert_true(s.reg.tx_moved(s.conn_id) <= queued)


def test_session_and_data_deadlines() raises:
    var limits = SmtpLimits()
    limits.idle_ms = 500
    limits.max_session_ms = 3000
    limits.max_data_ms = 1000
    var config = SmtpServerConfig(String("mx.test"), limits=limits)
    # One byte every 100 ms: never idle, but the session runs out.
    var s = SmtpTestSession(config.copy())
    var t = 1000
    for _ in range(30):
        t += 100
        s.now_ms = t
        _ = s.send(String("N"))
        assert_equal(len(s.reg.idle_ids(t, 500)), 0)
    assert_equal(t, 4000)
    assert_equal(len(s.reg.expired_ids(4000, config)), 0)
    assert_equal(len(s.reg.expired_ids(4001, config)), 1)
    assert_equal(s.reg.expired_ids(4001, config)[0], s.conn_id)
    # A quiet connection is expired by the idle time alone.
    var q = SmtpTestSession(config.copy())
    assert_equal(len(q.reg.expired_ids(1500, config)), 0)
    assert_equal(len(q.reg.expired_ids(1501, config)), 1)
    # In DATA a slow trickle is cut at max_data_ms, not before.
    var d = SmtpTestSession(config.copy())
    d.now_ms = 1100
    _ = d.send(
        String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\n")
    )
    for k in range(1, 10):
        d.now_ms = 1100 + k * 100
        _ = d.send(String("x"))
        assert_equal(len(d.reg.expired_ids(d.now_ms, config)), 0)
    assert_equal(len(d.reg.expired_ids(2101, config)), 1)
    # The time in DATA starts at DATA, not at the connection.
    var late = SmtpTestSession(config.copy())
    late.now_ms = 2500
    _ = late.send(
        String("EHLO c.test\r\nMAIL FROM:<a@x.test>\r\nRCPT TO:<b@y.test>\r\nDATA\r\n")
    )
    assert_equal(len(late.reg.expired_ids(2900, config)), 0)
    # A limit of 0 turns the deadline off.
    var off = limits.copy()
    off.max_session_ms = 0
    off.max_data_ms = 0
    off.idle_ms = 100000000
    var off_cfg = SmtpServerConfig(String("mx.test"), limits=off)
    assert_equal(len(s.reg.expired_ids(99999999, off_cfg)), 0)


def main() raises:
    test_greeting()
    test_command_line_cap_is_512_with_crlf()
    test_stream_without_line_end_is_bounded()
    test_bare_lf_in_command()
    test_bare_cr_in_command()
    test_cr_and_lf_in_separate_reads()
    test_chunking_does_not_change_the_replies()
    test_pipelined_commands_answer_in_order()
    test_receive_buffer_cost_is_linear()
    test_table_lifetime_churn()
    test_connection_limit()
    test_idle_connections()
    test_unread_replies_are_capped()
    test_bare_lines_are_capped_by_the_reply_queue()
    test_bare_lines_count_as_commands()
    test_reply_queue_compaction_cost_is_linear()
    test_session_and_data_deadlines()
    print("test_framing: OK")
