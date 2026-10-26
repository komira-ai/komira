# SEARCH and UID SEARCH, every key, over four messages written for it (A, B,
# C, D). Each case names the messages the key must find by label, and the test
# turns labels into sequence numbers (the view is in UID order, which is a
# hash), so a key that finds the wrong messages fails whatever the order. What
# each case catches:
# - the flag keys and their opposites over durable flags set with STORE; NEW
#   and RECENT find nothing and OLD everything (no \Recent flag is kept);
#   KEYWORD finds nothing and UNKEYWORD everything;
# - FROM, TO, CC, BCC, SUBJECT and HEADER: a case-insensitive substring of the
#   field as written, or with its encoded words decoded (a subject sent as
#   base64 is found by its text and by its encoding), a field present with an
#   empty value, HEADER with an empty string as "has the field", and a header
#   key that does not match a word that is only in the body;
# - BODY and TEXT: BODY finds the text after the header block only, TEXT also
#   the header, any letter case, and a needle that nearly matches a very long
#   run is still decided;
# - INTERNALDATE keys (BEFORE, ON, SINCE) compare UTC days of the Received
#   time, with the epoch for a message with no date, and the SENT keys the
#   Date field: a Date a day before the Received time, and a message with no
#   Date that none of the three finds (and NOT finds);
# - LARGER and SMALLER against the sizes of the stored messages, exactly at
#   each size;
# - sequence sets and UID sets with ranges and `*`; the result of UID SEARCH
#   is UIDs, ascending;
# - NOT, OR (nested), parentheses (all required), and several keys (all
#   required);
# - CHARSET US-ASCII and UTF-8 are accepted (also quoted), any other is
#   `NO [BADCHARSET (US-ASCII UTF-8)]`.

from std.testing import assert_equal, assert_true

from komira_mail_store import store_message
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import ImapServerConfig, ImapTestServer, assign_uid


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


comptime MSG_A = (
    "Received: from c.test by mx; Tue, 01 Sep 2026 10:00:00 +0000\r\n"
    "Date: Tue, 01 Sep 2026 09:00:00 +0000\r\n"
    "From: Alice <alice@example.com>\r\n"
    "To: Bob <bob@example.org>\r\n"
    "Subject: Quarterly report\r\n"
    "X-Priority: urgent\r\n"
    "\r\n"
    "budget figures attached\r\n"
)

comptime MSG_B = (
    "Received: from c.test by mx; Wed, 02 Sep 2026 12:00:00 +0000\r\n"
    "Date: Tue, 01 Sep 2026 23:00:00 +0000\r\n"
    "From: Carol <carol@example.net>\r\n"
    "To: Bob <bob@example.org>\r\n"
    "Cc: dave@example.net\r\n"
    "Subject: Lunch\r\n"
    "\r\n"
    "Pizza at noon\r\n"
)

comptime MSG_C = (
    "Received: from c.test by mx; Thu, 10 Sep 2026 08:00:00 +0000\r\n"
    "Date: Wed, 09 Sep 2026 20:00:00 +0000\r\n"
    "From: alice@example.com\r\n"
    "Subject: =?UTF-8?B?SGVsbG8gV29ybGQ=?=\r\n"
    "Bcc: erin@example.net\r\n"
    "\r\n"
    "ZEBRA stripes and more text so that this message is the largest of the four.\r\n"
    "More text, more text, more text, more text, more text, more text.\r\n"
)

comptime MSG_D = (
    "From: dave@example.net\r\n"
    "Subject: Notes\r\n"
    "X-Empty:\r\n"
    "\r\n"
    "hello from dave, who also mentions alice in the body\r\n"
)


