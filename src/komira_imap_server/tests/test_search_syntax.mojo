# What SEARCH does with input that is not a search, with the limits, and with
# messages that change under it. What each case catches:
# - malformed searches are `BAD` and nothing else: no keys, a missing or
#   extra argument, an unknown key, a bad number, date or set, an unbalanced
#   or empty group, an unterminated or badly escaped quoted string, a string
#   glued to the next token; the connection goes on after each;
# - the parser's bounds: nesting of groups and of NOT, and the number of
#   nodes, are refused above the limit and accepted at it;
# - state: SEARCH before LOGIN is `NO Log in first`, before SELECT `NO No
#   mailbox is selected`, after CLOSE the same; it works after EXAMINE;
# - a message the store lost since SELECT is still found by flag, set and
#   size keys (nothing is read for them) and never by a key that reads the
#   message, NOT of such a key included;
# - `max_scan_bytes`: a search with a key that reads messages is refused
#   `NO [LIMIT]` when the folder's messages are over it, before any is read;
#   a search of flags, sets and sizes is not.

from std.testing import assert_equal, assert_true

from komira_mail_store import folder_message_key, store_message
from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path

from komira_imap_server import (
    ImapLimits,
    ImapServerConfig,
    ImapTestServer,
    assign_uid,
)


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


struct _Rig(Movable):
    var s: ImapTestServer[SharedInMemoryConditionalStore]
    var id: Int
    var leaves: List[String]

    def __init__(out self, limits: ImapLimits = ImapLimits()):
        var config = ImapServerConfig(
            String("imap.test"), False, True, limits.copy()
        )
        self.s = ImapTestServer[SharedInMemoryConditionalStore](
            config^, SharedInMemoryConditionalStore()
        )
        self.s.add_user(String("bob@example.com"), String("pw"))
        self.id = 0
        self.leaves = List[String]()

    def add(mut self, raw: String) raises:
        var outcome = store_message(
            self.s.store,
            String("bob@example.com"),
            String("INBOX"),
            _bytes(raw),
        )
        self.leaves.append(outcome.leaf)

    def seq_of(self, which: Int) -> Int:
        for k in range(1, len(self.leaves) + 1):
            if self.s.reg.uid_at(self.id, k) == assign_uid(self.leaves[which]):
                return k
        return -1

    def login(mut self) raises:
        self.id = self.s.connect()
        _ = self.s.login(self.id, String("bob@example.com"), String("pw"))

    def select(mut self, verb: String = String("SELECT")) raises:
        var r = self.s.send(self.id, String("s1 ") + verb + " INBOX\r\n")
        assert_true(r.find("s1 OK") >= 0, r)

    def ask(mut self, line: String) -> String:
        return self.s.send(self.id, line)

    def search(mut self, keys: String) -> String:
        return self.ask(String("q1 SEARCH ") + keys + "\r\n")


def _two() raises -> _Rig:
    var r = _Rig()
    r.add(String("Subject: one\r\n\r\nfirst\r\n"))
    r.add(String("Subject: two\r\n\r\nsecond\r\n"))
    r.login()
    r.select()
    return r^


comptime BAD = "q1 BAD Invalid SEARCH arguments\r\n"


