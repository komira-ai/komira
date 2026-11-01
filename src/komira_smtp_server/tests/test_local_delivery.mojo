# LocalMailboxDelivery against an in-memory store, no sockets. What each case
# catches:
# - the RCPT rule: local domains match without regard to case and trailing
#   dot, address literals normalise, a lookalike domain, a suffix, a missing
#   domain and an empty list are refused 550 5.1.1, and the bare postmaster is
#   accepted only when a domain exists and lands in postmaster@<first domain>
#   (an accept-everything rule, a suffix match or a case-sensitive match fails);
# - the store happens before the hook: when the hook runs, the message is
#   already listed in the recipient's mailbox (a hook fired first fails);
# - a raising hook leaves the 250 and the message stored;
# - a store error is a 451, never raised, and the copies this delivery had
#   already written are removed, with no hook call (a 250 over a lost copy,
#   a leftover copy, or an escaping error fails);
# - two byte-identical deliveries are two messages (content addressing alone
#   would merge them);
# - the hook fires exactly once per recipient stored: two spellings of one
#   mailbox are one copy and one call, a recipient that is not local at DATA
#   time is a 554 with nothing stored and no call;
# - the trace headers are exact: Return-Path (also the null path), Received
#   with ESMTP, ESMTPS and ESMTPSA, the date from now_ms, the queue id, and
#   Authentication-Results;
# - a path cannot leave its brackets (`>` `;` `(` `)` `"` `\\` and space);
# - a sender's own Return-Path and Authentication-Results header fields are
#   renamed X-Original-... (any case, folded lines kept), the body untouched,
#   so ours is the only one of each (a delivery that only prepends fails);
# - header escaping: CR, LF, quotes and parentheses in the EHLO name, the peer
#   text, the verified user and the sender cannot add a header line or end a
#   quoted string or a comment.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_store import fetch_message, list_folder
from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_smtp_server import (
    LocalDomains,
    LocalMailboxDelivery,
    MailReceiveHook,
    NoopMailReceiveHook,
    SessionInfo,
    trace_headers,
)

comptime _NOW: Int = 1_790_000_000_000  # Mon, 21 Sep 2026 14:13:20 +0000


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _domains() -> LocalDomains:
    var d = LocalDomains()
    d.add(String("Example.COM"))
    d.add(String("[IPv6:2001:DB8::1]"))
    return d^


def _session(
    tls: Bool = False,
    user: String = "",
    helo: String = "client.test",
    peer: String = "192.0.2.9",
) -> SessionInfo:
    return SessionInfo(tls, user, False, peer, helo, 3)


struct _SeenHook(MailReceiveHook):
    """Records each call and what the mailbox held when it was made."""

    var view: SharedInMemoryConditionalStore
    var recipients: List[String]
    var counts_at_call: List[Int]
    var first_bytes: List[String]
    var fail: Bool

    def __init__(out self, var view: SharedInMemoryConditionalStore, fail: Bool = False):
        self.view = view^
        self.recipients = List[String]()
        self.counts_at_call = List[Int]()
        self.first_bytes = List[String]()
        self.fail = fail

    def on_message_stored(
        mut self, recipient: String, raw_bytes: List[UInt8]
    ) raises:
        self.recipients.append(recipient)
        self.counts_at_call.append(
            len(list_folder(self.view, recipient, String("INBOX")))
        )
        self.first_bytes.append(String(unsafe_from_utf8=Span(raw_bytes)[0:12]))
        if self.fail:
            raise Error("hook failed")


struct _FailStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """An in-memory store whose writes fail for a key holding `marker`."""

    var inner: SharedInMemoryConditionalStore
    var marker: String

    def __init__(out self, var inner: SharedInMemoryConditionalStore, marker: String):
        self.inner = inner^
        self.marker = marker

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if path.raw().find(self.marker) >= 0:
            raise Error("StoreError[TRANSPORT] put mem://bucket/ status=503")
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _only_message(mut view: SharedInMemoryConditionalStore, box: String) raises -> String:
    """The one message in `box`'s INBOX as text."""
    var entries = list_folder(view, box, String("INBOX"))
    assert_equal(len(entries), 1)
    var got = fetch_message(view, box, String("INBOX"), entries[0].leaf)
    return String(unsafe_from_utf8=Span(got.bytes))


