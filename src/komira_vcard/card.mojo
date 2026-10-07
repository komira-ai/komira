# =============================================================================
# card.mojo -- a .vcf stream to raw cards: BEGIN/END pairing, VERSION, the
# card-count limit, and vCard 2.1 quoted-printable values.
# =============================================================================
#
# `parse_vcards` unfolds and lexes the input (komira_content_line), then:
# - pairs BEGIN:VCARD with END:VCARD (names and the VCARD value are
#   case-insensitive). A property outside a card, a BEGIN:VCARD inside a card,
#   an END:VCARD with no card and a card with no END:VCARD are refused.
# - requires exactly one VERSION per card, 2.1, 3.0 or 4.0, anywhere in the
#   card (RFC 6350 wants it first; vCard 2.1 and 3.0 writers do not all
#   put it there).
# - refuses card number `max_cards + 1` before reading it.
# - decodes ENCODING=QUOTED-PRINTABLE, or vCard 2.1's bare QUOTED-PRINTABLE
#   parameter (also written by some 3.0 exporters): a value ending in "=" continues on the next line (a soft
#   break), `=XX` is an octet, and the octets are read in the line's CHARSET
#   (UTF-8 or US-ASCII, checked as UTF-8; ISO-8859-1, converted); a decoded
#   line break (CRLF, CR or LF) becomes the TEXT escape `\n`. The
#   ENCODING and CHARSET parameters are then removed and the line is written
#   back unfolded as `text`. CHARSET is removed from every line: the input is
#   UTF-8 by then (unfold refused anything else).
#
# A card keeps every other line in order, lexed (`line`) and as written
# (`text`, the unfolded logical line), with its first physical line number.
# =============================================================================

from komira_content_line import (
    ContentLimits,
    ContentLine,
    Param,
    format_content_line,
    parse_content_line,
    unfold,
    utf8_invalid_at,
    DEFAULT_MAX_INPUT_OCTETS,
    DEFAULT_MAX_LINE_OCTETS,
)


comptime DEFAULT_MAX_CARDS: Int = 10000


struct VCardLimits(Copyable, Movable):
    """Bounds on one import: input octets, unfolded line octets, cards."""

    var max_input_octets: Int
    var max_line_octets: Int
    var max_cards: Int

    def __init__(
        out self,
        *,
        max_input_octets: Int = DEFAULT_MAX_INPUT_OCTETS,
        max_line_octets: Int = DEFAULT_MAX_LINE_OCTETS,
        max_cards: Int = DEFAULT_MAX_CARDS,
    ):
        self.max_input_octets = max_input_octets
        self.max_line_octets = max_line_octets
        self.max_cards = max_cards


struct VCardLine(Copyable, Movable):
    """One property line of a card: lexed, as written, and where."""

    var line: ContentLine
    var text: String
    var line_number: Int

    def __init__(out self, var line: ContentLine, var text: String, n: Int):
        self.line = line^
        self.text = text^
        self.line_number = n


struct VCard(Copyable, Movable):
    """One card: its VERSION, its BEGIN line, and its other lines in order."""

    var version: String
    var begin_line: Int
    var lines: List[VCardLine]

    def __init__(out self, var version: String, begin_line: Int):
        self.version = version^
        self.begin_line = begin_line
        self.lines = List[VCardLine]()


def _at(n: Int) -> String:
    return String("vcard: line ") + String(n) + String(": ")


@always_inline
def _hex(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return -1


def _decode_qp(value: String, charset: String, n: Int) raises -> String:
    var b = value.as_bytes()
    var raw = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] != 61:
            raw.append(b[i])
            i += 1
            continue
        var hi = _hex(b[i + 1]) if i + 1 < len(b) else -1
        var lo = _hex(b[i + 2]) if i + 2 < len(b) else -1
        if hi < 0 or lo < 0:
            raise Error(
                _at(n) + String("invalid quoted-printable at octet ") + String(i)
            )
        raw.append(UInt8(hi * 16 + lo))
        i += 3
    var cs = charset.upper()
    if cs == "ISO-8859-1" or cs == "LATIN1":
        var conv = List[UInt8]()
        for k in range(len(raw)):
            var c = raw[k]
            if c < 0x80:
                conv.append(c)
            else:
                conv.append(UInt8(0xC0 | (Int(c) >> 6)))
                conv.append(UInt8(0x80 | (Int(c) & 0x3F)))
        raw = conv^
    elif cs != "" and cs != "UTF-8" and cs != "US-ASCII":
        raise Error(
            _at(n)
            + String("CHARSET ")
            + charset
            + String(" is not UTF-8, US-ASCII or ISO-8859-1")
        )
    var bad = utf8_invalid_at(Span(raw))
    if bad >= 0:
        raise Error(
            _at(n)
            + String("the quoted-printable value is not valid UTF-8 (octet ")
            + String(bad)
            + String(")")
        )
    # A decoded line break is written as the TEXT escape `\n`, so the value
    # stays one line in the escaped form every other value has.
    var esc = List[UInt8]()
    var k = 0
    while k < len(raw):
        var c = raw[k]
        if c == 13 or c == 10:
            esc.append(92)
            esc.append(110)
            if c == 13 and k + 1 < len(raw) and raw[k + 1] == 10:
                k += 1
        else:
            esc.append(c)
        k += 1
    return String(StringSlice(from_utf8=Span(esc)))


