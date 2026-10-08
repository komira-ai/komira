# =============================================================================
# read.mojo -- raw cards to `Contact`s (the mapping is in contact.mojo).
# =============================================================================
#
# Compound values (N, ADR) are split on unescaped ";" into components, each
# component on unescaped "," into values, and only then unescaped; ORG is
# split on ";" only (its components are single values, RFC 9555 §2.9.4);
# NICKNAME on "," only.
#
# A UID, BDAY, URL or MEMBER line with VALUE=text is not mapped: its value
# type is not the property's default (URI, date-and-or-time, URI, URI), and
# `Contact` has no field for it, so the line is kept whole in `extra`, as
# RFC 9555 §2.15.1 keeps a value with no JSContact counterpart in vCardProps
# (for UID and BDAY it is taken as the property's one line, so a later UID
# or BDAY line goes to `extra` too).
#
# Parameters a mapping accepts: TYPE and PREF on EMAIL, TEL, ADR and URL (and
# a vCard 2.1 bare parameter, read as a TYPE value, or as PREF), VALUE=uri on
# TEL, and VALUE=text on the other mapped properties, whose value type is text
# by default, so the parameter changes nothing and is not written back. Any
# other parameter of a mapped line is named in
# `ContactImport.dropped` as
#     card <k> line <n>: <PROPERTY> parameter <NAME> not kept
# where k counts cards from 1, and so is the group of a mapped property that
# is not EMAIL, TEL, ADR or URL (`card <k> line <n>: ORG group <g> not
# kept`). An unknown property loses nothing: it is kept whole in `extra`.
# =============================================================================

from komira_content_line import Param, split_unescaped, unescape_text

from .card import VCard, VCardLimits, VCardLine, parse_vcards
from .contact import Contact, ContactAddress, ContactImport, ContactValue


def _components(value: String, lists: Bool) -> List[List[String]]:
    var out = List[List[String]]()
    var fields = split_unescaped(value, 59)
    for i in range(len(fields)):
        var vals = List[String]()
        if lists:
            var pieces = split_unescaped(fields[i], 44)
            for j in range(len(pieces)):
                vals.append(unescape_text(pieces[j]))
        else:
            vals.append(unescape_text(fields[i]))
        out.append(vals^)
    return out^


def _drop(
    mut dropped: List[String], card: Int, vl: VCardLine, param: String
):
    dropped.append(
        String("card ")
        + String(card)
        + String(" line ")
        + String(vl.line_number)
        + String(": ")
        + vl.line.name
        + String(" parameter ")
        + param
        + String(" not kept")
    )


def _is_text_value(p: Param) -> Bool:
    return (
        p.name == "VALUE"
        and len(p.values) == 1
        and p.values[0].lower() == "text"
    )


def _text_on_non_text(vl: VCardLine) -> Bool:
    ref name = vl.line.name
    if not (
        name == "UID" or name == "BDAY" or name == "URL" or name == "MEMBER"
    ):
        return False
    for k in range(len(vl.line.params)):
        if _is_text_value(vl.line.params[k]):
            return True
    return False


def _report_all(mut dropped: List[String], card: Int, vl: VCardLine):
    if vl.line.group.byte_length() > 0:
        dropped.append(
            String("card ")
            + String(card)
            + String(" line ")
            + String(vl.line_number)
            + String(": ")
            + vl.line.name
            + String(" group ")
            + vl.line.group
            + String(" not kept")
        )
    for k in range(len(vl.line.params)):
        ref p = vl.line.params[k]
        if not _is_text_value(p):
            _drop(dropped, card, vl, p.name)


struct _Tags(Movable):
    var types: List[String]
    var pref: Int
    var uri: Bool

    def __init__(out self):
        self.types = List[String]()
        self.pref = 0
        self.uri = False


def _parse_pref(s: String) -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 3:
        return 0
    var v = 0
    for i in range(len(b)):
        if b[i] < 48 or b[i] > 57:
            return 0
        v = v * 10 + Int(b[i]) - 48
    if v < 1 or v > 100:
        return 0
    return v


def _tags(mut dropped: List[String], card: Int, vl: VCardLine) -> _Tags:
    var t = _Tags()
    var type_pref = False
    for k in range(len(vl.line.params)):
        ref p = vl.line.params[k]
        if not p.has_value:
            if p.name == "PREF":
                type_pref = True
            else:
                t.types.append(p.name.lower())
            continue
        if p.name == "TYPE":
            for j in range(len(p.values)):
                var pieces = p.values[j].split(",")
                for q in range(len(pieces)):
                    var ty = String(pieces[q]).lower()
                    if ty == "pref":
                        type_pref = True
                    elif ty.byte_length() > 0:
                        t.types.append(ty^)
            continue
        if p.name == "PREF" and len(p.values) == 1:
            var v = _parse_pref(p.values[0])
            if v > 0:
                t.pref = v
                continue
        if (
            p.name == "VALUE"
            and vl.line.name == "TEL"
            and len(p.values) == 1
            and p.values[0].lower() == "uri"
        ):
            t.uri = True
            continue
        if _is_text_value(p):
            continue
        _drop(dropped, card, vl, p.name)
    if t.pref == 0 and type_pref:
        t.pref = 1
    return t^


