# A server's reply (RFC 5321 section 4.2) and the capabilities an EHLO reply
# announces (section 4.1.1.1). Reply text is kept as printable ASCII: any byte
# outside 0x20..0x7E (and tab) becomes `?`, so a hostile server cannot put
# control bytes or invalid UTF-8 into a log line or an error.

comptime _MAX_REPLY_LINES: Int = 512
comptime _MAX_REPLY_BYTES: Int = 65536


struct SmtpReply(Copyable, Movable):
    """One reply: the three-digit code, the text of each line (without the code,
    the separator or an enhanced status code) and the enhanced status code of
    RFC 3463 (`5.1.1`) when the first line starts with one that agrees with the
    code's class, else empty."""

    var code: Int
    var lines: List[String]
    var enhanced: String

    def __init__(out self, code: Int, var lines: List[String], var enhanced: String):
        self.code = code
        self.lines = lines^
        self.enhanced = enhanced^

    def text(self) -> String:
        """The lines joined by a line feed."""
        var out = String("")
        for i in range(len(self.lines)):
            if i > 0:
                out += "\n"
            out += self.lines[i]
        return out^

    def is_positive(self) -> Bool:
        """2xx."""
        return self.code >= 200 and self.code < 300

    def is_intermediate(self) -> Bool:
        """3xx."""
        return self.code >= 300 and self.code < 400

    def is_transient(self) -> Bool:
        """4xx: the same command may succeed later."""
        return self.code >= 400 and self.code < 500

    def is_permanent(self) -> Bool:
        """5xx: the command will not succeed as it stands."""
        return self.code >= 500 and self.code < 600


def sanitize_text(b: Span[UInt8, _], start: Int, end: Int) -> String:
    """The bytes `b[start:end]` as printable ASCII (see the header)."""
    var out = List[UInt8](capacity=max(end - start, 0))
    for i in range(start, end):
        var c = b[i]
        if (c >= 0x20 and c < 0x7F) or c == 0x09:
            out.append(c)
        else:
            out.append(UInt8(0x3F))
    # SAFETY: every byte is ASCII, so the bytes are valid UTF-8.
    return String(unsafe_from_utf8=Span(out))


def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


struct ReplyLine(Copyable, Movable):
    """One parsed line of a reply."""

    var code: Int
    var is_last: Bool
    var text: String

    def __init__(out self, code: Int, is_last: Bool, var text: String):
        self.code = code
        self.is_last = is_last
        self.text = text^


def parse_reply_line(line: Span[UInt8, _]) raises -> ReplyLine:
    """Parse `NNN text`, `NNN-text` or `NNN`. The first digit is 2 to 5."""
    var n = len(line)
    if n < 3:
        raise Error("SmtpProtocol: a reply line shorter than a reply code")
    if not (_is_digit(line[0]) and _is_digit(line[1]) and _is_digit(line[2])):
        raise Error("SmtpProtocol: a reply line without a three-digit code")
    var code = (
        Int(line[0] - 0x30) * 100 + Int(line[1] - 0x30) * 10 + Int(line[2] - 0x30)
    )
    if code < 200 or code > 599:
        raise Error("SmtpProtocol: a reply code outside 200 to 599")
    if n == 3:
        return ReplyLine(code, True, String(""))
    if line[3] == 0x20:
        return ReplyLine(code, True, sanitize_text(line, 4, n))
    if line[3] == 0x2D:
        return ReplyLine(code, False, sanitize_text(line, 4, n))
    raise Error("SmtpProtocol: a reply code followed by neither a space nor a hyphen")


