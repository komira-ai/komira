# =============================================================================
# contact.mojo -- the contact subset a card maps to (RFC 9555-guided).
# =============================================================================
#
# One `Contact` per card. The mapped properties, and the RFC 9555 section
# whose conversion each follows:
#
#   KIND      kind          lower-cased; "individual" when absent (§2.4.2)
#   UID       uid           (§2.11.8)
#   FN        full_name     (§2.5.2)
#   N         name          components, each a list of values (§2.5.5)
#   NICKNAME  nicknames     every value of every NICKNAME line (§2.5.6)
#   ORG       organization  [name, unit, unit, ...] (§2.9.4)
#   TITLE     title         (§2.9.6)
#   EMAIL     emails        (§2.7.1)
#   TEL       phones        (§2.7.6)
#   ADR       addresses     components, each a list of values (§2.6.1)
#   URL       urls          (§2.11.9)
#   BDAY      birthday      the value as written (§2.5.1)
#   NOTE      note          (§2.11.4)
#   MEMBER    members       (§2.9.3)
#   X-ABLabel the label of the EMAIL/TEL/ADR/URL in the same group (§2.11.11)
#
# EMAIL, TEL, ADR and URL keep their group, TYPE values (lower-cased, minus
# "pref") and preference (PREF=1..100, or TYPE=pref / a bare PREF as 1; 0 is
# none). A TEL with VALUE=uri keeps its value as written; every other value is
# unescaped (komira_content_line text.mojo).
#
# A single-valued property (KIND, UID, FN, N, ORG, TITLE, BDAY, NOTE) maps
# from its first line; a later line, every property not listed above, and an
# X-ABLabel with no labelled sibling are kept in `extra` as the unfolded line,
# so writing the contact out again loses none of them. So is a UID, BDAY, URL
# or MEMBER line with VALUE=text (read.mojo).
# =============================================================================


def _strings_eq(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _parts_eq(a: List[List[String]], b: List[List[String]]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not _strings_eq(a[i], b[i]):
            return False
    return True


struct ContactValue(Copyable, Movable, Equatable):
    """An EMAIL, TEL or URL: the value and how it was tagged."""

    var value: String
    var group: String
    var types: List[String]
    var pref: Int
    var label: String

    def __init__(out self, var value: String):
        self.value = value^
        self.group = String()
        self.types = List[String]()
        self.pref = 0
        self.label = String()

    def __eq__(self, other: Self) -> Bool:
        return (
            self.value == other.value
            and self.group == other.group
            and _strings_eq(self.types, other.types)
            and self.pref == other.pref
            and self.label == other.label
        )


struct ContactAddress(Copyable, Movable, Equatable):
    """An ADR: its components (post office box, extended address, street,
    locality, region, postal code, country, then any RFC 9554 components),
    each a list of values, and how it was tagged."""

    var parts: List[List[String]]
    var group: String
    var types: List[String]
    var pref: Int
    var label: String

    def __init__(out self, var parts: List[List[String]]):
        self.parts = parts^
        self.group = String()
        self.types = List[String]()
        self.pref = 0
        self.label = String()

    def component(self, index: Int) -> String:
        """Component `index`'s values joined by ", " ("" when absent)."""
        if index >= len(self.parts):
            return String()
        return String(", ").join(self.parts[index])

    def __eq__(self, other: Self) -> Bool:
        return (
            _parts_eq(self.parts, other.parts)
            and self.group == other.group
            and _strings_eq(self.types, other.types)
            and self.pref == other.pref
            and self.label == other.label
        )


struct Contact(Copyable, Movable, Equatable):
    """The mapped subset of one card (file header)."""

    var kind: String
    var uid: String
    var full_name: String
    var name: List[List[String]]
    var nicknames: List[String]
    var organization: List[String]
    var title: String
    var emails: List[ContactValue]
    var phones: List[ContactValue]
    var addresses: List[ContactAddress]
    var urls: List[ContactValue]
    var birthday: String
    var note: String
    var members: List[String]
    var extra: List[String]

    def __init__(out self):
        self.kind = String("individual")
        self.uid = String()
        self.full_name = String()
        self.name = List[List[String]]()
        self.nicknames = List[String]()
        self.organization = List[String]()
        self.title = String()
        self.emails = List[ContactValue]()
        self.phones = List[ContactValue]()
        self.addresses = List[ContactAddress]()
        self.urls = List[ContactValue]()
        self.birthday = String()
        self.note = String()
        self.members = List[String]()
        self.extra = List[String]()

    def name_component(self, index: Int) -> String:
        """N component `index` (0 family, 1 given, 2 additional, 3 prefixes,
        4 suffixes) with its values joined by " " ("" when absent)."""
        if index >= len(self.name):
            return String()
        return String(" ").join(self.name[index])

    def __eq__(self, other: Self) -> Bool:
        if len(self.emails) != len(other.emails):
            return False
        for i in range(len(self.emails)):
            if self.emails[i] != other.emails[i]:
                return False
        if len(self.phones) != len(other.phones):
            return False
        for i in range(len(self.phones)):
            if self.phones[i] != other.phones[i]:
                return False
        if len(self.urls) != len(other.urls):
            return False
        for i in range(len(self.urls)):
            if self.urls[i] != other.urls[i]:
                return False
        if len(self.addresses) != len(other.addresses):
            return False
        for i in range(len(self.addresses)):
            if self.addresses[i] != other.addresses[i]:
                return False
        return (
            self.kind == other.kind
            and self.uid == other.uid
            and self.full_name == other.full_name
            and _parts_eq(self.name, other.name)
            and _strings_eq(self.nicknames, other.nicknames)
            and _strings_eq(self.organization, other.organization)
            and self.title == other.title
            and self.birthday == other.birthday
            and self.note == other.note
            and _strings_eq(self.members, other.members)
            and _strings_eq(self.extra, other.extra)
        )


struct ContactImport(Movable):
    """The contacts read from one input, and one line per parameter of a
    mapped property that the mapping did not keep."""

    var contacts: List[Contact]
    var dropped: List[String]

    def __init__(out self):
        self.contacts = List[Contact]()
        self.dropped = List[String]()