def _value(vl: VCardLine, t: _Tags) -> ContactValue:
    var v = ContactValue(
        vl.line.value.copy() if t.uri else unescape_text(vl.line.value)
    )
    v.group = vl.line.group.copy()
    v.types = t.types.copy()
    v.pref = t.pref
    return v^


def _set_label(mut c: Contact, group: String, label: String) -> Bool:
    for i in range(len(c.emails)):
        if c.emails[i].group == group and c.emails[i].label.byte_length() == 0:
            c.emails[i].label = label.copy()
            return True
    for i in range(len(c.phones)):
        if c.phones[i].group == group and c.phones[i].label.byte_length() == 0:
            c.phones[i].label = label.copy()
            return True
    for i in range(len(c.addresses)):
        if (
            c.addresses[i].group == group
            and c.addresses[i].label.byte_length() == 0
        ):
            c.addresses[i].label = label.copy()
            return True
    for i in range(len(c.urls)):
        if c.urls[i].group == group and c.urls[i].label.byte_length() == 0:
            c.urls[i].label = label.copy()
            return True
    return False


def contact_from_vcard(
    card: VCard, card_number: Int, mut dropped: List[String]
) -> Contact:
    """Map one raw card (file header); `card_number` counts from 1 and is
    used in `dropped` lines only."""
    var c = Contact()
    var seen = List[String]()
    var labels = List[Int]()
    for k in range(len(card.lines)):
        ref vl = card.lines[k]
        ref name = vl.line.name
        var single = (
            name == "KIND"
            or name == "UID"
            or name == "FN"
            or name == "N"
            or name == "ORG"
            or name == "TITLE"
            or name == "BDAY"
            or name == "NOTE"
        )
        if single:
            var taken = False
            for s in range(len(seen)):
                if seen[s] == name:
                    taken = True
            if taken:
                c.extra.append(vl.text.copy())
                continue
            seen.append(name.copy())
            if _text_on_non_text(vl):
                c.extra.append(vl.text.copy())
                continue
            _report_all(dropped, card_number, vl)
            if name == "KIND":
                c.kind = unescape_text(vl.line.value).lower()
            elif name == "UID":
                c.uid = unescape_text(vl.line.value)
            elif name == "FN":
                c.full_name = unescape_text(vl.line.value)
            elif name == "N":
                c.name = _components(vl.line.value, True)
            elif name == "ORG":
                var org = _components(vl.line.value, False)
                for j in range(len(org)):
                    c.organization.append(org[j][0].copy())
            elif name == "TITLE":
                c.title = unescape_text(vl.line.value)
            elif name == "BDAY":
                c.birthday = unescape_text(vl.line.value)
            else:
                c.note = unescape_text(vl.line.value)
        elif _text_on_non_text(vl):
            c.extra.append(vl.text.copy())
        elif name == "NICKNAME":
            _report_all(dropped, card_number, vl)
            var pieces = split_unescaped(vl.line.value, 44)
            for j in range(len(pieces)):
                c.nicknames.append(unescape_text(pieces[j]))
        elif name == "MEMBER":
            _report_all(dropped, card_number, vl)
            c.members.append(unescape_text(vl.line.value))
        elif name == "EMAIL":
            c.emails.append(_value(vl, _tags(dropped, card_number, vl)))
        elif name == "TEL":
            c.phones.append(_value(vl, _tags(dropped, card_number, vl)))
        elif name == "URL":
            c.urls.append(_value(vl, _tags(dropped, card_number, vl)))
        elif name == "ADR":
            var t = _tags(dropped, card_number, vl)
            var a = ContactAddress(_components(vl.line.value, True))
            a.group = vl.line.group.copy()
            a.types = t.types.copy()
            a.pref = t.pref
            c.addresses.append(a^)
        elif name == "X-ABLABEL" and vl.line.group.byte_length() > 0:
            labels.append(k)
        else:
            c.extra.append(vl.text.copy())
    for i in range(len(labels)):
        ref vl = card.lines[labels[i]]
        if not _set_label(c, vl.line.group, unescape_text(vl.line.value)):
            c.extra.append(vl.text.copy())
    return c^


def parse_contacts(
    data: Span[UInt8, _], limits: VCardLimits = VCardLimits()
) raises -> ContactImport:
    """Every card in `data` as a `Contact`, plus the parameters the mapping
    did not keep. Raises on input `parse_vcards` refuses."""
    var cards = parse_vcards(data, limits)
    var out = ContactImport()
    var dropped = List[String]()
    for i in range(len(cards)):
        var c = contact_from_vcard(cards[i], i + 1, dropped)
        out.contacts.append(c^)
    out.dropped = dropped^
    return out^