def test_malformed_searches_are_bad() raises:
    var r = _two()
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("("))
    bad.append(String(")"))
    bad.append(String("()"))
    bad.append(String("(ALL"))
    bad.append(String("ALL)"))
    bad.append(String("FROM"))
    bad.append(String("SUBJECT"))
    bad.append(String("HEADER subject"))
    bad.append(String('HEADER "" x'))
    bad.append(String("HEADER a:b x"))
    bad.append(String("OR ALL"))
    bad.append(String("OR"))
    bad.append(String("NOT"))
    bad.append(String("NOT (ALL"))
    bad.append(String("FROBNICATE"))
    bad.append(String("ALL FROBNICATE"))
    bad.append(String("LARGER"))
    bad.append(String("LARGER x"))
    bad.append(String("LARGER -1"))
    bad.append(String("SMALLER 99999999999"))
    bad.append(String("UID"))
    bad.append(String("UID 0"))
    bad.append(String("UID a"))
    bad.append(String("0"))
    bad.append(String("1:"))
    bad.append(String(":1"))
    bad.append(String("1,,2"))
    bad.append(String("BEFORE"))
    bad.append(String("BEFORE 32-Jan-2027"))
    bad.append(String("BEFORE 0-Jan-2027"))
    bad.append(String("SINCE 1-Foo-2027"))
    bad.append(String("SINCE 1-Sep-27"))
    bad.append(String("SINCE 1-Sep-1899"))
    bad.append(String("SINCE 1/Sep/2027"))
    bad.append(String("SINCE 29-Feb-2027"))
    bad.append(String("SINCE 2027-09-01"))
    bad.append(String("SENTON"))
    bad.append(String('SUBJECT "abc'))
    bad.append(String('SUBJECT "a\\x"'))
    bad.append(String('SUBJECT "a"b'))
    bad.append(String('SUBJECT"a"'))
    bad.append(String("CHARSET UTF-8"))
    for i in range(len(bad)):
        assert_equal(r.search(bad[i]), BAD)
        assert_equal(r.ask(String("n1 NOOP\r\n")), "n1 OK NOOP completed\r\n")
    assert_equal(
        r.search(String("CHARSET")), "q1 BAD CHARSET needs a charset name\r\n"
    )
    # `SEARCH` alone is a line with no argument at all.
    assert_equal(r.ask(String("q1 SEARCH\r\n")), BAD)
    # The same for UID SEARCH.
    assert_equal(r.ask(String("q1 UID SEARCH FROM\r\n")), BAD)
    assert_equal(r.ask(String("q1 UID SEARCH\r\n")), BAD)


def test_29_february_of_a_leap_year_is_a_date() raises:
    var r = _two()
    assert_equal(
        r.search(String("SINCE 29-Feb-2028")),
        "* SEARCH\r\nq1 OK SEARCH completed\r\n",
    )
    assert_equal(
        r.search(String("BEFORE 29-Feb-2028")),
        "* SEARCH 1 2\r\nq1 OK SEARCH completed\r\n",
    )


def _nested(depth: Int, open_: String, close: String) -> String:
    var out = String("")
    for _ in range(depth):
        out += open_
    out += "ALL"
    for _ in range(depth):
        out += close
    return out^


def test_nesting_and_size_bounds() raises:
    var r = _two()
    var found = String("* SEARCH 1 2\r\nq1 OK SEARCH completed\r\n")
    # Groups and NOT nest to a bound.
    assert_equal(r.search(_nested(24, String("("), String(")"))), found)
    assert_equal(r.search(_nested(25, String("("), String(")"))), BAD)
    assert_equal(r.search(_nested(24, String("NOT "), String(""))), found)
    assert_equal(
        r.search(_nested(23, String("NOT "), String(""))),
        "* SEARCH\r\nq1 OK SEARCH completed\r\n",
    )
    assert_equal(r.search(_nested(25, String("NOT "), String(""))), BAD)
    # Nodes: 255 keys and the node that holds them are the most there are.
    var keys = String("")
    for _ in range(255):
        keys += "ALL "
    assert_equal(r.search(keys), found)
    assert_equal(r.search(keys + "ALL"), BAD)
    # The connection is fine after all of it.
    assert_equal(r.ask(String("n1 NOOP\r\n")), "n1 OK NOOP completed\r\n")