def _first_value(cl: ContentLine, name: String) -> String:
    var p = cl.param(name)
    if p and len(p.value().values) > 0:
        return p.value().values[0].copy()
    return String()


def _without(params: List[Param], a: String, b: String) -> List[Param]:
    var out = List[Param]()
    for k in range(len(params)):
        if params[k].name != a and params[k].name != b:
            out.append(params[k].copy())
    return out^


def parse_vcards(
    data: Span[UInt8, _], limits: VCardLimits = VCardLimits()
) raises -> List[VCard]:
    """Every card in `data`, raw (file header)."""
    var logical = unfold(
        data,
        ContentLimits(
            max_input_octets=limits.max_input_octets,
            max_line_octets=limits.max_line_octets,
        ),
    )
    var cards = List[VCard]()
    var open = False
    var cur = VCard(String(), 0)
    var i = 0
    while i < len(logical):
        var n = logical[i].line_number
        var text = logical[i].text.copy()
        i += 1
        var cl = parse_content_line(text, n)
        var is_vcard = cl.value.upper() == "VCARD"
        if cl.name == "BEGIN" and is_vcard:
            if open:
                raise Error(
                    _at(n)
                    + String("BEGIN:VCARD inside the card begun at line ")
                    + String(cur.begin_line)
                )
            if len(cards) >= limits.max_cards:
                raise Error(
                    _at(n)
                    + String("card ")
                    + String(len(cards) + 1)
                    + String(" is over the limit of ")
                    + String(limits.max_cards)
                    + String(" cards")
                )
            open = True
            cur = VCard(String(), n)
            continue
        if not open:
            if cl.name == "END" and is_vcard:
                raise Error(_at(n) + String("END:VCARD with no card begun"))
            raise Error(
                _at(n) + String("a property outside BEGIN:VCARD and END:VCARD")
            )
        if cl.name == "END" and is_vcard:
            if cur.version.byte_length() == 0:
                raise Error(
                    String("vcard: the card begun at line ")
                    + String(cur.begin_line)
                    + String(" has no VERSION")
                )
            cards.append(cur.copy())
            open = False
            continue
        if cl.name == "VERSION":
            if cur.version.byte_length() > 0:
                raise Error(
                    _at(n)
                    + String("a second VERSION in the card begun at line ")
                    + String(cur.begin_line)
                )
            var v = String(cl.value.strip())
            if v != "2.1" and v != "3.0" and v != "4.0":
                raise Error(
                    _at(n)
                    + String("VERSION ")
                    + v
                    + String(" is not 2.1, 3.0 or 4.0")
                )
            cur.version = v^
            continue
        var charset = _first_value(cl, "CHARSET")
        var qp = _first_value(cl, "ENCODING").upper() == "QUOTED-PRINTABLE"
        var bare_qp = cl.param("QUOTED-PRINTABLE")
        if bare_qp and not bare_qp.value().has_value:
            qp = True
        if qp:
            var value = cl.value.copy()
            while value.endswith("=") and i < len(logical):
                var cut = String(value[byte = 0 : value.byte_length() - 1])
                value = cut + logical[i].text
                i += 1
                if value.byte_length() > limits.max_line_octets:
                    raise Error(
                        String("content line: line ")
                        + String(n)
                        + String(" is longer than the ")
                        + String(limits.max_line_octets)
                        + String("-octet limit")
                    )
            cl.value = _decode_qp(value, charset, n)
            var kept = _without(cl.params, "ENCODING", "CHARSET")
            cl.params = _without(kept, "QUOTED-PRINTABLE", "QUOTED-PRINTABLE")
            text = format_content_line(cl)
        elif charset.byte_length() > 0:
            cl.params = _without(cl.params, "CHARSET", "CHARSET")
            text = format_content_line(cl)
        cur.lines.append(VCardLine(cl^, text^, n))
    if open:
        raise Error(
            String("vcard: the card begun at line ")
            + String(cur.begin_line)
            + String(" has no END:VCARD")
        )
    return cards^