struct _Rig(Movable):
    var s: ImapTestServer[SharedInMemoryConditionalStore]
    var id: Int
    var raws: List[String]
    var leaves: List[String]

    def __init__(out self):
        var config = ImapServerConfig(String("imap.test"), False, True)
        self.s = ImapTestServer[SharedInMemoryConditionalStore](
            config^, SharedInMemoryConditionalStore()
        )
        self.s.add_user(String("bob@example.com"), String("pw"))
        self.id = 0
        self.raws = List[String]()
        self.leaves = List[String]()

    def add(mut self, raw: String) raises:
        var outcome = store_message(
            self.s.store,
            String("bob@example.com"),
            String("INBOX"),
            _bytes(raw),
        )
        self.raws.append(raw)
        self.leaves.append(outcome.leaf)

    def seq_of(self, which: Int) -> Int:
        for k in range(1, len(self.leaves) + 1):
            if self.s.reg.uid_at(self.id, k) == assign_uid(self.leaves[which]):
                return k
        return -1

    def uid_of(self, which: Int) -> Int:
        return assign_uid(self.leaves[which])

    def ask(mut self, line: String) -> String:
        return self.s.send(self.id, line)

    def search(mut self, keys: String) -> String:
        return self.ask(String("q1 SEARCH ") + keys + "\r\n")

    def labels(self, text: String) -> List[Int]:
        """The indexes of the messages named by the letters of `text`."""
        var out = List[Int]()
        var b = text.as_bytes()
        for i in range(len(b)):
            out.append(Int(b[i]) - 0x41)
        return out^

    def expect(self, text: String) -> String:
        """The answer of `SEARCH` finding the messages named by `text`
        (letters, e.g. "AC"): their sequence numbers, ascending."""
        var seqs = List[Int]()
        var which = self.labels(text)
        for i in range(len(which)):
            seqs.append(self.seq_of(which[i]))
        # Insertion sort: at most four numbers.
        for i in range(1, len(seqs)):
            var v = seqs[i]
            var j = i - 1
            while j >= 0 and seqs[j] > v:
                seqs[j + 1] = seqs[j]
                j -= 1
            seqs[j + 1] = v
        var line = String("* SEARCH")
        for i in range(len(seqs)):
            line += " " + String(seqs[i])
        return line + "\r\nq1 OK SEARCH completed\r\n"


def _rig() raises -> _Rig:
    var r = _Rig()
    r.add(String(MSG_A))
    r.add(String(MSG_B))
    r.add(String(MSG_C))
    r.add(String(MSG_D))
    r.id = r.s.connect()
    _ = r.s.login(r.id, String("bob@example.com"), String("pw"))
    var sel = r.s.send(r.id, String("s1 SELECT INBOX\r\n"))
    assert_true(sel.find("s1 OK") >= 0, sel)
    # A is \Seen; B \Answered and \Flagged; C \Deleted and \Draft.
    _ = r.ask(String("t1 STORE ") + String(r.seq_of(0)) + " +FLAGS (\\Seen)\r\n")
    _ = r.ask(
        String("t2 STORE ") + String(r.seq_of(1)) + " +FLAGS (\\Answered \\Flagged)\r\n"
    )
    _ = r.ask(
        String("t3 STORE ") + String(r.seq_of(2)) + " +FLAGS (\\Deleted \\Draft)\r\n"
    )
    return r^


def _check(mut r: _Rig, keys: String, labels: String) raises:
    assert_equal(r.search(keys), r.expect(labels))


def test_flag_keys() raises:
    var r = _rig()
    _check(r, String("ALL"), String("ABCD"))
    _check(r, String("SEEN"), String("A"))
    _check(r, String("UNSEEN"), String("BCD"))
    _check(r, String("ANSWERED"), String("B"))
    _check(r, String("UNANSWERED"), String("ACD"))
    _check(r, String("FLAGGED"), String("B"))
    _check(r, String("UNFLAGGED"), String("ACD"))
    _check(r, String("DELETED"), String("C"))
    _check(r, String("UNDELETED"), String("ABD"))
    _check(r, String("DRAFT"), String("C"))
    _check(r, String("UNDRAFT"), String("ABD"))
    # Keys are not case sensitive.
    _check(r, String("seen"), String("A"))
    _check(r, String("Unseen"), String("BCD"))