def test_search_needs_a_login_and_a_selected_folder() raises:
    var r = _Rig()
    r.add(String("Subject: one\r\n\r\nx\r\n"))
    r.id = r.s.connect()
    _ = r.s.take(r.id)
    assert_equal(r.search(String("ALL")), "q1 NO Log in first\r\n")
    assert_equal(
        r.ask(String("q1 UID SEARCH ALL\r\n")), "q1 NO Log in first\r\n"
    )
    _ = r.s.login(r.id, String("bob@example.com"), String("pw"))
    assert_equal(r.search(String("ALL")), "q1 NO No mailbox is selected\r\n")
    assert_equal(
        r.ask(String("q1 UID SEARCH ALL\r\n")), "q1 NO No mailbox is selected\r\n"
    )
    r.select()
    assert_equal(r.search(String("ALL")), "* SEARCH 1\r\nq1 OK SEARCH completed\r\n")
    _ = r.ask(String("c1 CLOSE\r\n"))
    assert_equal(r.search(String("ALL")), "q1 NO No mailbox is selected\r\n")
    # EXAMINE allows it.
    r.select(String("EXAMINE"))
    assert_equal(r.search(String("ALL")), "* SEARCH 1\r\nq1 OK SEARCH completed\r\n")


def test_a_message_the_store_lost_is_found_only_by_what_reads_nothing() raises:
    var r = _Rig()
    r.add(String("Subject: kept\r\n\r\nkept body\r\n"))
    r.add(String("Subject: lost\r\n\r\nlost body\r\n"))
    r.login()
    r.select()
    var kept = r.seq_of(0)
    # Both are in the view. The second one's object goes away.
    r.s.store.delete(
        Path.parse(
            folder_message_key(
                String("bob@example.com"), String("INBOX"), r.leaves[1]
            )
        )
    )
    var both = String("* SEARCH 1 2\r\nq1 OK SEARCH completed\r\n")
    # The lost message is in the view, so what reads nothing still finds it.
    assert_equal(r.search(String("ALL")), both)
    assert_equal(r.search(String("UNSEEN")), both)
    assert_equal(r.search(String("1:2")), both)
    assert_equal(r.search(String("LARGER 1")), both)
    # What reads a message cannot find the one that is gone, even as a NOT.
    var only = "* SEARCH " + String(kept) + "\r\nq1 OK SEARCH completed\r\n"
    assert_equal(r.search(String("SUBJECT kept")), only)
    assert_equal(r.search(String("NOT SUBJECT zzz")), only)
    assert_equal(r.search(String("NOT TEXT lost")), only)
    assert_equal(
        r.search(String("TEXT lost")), "* SEARCH\r\nq1 OK SEARCH completed\r\n"
    )


def test_the_scan_limit_applies_to_keys_that_read_messages() raises:
    var limits = ImapLimits()
    limits.max_scan_bytes = 50
    var r = _Rig(limits^)
    r.add(String("Subject: one\r\n\r\nfirst message body\r\n"))
    r.add(String("Subject: two\r\n\r\nsecond message body\r\n"))
    r.login()
    r.select()
    var refused = String(
        "q1 NO [LIMIT] Too many message bytes to search; narrow the search\r\n"
    )
    var reading = List[String]()
    reading.append(String("SUBJECT one"))
    reading.append(String("BODY first"))
    reading.append(String("TEXT first"))
    reading.append(String("FROM x"))
    reading.append(String("HEADER Subject one"))
    reading.append(String("SINCE 1-Sep-2026"))
    reading.append(String("SENTON 1-Sep-2026"))
    reading.append(String("UNSEEN OR SEEN SUBJECT one"))
    for i in range(len(reading)):
        assert_equal(r.search(reading[i]), refused)
    # Flags, sets and sizes read nothing and are not limited.
    assert_equal(r.search(String("ALL")), "* SEARCH 1 2\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("UNSEEN LARGER 3")), "* SEARCH 1 2\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("2")), "* SEARCH 2\r\nq1 OK SEARCH completed\r\n")


def main() raises:
    test_malformed_searches_are_bad()
    test_29_february_of_a_leap_year_is_a_date()
    test_nesting_and_size_bounds()
    test_search_needs_a_login_and_a_selected_folder()
    test_a_message_the_store_lost_is_found_only_by_what_reads_nothing()
    test_the_scan_limit_applies_to_keys_that_read_messages()
    print("test_search_syntax: OK")
