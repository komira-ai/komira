# =============================================================================
# write.mojo -- `Contact`s to vCard 4.0 text (RFC 6350).
# =============================================================================
#
# One card per contact, CRLF line breaks, every line folded at 75 octets:
#
#   BEGIN:VCARD / VERSION:4.0 / KIND (when not "individual") / UID (when set)
#   / FN (always; RFC 6350 requires it) / N (when it has components) /
#   NICKNAME (when any) / ORG (when set) / TITLE / EMAIL... / TEL... / ADR... /
#   URL... / BDAY / NOTE (when set) / MEMBER... / the `extra` lines / END:VCARD
#
# Text values are escaped (komira_content_line text.mojo); N and ADR join
# values with "," and components with ";" after escaping each value. A TEL
# whose value starts with "tel:" and holds no backslash or line break is
# written as VALUE=uri, unescaped, as RFC 6350 §6.4.1 shows. An EMAIL, TEL,
# ADR or URL with a label is written with a group and a `<group>.X-ABLabel`
# line after it; with no group of its own it gets `item<k>`, the first k no
# other line of the contact uses.
#
# Nothing a contact holds can start a line of its own: a value's line breaks
# are escaped, a group, TYPE value or `extra` line that would break the line
# or the grammar is refused (format_content_line), and an `extra` line must
# lex as a content line and must not be BEGIN:VCARD, END:VCARD or VERSION.
# =============================================================================

from komira_content_line import (
    ContentLine,
    Param,
    escape_text,
    fold_line,
    format_content_line,
    parse_content_line,
)

from .contact import Contact, ContactAddress, ContactValue


def _line(
    mut out: String, group: String, name: String, var params: List[Param],
    value: String
) raises:
    var cl = ContentLine(group.copy(), name.copy(), params^, value.copy())
    out += fold_line(format_content_line(cl))


def _join_escaped(values: List[String], sep: String) -> String:
    var out = String()
    for i in range(len(values)):
        if i > 0:
            out += sep
        out += escape_text(values[i])
    return out^


def _compound(parts: List[List[String]]) -> String:
    var out = String()
    for i in range(len(parts)):
        if i > 0:
            out += ";"
        out += _join_escaped(parts[i], ",")
    return out^


def _tag_params(types: List[String], pref: Int) -> List[Param]:
    var params = List[Param]()
    if len(types) > 0:
        params.append(Param("TYPE", types.copy()))
    if pref > 0:
        var v = List[String]()
        v.append(String(pref))
        params.append(Param("PREF", v^))
    return params^


struct _Groups(Movable):
    var used: List[String]
    var next: Int

    def __init__(out self, c: Contact):
        self.used = List[String]()
        self.next = 1
        for i in range(len(c.emails)):
            self.used.append(c.emails[i].group.lower())
        for i in range(len(c.phones)):
            self.used.append(c.phones[i].group.lower())
        for i in range(len(c.addresses)):
            self.used.append(c.addresses[i].group.lower())
        for i in range(len(c.urls)):
            self.used.append(c.urls[i].group.lower())
        for i in range(len(c.extra)):
            var dot = c.extra[i].find(".")
            var colon = c.extra[i].find(":")
            if dot > 0 and (colon < 0 or dot < colon):
                self.used.append(String(c.extra[i][byte=0:dot]).lower())

    def group_for(mut self, group: String, label: String) -> String:
        if group.byte_length() > 0 or label.byte_length() == 0:
            return group.copy()
        while True:
            var g = String("item") + String(self.next)
            self.next += 1
            var clash = False
            for i in range(len(self.used)):
                if self.used[i] == g:
                    clash = True
            if not clash:
                self.used.append(g.copy())
                return g^


def _label(mut out: String, group: String, label: String) raises:
    if label.byte_length() > 0:
        _line(out, group, "X-ABLabel", List[Param](), escape_text(label))


def _tel_is_uri(value: String) -> Bool:
    if not value.lower().startswith("tel:"):
        return False
    var b = value.as_bytes()
    for i in range(len(b)):
        if b[i] == 92 or b[i] == 10 or b[i] == 13:
            return False
    return True


def _values(
    mut out: String,
    mut groups: _Groups,
    name: String,
    values: List[ContactValue],
) raises:
    for i in range(len(values)):
        ref v = values[i]
        var g = groups.group_for(v.group, v.label)
        var params = _tag_params(v.types, v.pref)
        var text: String
        if name == "TEL" and _tel_is_uri(v.value):
            var uri = List[String]()
            uri.append("uri")
            params.insert(0, Param("VALUE", uri^))
            text = v.value.copy()
        else:
            text = escape_text(v.value)
        _line(out, g, name, params^, text)
        _label(out, g, v.label)


def emit_contact(c: Contact) raises -> String:
    """`c` as one vCard 4.0 card (file header)."""
    var out = String("BEGIN:VCARD\r\nVERSION:4.0\r\n")
    var groups = _Groups(c)
    var none = String()
    if c.kind != "individual":
        _line(out, none, "KIND", List[Param](), escape_text(c.kind))
    if c.uid.byte_length() > 0:
        _line(out, none, "UID", List[Param](), escape_text(c.uid))
    _line(out, none, "FN", List[Param](), escape_text(c.full_name))
    if len(c.name) > 0:
        _line(out, none, "N", List[Param](), _compound(c.name))
    if len(c.nicknames) > 0:
        _line(
            out, none, "NICKNAME", List[Param](), _join_escaped(c.nicknames, ",")
        )
    if len(c.organization) > 0:
        _line(
            out, none, "ORG", List[Param](), _join_escaped(c.organization, ";")
        )
    if c.title.byte_length() > 0:
        _line(out, none, "TITLE", List[Param](), escape_text(c.title))
    _values(out, groups, "EMAIL", c.emails)
    _values(out, groups, "TEL", c.phones)
    for i in range(len(c.addresses)):
        ref a = c.addresses[i]
        var g = groups.group_for(a.group, a.label)
        _line(out, g, "ADR", _tag_params(a.types, a.pref), _compound(a.parts))
        _label(out, g, a.label)
    _values(out, groups, "URL", c.urls)
    if c.birthday.byte_length() > 0:
        _line(out, none, "BDAY", List[Param](), escape_text(c.birthday))
    if c.note.byte_length() > 0:
        _line(out, none, "NOTE", List[Param](), escape_text(c.note))
    for i in range(len(c.members)):
        _line(out, none, "MEMBER", List[Param](), escape_text(c.members[i]))
    for i in range(len(c.extra)):
        ref x = c.extra[i]
        var xb = x.as_bytes()
        for k in range(len(xb)):
            if xb[k] == 10 or xb[k] == 13:
                raise Error(
                    String("vcard: extra line ")
                    + String(i + 1)
                    + String(" holds a line break")
                )
        var xl = parse_content_line(x, i + 1)
        if xl.name == "VERSION" or (
            (xl.name == "BEGIN" or xl.name == "END")
            and xl.value.upper() == "VCARD"
        ):
            raise Error(
                String("vcard: extra line ")
                + String(i + 1)
                + String(" is a BEGIN:VCARD, END:VCARD or VERSION line")
            )
        out += fold_line(x)
    out += "END:VCARD\r\n"
    return out^


def emit_contacts(contacts: List[Contact]) raises -> String:
    """Every contact as a vCard 4.0 card, in order."""
    var out = String()
    for i in range(len(contacts)):
        out += emit_contact(contacts[i])
    return out^