def test_keys_that_depend_on_a_recent_flag_and_on_keywords() raises:
    var r = _rig()
    _check(r, String("RECENT"), String(""))
    _check(r, String("NEW"), String(""))
    _check(r, String("OLD"), String("ABCD"))
    _check(r, String("KEYWORD $Label1"), String(""))
    _check(r, String("UNKEYWORD $Label1"), String("ABCD"))
    _check(r, String("NOT OLD"), String(""))


def test_header_keys() raises:
    var r = _rig()
    _check(r, String("FROM alice"), String("AC"))
    _check(r, String('FROM "ALICE@EXAMPLE"'), String("AC"))
    _check(r, String("FROM example.net"), String("BD"))
    _check(r, String("FROM nobody"), String(""))
    _check(r, String("TO bob"), String("AB"))
    _check(r, String("CC dave"), String("B"))
    _check(r, String("BCC erin"), String("C"))
    _check(r, String("SUBJECT report"), String("A"))
    _check(r, String("SUBJECT QUARTERLY"), String("A"))
    _check(r, String('SUBJECT "quarterly report"'), String("A"))
    # A word of the display name is part of the field.
    _check(r, String("FROM Carol"), String("B"))
    # An encoded subject is found by the text it decodes to and by what was
    # written.
    _check(r, String('SUBJECT "hello world"'), String("C"))
    _check(r, String("SUBJECT =?UTF-8?B?SGVsbG8"), String("C"))
    # A word that is only in a body is not in the FROM field.
    _check(r, String("FROM mentions"), String(""))
    _check(r, String("HEADER X-Priority urgent"), String("A"))
    _check(r, String("HEADER x-priority URG"), String("A"))
    _check(r, String('HEADER X-Priority ""'), String("A"))
    _check(r, String('HEADER X-Empty ""'), String("D"))
    _check(r, String("HEADER X-Empty x"), String(""))
    _check(r, String('HEADER Subject ""'), String("ABCD"))
    _check(r, String('HEADER Cc ""'), String("B"))
    _check(r, String('HEADER Reply-To ""'), String(""))


def test_body_and_text_keys() raises:
    var r = _rig()
    _check(r, String("BODY budget"), String("A"))
    _check(r, String("BODY pizza"), String("B"))
    _check(r, String("BODY zebra"), String("C"))
    # alice is in the headers of A and C and in the body of D.
    _check(r, String("BODY alice"), String("D"))
    _check(r, String("TEXT alice"), String("ACD"))
    # Header field names and values are not in the body.
    _check(r, String("BODY From:"), String(""))
    _check(r, String("TEXT From:"), String("ABCD"))
    _check(r, String('BODY "and more text"'), String("C"))
    _check(r, String('BODY ""'), String("ABCD"))
    _check(r, String("TEXT dave"), String("BD"))


def test_a_needle_that_nearly_matches_a_long_run_is_decided() raises:
    var r = _Rig()
    var run = String("")
    for _ in range(3000):
        run += "aaaaaaaaaa"
    # Not a multiple of the needle's run: a search that restarts at the
    # needle's start after a near match, instead of at the longest border,
    # loses the match at the end.
    run += "aaa"
    r.add(String("Subject: run\r\n\r\n") + run + "b\r\n")
    r.id = r.s.connect()
    _ = r.s.login(r.id, String("bob@example.com"), String("pw"))
    _ = r.s.send(r.id, String("s1 SELECT INBOX\r\n"))
    var needle = String("")
    for _ in range(40):
        needle += "aaaaaaaaaa"
    assert_equal(r.search(String("BODY ") + needle + "b"), "* SEARCH 1\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("BODY ") + needle + "c"), "* SEARCH\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("BODY b")), "* SEARCH 1\r\nq1 OK SEARCH completed\r\n")