def _count(mut view: SharedInMemoryConditionalStore, box: String) raises -> Int:
    return len(list_folder(view, box, String("INBOX")))


def _delivery(
    var store: SharedInMemoryConditionalStore,
    var view: SharedInMemoryConditionalStore,
    fail_hook: Bool = False,
) -> LocalMailboxDelivery[SharedInMemoryConditionalStore, _SeenHook]:
    return LocalMailboxDelivery[SharedInMemoryConditionalStore, _SeenHook](
        store^,
        _SeenHook(view^, fail_hook),
        String("mx.example.com"),
        _domains(),
    )


def test_rcpt_rule() raises:
    var store = SharedInMemoryConditionalStore()
    var d = _delivery(store.clone(), store.clone())
    var s = _session()
    var accepted = List[String]()
    accepted.append("bob@example.com")
    accepted.append("Bob@EXAMPLE.COM")
    accepted.append("bob@example.com.")
    accepted.append("bob@[ipv6:2001:db8::1]")
    accepted.append("bob@[IPV6:2001:DB8::1]")
    accepted.append("postmaster")
    accepted.append("PostMaster")
    accepted.append("postmaster@example.com")
    for i in range(len(accepted)):
        var r = d.accept_recipient(s, String("a@b.test"), accepted[i])
        assert_equal(r.code, 0, accepted[i])
    var refused = List[String]()
    refused.append("bob@other.test")
    refused.append("bob@example.com.evil.test")
    refused.append(String("bob@not") + "example.com")  # a suffix, not a subdomain
    refused.append("bob@sub.example.com")
    refused.append("bob@example.org")
    refused.append("bob")
    refused.append("@example.com")
    refused.append("bob@")
    refused.append("bob@[ipv6:2001:db8::2]")
    for i in range(len(refused)):
        var r = d.accept_recipient(s, String("a@b.test"), refused[i])
        assert_equal(r.code, 550, refused[i])
        assert_true(r.text.startswith("5.1.1"), refused[i])

    # No local domain at all: nothing is ours, the postmaster included.
    var empty = LocalMailboxDelivery[SharedInMemoryConditionalStore, NoopMailReceiveHook](
        store.clone(), NoopMailReceiveHook(), String("mx"), LocalDomains()
    )
    assert_equal(empty.accept_recipient(s, String(""), String("postmaster")).code, 550)
    assert_equal(empty.accept_recipient(s, String(""), String("a@example.com")).code, 550)


def test_postmaster_lands_in_the_first_domain() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("PostMaster")
    var msg = _bytes("Subject: x\r\n\r\nbody\r\n")
    var r = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    assert_equal(_count(view, "postmaster@example.com"), 1)


def test_store_happens_before_the_hook() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    rcpts.append("carol@example.com")
    var msg = _bytes("Subject: x\r\n\r\nbody\r\n")
    var r = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    assert_equal(len(d.hook.recipients), 2)
    # When the hook ran the recipient's message was already there.
    assert_equal(d.hook.counts_at_call[0], 1)
    assert_equal(d.hook.counts_at_call[1], 1)
    assert_equal(d.hook.recipients[0], "bob@example.com")
    assert_equal(d.hook.recipients[1], "carol@example.com")
    # The hook saw the bytes as stored: trace headers first.
    assert_equal(d.hook.first_bytes[0], "Return-Path:")


def test_a_raising_hook_leaves_the_250() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone(), True)
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    rcpts.append("carol@example.com")
    var msg = _bytes("body\r\n")
    var r = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    assert_true(r.text.byte_length() > 0)
    # Both hook calls happened (a raise does not stop the next recipient) and
    # both messages are stored.
    assert_equal(len(d.hook.recipients), 2)
    assert_equal(_count(view, "bob@example.com"), 1)
    assert_equal(_count(view, "carol@example.com"), 1)


def test_a_store_error_is_451_and_undoes_the_delivery() raises:
    var inner = SharedInMemoryConditionalStore()
    var view = inner.clone()
    var d = LocalMailboxDelivery[_FailStore, _SeenHook](
        _FailStore(inner.clone(), String("badbox")),
        _SeenHook(inner.clone()),
        String("mx.example.com"),
        _domains(),
    )
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    rcpts.append("badbox@example.com")
    var msg = _bytes("body\r\n")
    var r = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 451)
    assert_true(r.text.startswith("4."))
    # All or nothing: bob's copy, written first, is gone; no hook call.
    assert_equal(_count(view, "bob@example.com"), 0)
    assert_equal(len(d.hook.recipients), 0)
    # The same mail to the healthy mailbox alone works.
    var ok = List[String]()
    ok.append("bob@example.com")
    assert_equal(d.deliver(_session(), String("a@b.test"), ok, Span(msg), _NOW).code, 250)
    assert_equal(_count(view, "bob@example.com"), 1)