def _enhanced_prefix_len(text: String, code: Int) -> Int:
    """The length of a leading enhanced status code (`d.ddd.ddd`) whose class
    digit equals the reply's class, followed by a space or the end; else 0."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    if n < 5 or not _is_digit(b[0]) or Int(b[0] - 0x30) != code // 100:
        return 0
    i = 1
    for _ in range(2):
        if i >= n or b[i] != 0x2E:
            return 0
        i += 1
        var digits = 0
        while i < n and _is_digit(b[i]) and digits < 3:
            i += 1
            digits += 1
        if digits == 0:
            return 0
    if i < n and b[i] != 0x20:
        return 0
    return i


def assemble_reply(code: Int, texts: List[String]) -> SmtpReply:
    """Make a reply from the lines' texts: the enhanced status code of the
    first line is split off, and so is the same code on later lines."""
    var enhanced = String("")
    var out = List[String]()
    for i in range(len(texts)):
        var t = texts[i]
        var k = _enhanced_prefix_len(t, code)
        if k > 0:
            if i == 0:
                enhanced = String(t[byte=0:k])
            var rest_start = k
            if rest_start < t.byte_length():
                rest_start += 1
            var tail = String(t[byte=rest_start : t.byte_length()])
            t = tail^
        out.append(t)
    return SmtpReply(code, out^, enhanced^)


def reply_line_budget_ok(lines: Int, bytes: Int) -> Bool:
    """Whether a reply of this many lines and bytes is within the caps."""
    return lines <= _MAX_REPLY_LINES and bytes <= _MAX_REPLY_BYTES


def _upper(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= 0x61 and c <= 0x7A:
            c = c - 32
        out.append(c)
    # SAFETY: only ASCII letters changed, so UTF-8 validity is kept.
    return String(unsafe_from_utf8=Span(out))


def _words(s: String) -> List[String]:
    var out = List[String]()
    var b = s.as_bytes()
    var start = -1
    for i in range(len(b)):
        if b[i] == 0x20 or b[i] == 0x09:
            if start >= 0:
                out.append(String(s[byte=start:i]))
                start = -1
        elif start < 0:
            start = i
    if start >= 0:
        out.append(String(s[byte=start : len(b)]))
    return out^


struct SmtpCapabilities(Copyable, Movable):
    """What an EHLO reply announced. Keywords are matched case-insensitively.
    `size_limit` is -1 when SIZE was not announced and 0 when it was announced
    without a limit. `auth_mechanisms` holds the upper-cased names."""

    var starttls: Bool
    var auth_mechanisms: List[String]
    var size_limit: Int
    var eight_bit_mime: Bool
    var smtputf8: Bool
    var pipelining: Bool
    var enhanced_status_codes: Bool

    def __init__(out self):
        self.starttls = False
        self.auth_mechanisms = List[String]()
        self.size_limit = -1
        self.eight_bit_mime = False
        self.smtputf8 = False
        self.pipelining = False
        self.enhanced_status_codes = False

    def offers_auth(self, mechanism: String) -> Bool:
        for i in range(len(self.auth_mechanisms)):
            if self.auth_mechanisms[i] == mechanism:
                return True
        return False

    @staticmethod
    def from_ehlo(reply: SmtpReply) -> SmtpCapabilities:
        """Read the capability lines of a 250 reply. The first line is the
        server's greeting and is not a keyword."""
        var caps = SmtpCapabilities()
        for i in range(1, len(reply.lines)):
            var words = _words(_upper(reply.lines[i]))
            if len(words) == 0:
                continue
            var key = words[0]
            if key == "STARTTLS":
                caps.starttls = True
            elif key == "8BITMIME":
                caps.eight_bit_mime = True
            elif key == "SMTPUTF8":
                caps.smtputf8 = True
            elif key == "PIPELINING":
                caps.pipelining = True
            elif key == "ENHANCEDSTATUSCODES":
                caps.enhanced_status_codes = True
            elif key == "SIZE":
                caps.size_limit = 0
                if len(words) > 1:
                    var v = 0
                    var ok = True
                    var wb = words[1].as_bytes()
                    if len(wb) == 0 or len(wb) > 15:
                        ok = False
                    for j in range(len(wb)):
                        if not _is_digit(wb[j]):
                            ok = False
                            break
                        v = v * 10 + Int(wb[j] - 0x30)
                    if ok:
                        caps.size_limit = v
            elif key == "AUTH" or key.startswith("AUTH="):
                # The legacy `AUTH=PLAIN LOGIN` spelling is read too.
                var first = True
                for j in range(len(words)):
                    var w = words[j]
                    if first:
                        first = False
                        if key.startswith("AUTH="):
                            w = String(key[byte=5 : key.byte_length()])
                        else:
                            continue
                    if w.byte_length() > 0:
                        caps.auth_mechanisms.append(w)
        return caps^