def test_internal_date_keys() raises:
    var r = _rig()
    # Received: A 1 Sep, B 2 Sep, C 10 Sep; D has none, so the epoch.
    _check(r, String("ON 1-Sep-2026"), String("A"))
    _check(r, String("ON 02-Sep-2026"), String("B"))
    _check(r, String('ON "10-sep-2026"'), String("C"))
    _check(r, String("ON 3-Sep-2026"), String(""))
    _check(r, String("BEFORE 2-Sep-2026"), String("AD"))
    _check(r, String("BEFORE 1-Sep-2026"), String("D"))
    _check(r, String("BEFORE 11-Sep-2026"), String("ABCD"))
    _check(r, String("SINCE 2-Sep-2026"), String("BC"))
    _check(r, String("SINCE 10-Sep-2026"), String("C"))
    _check(r, String("SINCE 11-Sep-2026"), String(""))
    _check(r, String("SINCE 1-Sep-2026 BEFORE 10-Sep-2026"), String("AB"))


def test_sent_date_keys() raises:
    var r = _rig()
    # Date: A 1 Sep 09:00, B 1 Sep 23:00 (a day before it was received),
    # C 9 Sep; D has no Date and is found by none of these, and by NOT.
    _check(r, String("SENTON 1-Sep-2026"), String("AB"))
    _check(r, String("SENTON 2-Sep-2026"), String(""))
    _check(r, String("SENTON 9-Sep-2026"), String("C"))
    _check(r, String("SENTBEFORE 2-Sep-2026"), String("AB"))
    _check(r, String("SENTBEFORE 9-Sep-2026"), String("AB"))
    _check(r, String("SENTBEFORE 10-Sep-2026"), String("ABC"))
    _check(r, String("SENTSINCE 2-Sep-2026"), String("C"))
    _check(r, String("SENTSINCE 1-Sep-2026"), String("ABC"))
    _check(r, String("NOT SENTBEFORE 2-Sep-2026"), String("CD"))
    # The received day and the sent day differ for B.
    _check(r, String("ON 2-Sep-2026 SENTON 1-Sep-2026"), String("B"))


def test_size_keys_are_exact() raises:
    var r = _rig()
    var sizes = List[Int]()
    for i in range(4):
        sizes.append(r.raws[i].byte_length())
    for i in range(4):
        # LARGER n: more than n octets; SMALLER n: fewer.
        for delta in range(-1, 2):
            var n = sizes[i] + delta
            var larger = String("")
            var smaller = String("")
            for k in range(4):
                if sizes[k] > n:
                    larger += chr(0x41 + k)
                if sizes[k] < n:
                    smaller += chr(0x41 + k)
            _check(r, String("LARGER ") + String(n), larger)
            _check(r, String("SMALLER ") + String(n), smaller)
    _check(r, String("LARGER 0"), String("ABCD"))
    _check(r, String("SMALLER 1"), String(""))


def test_sequence_and_uid_sets() raises:
    var r = _rig()
    assert_equal(r.search(String("1")), "* SEARCH 1\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("2:3")), "* SEARCH 2 3\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("3:2")), "* SEARCH 2 3\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("*")), "* SEARCH 4\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("1,4")), "* SEARCH 1 4\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("3:*")), "* SEARCH 3 4\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("9")), "* SEARCH\r\nq1 OK SEARCH completed\r\n")
    assert_equal(r.search(String("1:4 SEEN")), r.expect(String("A")))
    # UID sets: one UID, and a range that holds all of them.
    var uid_b = r.uid_of(1)
    assert_equal(
        r.search(String("UID ") + String(uid_b)), r.expect(String("B"))
    )
    assert_equal(r.search(String("UID 1:*")), r.expect(String("ABCD")))
    assert_equal(
        r.search(String("NOT UID ") + String(uid_b)), r.expect(String("ACD"))
    )
    assert_equal(
        r.search(String("UID 4294967295")), "* SEARCH\r\nq1 OK SEARCH completed\r\n"
    )
    # More than ten digits is not a number.
    assert_equal(r.search(String("UID 99999999999")), "q1 BAD Invalid SEARCH arguments\r\n")