def test_identical_deliveries_make_two_messages() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    var msg = _bytes("Subject: same\r\n\r\nsame body\r\n")
    var a = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    var b = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(a.code, 250)
    assert_equal(b.code, 250)
    assert_true(a.text != b.text)
    var entries = list_folder(view, String("bob@example.com"), String("INBOX"))
    assert_equal(len(entries), 2)
    assert_true(entries[0].leaf != entries[1].leaf)
    # The hook was told twice.
    assert_equal(len(d.hook.recipients), 2)


def test_the_hook_fires_for_exactly_the_recipients_stored() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    rcpts.append("BOB@Example.COM")
    rcpts.append("carol@example.com")
    var msg = _bytes("body\r\n")
    assert_equal(
        d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW).code, 250
    )
    # Two spellings of one mailbox: one copy, one call.
    assert_equal(_count(view, "bob@example.com"), 1)
    assert_equal(_count(view, "carol@example.com"), 1)
    assert_equal(len(d.hook.recipients), 2)

    # A recipient that is not local at DATA time refuses the whole message.
    var mixed = List[String]()
    mixed.append("dave@example.com")
    mixed.append("eve@elsewhere.test")
    var r = d.deliver(_session(), String("a@b.test"), mixed, Span(msg), _NOW)
    assert_equal(r.code, 554)
    assert_equal(_count(view, "dave@example.com"), 0)
    assert_equal(len(d.hook.recipients), 2)

    # No recipients at all.
    var none = List[String]()
    assert_equal(
        d.deliver(_session(), String("a@b.test"), none, Span(msg), _NOW).code, 554
    )