def test_uid_search_answers_uids() raises:
    var r = _rig()
    var uids = List[Int]()
    for seq in range(1, 5):
        uids.append(r.s.reg.uid_at(r.id, seq))
    var all = String("* SEARCH")
    for i in range(4):
        all += " " + String(uids[i])
    assert_equal(
        r.ask(String("u1 UID SEARCH ALL\r\n")),
        all + "\r\nu1 OK SEARCH completed\r\n",
    )
    # Ascending, and only the matches.
    assert_equal(
        r.ask(String("u1 UID SEARCH FROM carol\r\n")),
        "* SEARCH " + String(r.uid_of(1)) + "\r\nu1 OK SEARCH completed\r\n",
    )
    assert_equal(
        r.ask(String("u1 UID SEARCH SEEN\r\n")),
        "* SEARCH " + String(r.uid_of(0)) + "\r\nu1 OK SEARCH completed\r\n",
    )
    assert_equal(
        r.ask(String("u1 UID SEARCH FROM nobody\r\n")),
        "* SEARCH\r\nu1 OK SEARCH completed\r\n",
    )


def test_not_or_groups_and_several_keys() raises:
    var r = _rig()
    _check(r, String("NOT SEEN"), String("BCD"))
    _check(r, String("NOT NOT SEEN"), String("A"))
    _check(r, String("NOT FROM alice"), String("BD"))
    _check(r, String("OR SEEN FLAGGED"), String("AB"))
    _check(r, String("OR FROM carol FROM dave"), String("BD"))
    _check(r, String("OR FROM carol OR FROM dave FROM erin"), String("BD"))
    _check(r, String("OR OR FROM carol FROM dave SUBJECT report"), String("ABD"))
    # OR takes two keys and the keys after it are required as well.
    _check(r, String("OR SEEN FLAGGED TO bob"), String("AB"))
    _check(r, String("OR SEEN FLAGGED FROM carol"), String("B"))
    # A group needs all of its keys.
    _check(r, String("(FROM alice TO bob)"), String("A"))
    _check(r, String("(SEEN FLAGGED)"), String(""))
    _check(r, String("OR (SEEN FLAGGED) (DELETED DRAFT)"), String("C"))
    _check(r, String("NOT (FROM alice UNSEEN)"), String("ABD"))
    _check(r, String("((((ALL))))"), String("ABCD"))
    # Several keys are all required.
    _check(r, String("FROM alice UNSEEN"), String("C"))
    _check(r, String("FROM alice SUBJECT report"), String("A"))
    _check(r, String("FROM alice SUBJECT carol"), String(""))
    # Content keys with cheap keys in either order give the same answer.
    _check(r, String("TEXT dave UNSEEN"), String("BD"))
    _check(r, String("UNSEEN TEXT dave"), String("BD"))
    _check(r, String("OR TEXT pizza SEEN"), String("AB"))
    _check(r, String("NOT TEXT dave"), String("AC"))


def test_charset_argument() raises:
    var r = _rig()
    _check(r, String("CHARSET UTF-8 FROM alice"), String("AC"))
    _check(r, String("CHARSET US-ASCII FROM alice"), String("AC"))
    _check(r, String("charset utf-8 SEEN"), String("A"))
    _check(r, String('CHARSET "UTF-8" SEEN'), String("A"))
    var no = String(
        "q1 NO [BADCHARSET (US-ASCII UTF-8)] Unsupported charset\r\n"
    )
    assert_equal(r.search(String("CHARSET ISO-8859-1 ALL")), no)
    assert_equal(r.search(String("CHARSET UTF-16 FROM alice")), no)
    assert_equal(r.search(String("CHARSET BOGUS")), no)


def main() raises:
    test_flag_keys()
    test_keys_that_depend_on_a_recent_flag_and_on_keywords()
    test_header_keys()
    test_body_and_text_keys()
    test_a_needle_that_nearly_matches_a_long_run_is_decided()
    test_internal_date_keys()
    test_sent_date_keys()
    test_size_keys_are_exact()
    test_sequence_and_uid_sets()
    test_uid_search_answers_uids()
    test_not_or_groups_and_several_keys()
    test_charset_argument()
    print("test_search: OK")