def test_trace_headers_are_exact() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    var msg = _bytes("Subject: hi\r\n\r\nHello\r\n")
    var r = d.deliver(_session(), String("a@sender.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    assert_equal(r.text, "q1790000000000-3-1")
    var want = String(
        "Return-Path: <a@sender.test>\r\n"
        "Received: from client.test (192.0.2.9)\r\n"
        "\tby mx.example.com with ESMTP id q1790000000000-3-1\r\n"
        "\tfor <bob@example.com>; Mon, 21 Sep 2026 14:13:20 +0000\r\n"
        "Authentication-Results: mx.example.com; none\r\n"
        "Subject: hi\r\n\r\nHello\r\n"
    )
    assert_equal(_only_message(view, "bob@example.com"), want)

    # The null reverse-path, TLS, and a verified user.
    var h = trace_headers(
        String(""),
        String("c.test"),
        String("192.0.2.1"),
        String("alice"),
        True,
        String("mx.example.com"),
        String("q9"),
        String("bob@example.com"),
        _NOW,
    )
    assert_equal(
        h,
        String(
            "Return-Path: <>\r\n"
            "Received: from c.test (192.0.2.1)\r\n"
            '\tby mx.example.com with ESMTPSA (authenticated as "alice") id q9\r\n'
            "\tfor <bob@example.com>; Mon, 21 Sep 2026 14:13:20 +0000\r\n"
            "Authentication-Results: mx.example.com; none\r\n"
        ),
    )
    var tls_only = trace_headers(
        String("a@b.test"), String("c.test"), String("p"), String(""), True,
        String("h"), String("q"), String("r@h"), _NOW,
    )
    assert_true(tls_only.find("with ESMTPS id q") >= 0)


def test_peer_text_cannot_add_a_header() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    var msg = _bytes("BODYSTART\r\n")
    var s = _session(
        True,
        String('al"ice\r\nX-Inject: 1'),
        String("evil\r\nBcc: x@y"),
        String("1.2.3.4) \r\nX: y("),
    )
    var r = d.deliver(s, String("a@b>\r\nX-Sender: 1"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    var text = _only_message(view, "bob@example.com")
    var cut = text.find("BODYSTART")
    assert_true(cut > 0)
    var head = String(unsafe_from_utf8=text.as_bytes()[0:cut])
    # Return-Path, three Received lines, Authentication-Results: nothing else.
    var lines = 0
    for b in head.as_bytes():
        if b == 0x0A:
            lines += 1
    assert_equal(lines, 5)
    assert_false(head.find("\r\nBcc") >= 0)
    assert_false(head.find("\r\nX-Inject") >= 0)
    assert_false(head.find("\r\nX-Sender") >= 0)
    assert_false(head.find("\r\nX:") >= 0)
    # What the peer said is still there, neutralised.
    assert_true(head.find("from evil??Bcc:?x?y (") >= 0)
    assert_true(head.find('(authenticated as "al\\"ice??X-Inject: 1")') >= 0)
    assert_true(head.find("(1.2.3.4? ??X: y?)") >= 0)
    assert_true(head.find("Return-Path: <a@b???X-Sender:?1>") >= 0)


def test_a_path_cannot_leave_its_brackets() raises:
    # `>`, `;`, parentheses, quotes, backslash and space would close the
    # angle brackets, end the `for` clause or open a comment or a string.
    var h = trace_headers(
        String('a@b> (x;"y\\ z'),
        String("c.test"),
        String("192.0.2.1"),
        String(""),
        False,
        String("mx.example.com"),
        String("q1"),
        String("r@h>; Mon, 1 Jan 2001"),
        _NOW,
    )
    assert_true(h.startswith("Return-Path: <a@b???x??y??z>\r\n"), h)
    assert_true(h.find("\tfor <r@h???Mon,?1?Jan?2001>; Mon, 21 Sep 2026") >= 0, h)


def test_inbound_trace_fields_are_renamed() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var d = _delivery(store.clone(), store.clone())
    var rcpts = List[String]()
    rcpts.append("bob@example.com")
    var msg = _bytes(
        "Subject: s\r\n"
        "Authentication-Results: mx.example.com; spf=pass\r\n"
        " dkim=pass\r\n"
        "return-path: <boss@elsewhere.test>\r\n"
        "AUTHENTICATION-RESULTS : mx.example.com; dmarc=pass\r\n"
        "X-Return-Path: <keep@elsewhere.test>\r\n"
        "\r\n"
        "Return-Path: <in-the-body>\r\n"
        "Authentication-Results: in the body\r\n"
    )
    var r = d.deliver(_session(), String("a@b.test"), rcpts, Span(msg), _NOW)
    assert_equal(r.code, 250)
    var text = _only_message(view, "bob@example.com")
    var cut = text.find("Subject: s")
    assert_true(cut > 0)
    var tail = String(unsafe_from_utf8=text.as_bytes()[cut:])
    assert_equal(
        tail,
        String(
            "Subject: s\r\n"
            "X-Original-Authentication-Results: mx.example.com; spf=pass\r\n"
            " dkim=pass\r\n"
            "X-Original-return-path: <boss@elsewhere.test>\r\n"
            "X-Original-AUTHENTICATION-RESULTS : mx.example.com; dmarc=pass\r\n"
            "X-Return-Path: <keep@elsewhere.test>\r\n"
            "\r\n"
            "Return-Path: <in-the-body>\r\n"
            "Authentication-Results: in the body\r\n"
        ),
    )
    # Ours is the only unrenamed Return-Path and Authentication-Results in the
    # header: the first lines, and each exactly once before the blank line.
    var head_end = text.find("\r\n\r\n")
    var head = String(unsafe_from_utf8=text.as_bytes()[0:head_end])
    assert_true(head.startswith("Return-Path: <a@b.test>\r\n"))
    assert_equal(len(head.split("\r\nReturn-Path:")), 1)
    assert_equal(len(head.split("\r\nAuthentication-Results:")), 2)


def main() raises:
    test_rcpt_rule()
    test_postmaster_lands_in_the_first_domain()
    test_store_happens_before_the_hook()
    test_a_raising_hook_leaves_the_250()
    test_a_store_error_is_451_and_undoes_the_delivery()
    test_identical_deliveries_make_two_messages()
    test_the_hook_fires_for_exactly_the_recipients_stored()
    test_trace_headers_are_exact()
    test_peer_text_cannot_add_a_header()
    test_a_path_cannot_leave_its_brackets()
    test_inbound_trace_fields_are_renamed()
    print("test_local_delivery: OK")
