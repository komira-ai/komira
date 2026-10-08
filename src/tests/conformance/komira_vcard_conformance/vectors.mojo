# =============================================================================
# vectors.mojo -- the vCard inputs the conformance tests read.
# =============================================================================
#
# RFC vectors are the RFCs' own example text, with CRLF line breaks and the
# folds the RFC prints. Where an RFC example names a real person, address or
# host, those values are replaced with reserved example names (RFC 2606) and
# the replacement is said at the vector; the structure, parameters and folds
# are the RFC's.
#
# The vendor-shaped vectors are written for these tests in the shape the
# named products' exports take (property order, grouping, parameter
# spelling, encodings). They are not captured exports and hold no personal
# data.
# =============================================================================


def rfc6350_6_1_4_kind() -> String:
    """RFC 6350 §6.1.4, both KIND examples."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "KIND:individual\r\n"
        "FN:Jane Doe\r\n"
        "ORG:ABC\\, Inc.;North American Division;Marketing\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "KIND:org\r\n"
        "FN:ABC Marketing\r\n"
        "ORG:ABC\\, Inc.;North American Division;Marketing\r\n"
        "END:VCARD\r\n"
    )


def rfc6350_6_6_5_member() -> String:
    """RFC 6350 §6.6.5, all four cards of the MEMBER examples."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "KIND:group\r\n"
        "FN:The Doe family\r\n"
        "MEMBER:urn:uuid:03a0e51f-d1aa-4385-8a53-e29025acd8af\r\n"
        "MEMBER:urn:uuid:b8767877-b4a1-4c70-9acc-505d3819e519\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:John Doe\r\n"
        "UID:urn:uuid:03a0e51f-d1aa-4385-8a53-e29025acd8af\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Jane Doe\r\n"
        "UID:urn:uuid:b8767877-b4a1-4c70-9acc-505d3819e519\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "KIND:group\r\n"
        "FN:Funky distribution list\r\n"
        "MEMBER:mailto:subscriber1@example.com\r\n"
        "MEMBER:xmpp:subscriber2@example.com\r\n"
        "MEMBER:sip:subscriber3@example.com\r\n"
        "MEMBER:tel:+1-418-555-5555\r\n"
        "END:VCARD\r\n"
    )


def rfc6350_6_property_examples() -> String:
    """RFC 6350 §6.2.1 FN, §6.2.2 N (second example), §6.2.3 NICKNAME,
    §6.2.5 BDAY, §6.3.1 ADR, §6.4.1 TEL, §6.4.2 EMAIL, §6.6.1 TITLE, in one
    card, folded as the RFC prints them."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Mr. John Q. Public\\, Esq.\r\n"
        "N:Stevenson;John;Philip,Paul;Dr.;Jr.,M.D.,A.C.P.\r\n"
        "NICKNAME:Jim,Jimmie\r\n"
        "NICKNAME;TYPE=work:Boss\r\n"
        "BDAY:--0415\r\n"
        'ADR;GEO="geo:12.3457,78.910";LABEL="Mr. John Q. Public, Esq.\\n\r\n'
        " Mail Drop: TNE QB\\n123 Main Street\\nAny Town, CA  91921-1234\\n\r\n"
        ' U.S.A.":;;123 Main Street;Any Town;CA;91921-1234;U.S.A.\r\n'
        'TEL;VALUE=uri;PREF=1;TYPE="voice,home":tel:+1-555-555-5555;ext=5555\r\n'
        "TEL;VALUE=uri;TYPE=home:tel:+33-01-23-45-67\r\n"
        "EMAIL;TYPE=work:jqpublic@xyz.example.com\r\n"
        "EMAIL;PREF=1:jane_doe@example.com\r\n"
        "TITLE:Research Scientist\r\n"
        "END:VCARD\r\n"
    )


def rfc6350_6_2_5_bday_text() -> String:
    """RFC 6350 §6.2.5, the text-valued BDAY example `BDAY;VALUE=text:circa
    1800`, in a card of its own: the BEGIN, VERSION, FN and END lines are
    added around it."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Jane Doe\r\n"
        "BDAY;VALUE=text:circa 1800\r\n"
        "END:VCARD\r\n"
    )


def rfc6350_8_author() -> String:
    """RFC 6350 §8, the author's card. Replaced: the name (Simone Exemple),
    the e-mail address and the KEY and URL hosts (under `.example`). The
    page-break blank line in the RFC's figure is left out."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Simone Exemple\r\n"
        "N:Exemple;Simone;;;ing. jr,M.Sc.\r\n"
        "BDAY:--0203\r\n"
        "ANNIVERSARY:20090808T1430-0500\r\n"
        "GENDER:M\r\n"
        "LANG;PREF=1:fr\r\n"
        "LANG;PREF=2:en\r\n"
        "ORG;TYPE=work:Viagenie\r\n"
        "ADR;TYPE=work:;Suite D2-630;2875 Laurier;\r\n"
        " Quebec;QC;G1V 2M2;Canada\r\n"
        'TEL;VALUE=uri;TYPE="work,voice";PREF=1:tel:+1-418-656-9254;ext=102\r\n'
        'TEL;VALUE=uri;TYPE="work,cell,voice,video,text":tel:+1-418-262-6501\r\n'
        "EMAIL;TYPE=work:simone.exemple@viagenie.example\r\n"
        "GEO;TYPE=work:geo:46.772673,-71.282945\r\n"
        "KEY;TYPE=work;VALUE=uri:\r\n"
        " http://www.viagenie.example/simone.exemple/simone.asc\r\n"
        "TZ:-0500\r\n"
        "URL;TYPE=home:http://nomis80.example\r\n"
        "END:VCARD\r\n"
    )


def rfc2426_7_example() -> String:
    """RFC 2426 (vCard 3.0) §7, the first card. Replaced: the name, the
    organization, the e-mail addresses and the URL host."""
    return String(
        "BEGIN:vCard\r\n"
        "VERSION:3.0\r\n"
        "FN:Alex Exemple\r\n"
        "ORG:Example Development Corporation\r\n"
        "ADR;TYPE=WORK,POSTAL,PARCEL:;;6544 Battleford Drive\r\n"
        " ;Raleigh;NC;27613-3502;U.S.A.\r\n"
        "TEL;TYPE=VOICE,MSG,WORK:+1-919-676-9515\r\n"
        "TEL;TYPE=FAX,WORK:+1-919-676-9564\r\n"
        "EMAIL;TYPE=INTERNET,PREF:Alex_Exemple@example.com\r\n"
        "EMAIL;TYPE=INTERNET:aexemple@example.net\r\n"
        "URL:http://home.example.net/~aexemple\r\n"
        "END:vCard\r\n"
    )


def rfc9555_figures() -> String:
    """RFC 9555 §2, the vCard side of Figures 7, 9 (BDAY), 10, 12, 13, 15,
    16, 21, 25, 27, 34, 38, 39 and 40, one card each, folded as printed."""
    return String(
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 1: Figure 7, 10, 38
        "KIND:individual\r\n"
        "FN:John Q. Public, Esq.\r\n"
        "UID:urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 2: Figure 12
        'N;SORT-AS="Stevenson,John Philip":\r\n'
        " Stevenson;John;Philip,Paul;Dr.;Jr.,M.D.,A.C.P.;;Jr.\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 3: Figure 13, 9
        "NICKNAME:Johnny\r\n"
        "BDAY:19531015T231000Z\r\n"
        "BIRTHPLACE:\r\n"
        " 123 Main Street\\nAny Town, CA 91921-1234\\nU.S.A.\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 4: Figure 15
        "ADR;TYPE=work;CC=US:\r\n"
        " ;;54321 Oak St;Reston;VA;20190;USA;;;;54321;Oak St;;;;;;\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 5: Figure 16, 21
        "EMAIL;TYPE=work:jqpublic@xyz.example.com\r\n"
        "EMAIL;PREF=1:jane_doe@example.com\r\n"
        'TEL;VALUE=uri;PREF=1;TYPE="voice,home":tel:+1-555-555-5555;ext=5555\r\n'
        "TEL;VALUE=uri;TYPE=home:tel:+33-01-23-45-67\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 6: Figure 25
        'ORG;SORT-AS="ABC":ABC\\, Inc.;North American Division;Marketing\r\n'
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 7: Figure 27
        "TITLE:Research Scientist\r\n"
        "group1.ROLE:Project Leader\r\n"
        "group1.ORG:ABC, Inc.\r\n"
        "END:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\n"  # card 8: Figure 34, 39, 40
        'NOTE;CREATED=20221123T150132Z;AUTHOR-NAME="John":\r\n'
        " Office hours are from 0800 to 1715 EST\\, Mon-Fri.\r\n"
        "URL:https://example.org/restaurant.french/~chezchic.html\r\n"
        "item1.TEL;VALUE=uri:tel:+1-555-555-5555\r\n"
        "item1.X-ABLabel:foo\r\n"
        "END:VCARD\r\n"
    )


def apple_shaped_3_0() -> String:
    """A vCard 3.0 in the shape Apple Contacts exports: PRODID first, `item<n>`
    groups with X-ABLabel, `type=` repeated, TYPE=pref, URL with `\\:`."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:3.0\r\n"
        "PRODID:-//Apple Inc.//macOS 14.0//EN\r\n"
        "N:Exemple;Alex;;;\r\n"
        "FN:Alex Exemple\r\n"
        "ORG:Example Corp;Research\r\n"
        "TITLE:Engineer\r\n"
        "item1.EMAIL;type=INTERNET;type=pref:alex@example.com\r\n"
        "item1.X-ABLabel:_$!<Other>!$_\r\n"
        "EMAIL;type=INTERNET;type=HOME:alex.home@example.net\r\n"
        "TEL;type=CELL;type=VOICE;type=pref:+1 (555) 010-0001\r\n"
        "item2.ADR;type=HOME;type=pref:;;1 Loop Road\\nApt 2;Cupertino;CA;95\r\n"
        " 014;United States\r\n"
        "item2.X-ABADR:us\r\n"
        "item3.URL;type=pref:https\\://example.com/alex\r\n"
        "item3.X-ABLabel:_$!<HomePage>!$_\r\n"
        "BDAY:1980-05-04\r\n"
        "NOTE:Met at the conference\\, follow up.\r\n"
        "X-SOCIALPROFILE;type=example:https://social.example/alex\r\n"
        "UID:6A5C1B44-0E2B-4F7D-9C55-0D6B1D3A2F10\r\n"
        "END:VCARD\r\n"
    )


def outlook_shaped_2_1() -> String:
    """A vCard 2.1 in the shape Outlook exports: bare TYPE parameters,
    quoted-printable values with soft breaks, LANGUAGE on N, X-MS-* lines."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:2.1\r\n"
        "N;LANGUAGE=en-us:Exemple;Alex\r\n"
        "FN:Alex Exemple\r\n"
        "ORG:Example Corp\r\n"
        "TITLE:Engineer\r\n"
        "TEL;WORK;VOICE:(555) 010-0002\r\n"
        "TEL;CELL;VOICE:(555) 010-0003\r\n"
        "ADR;WORK;PREF:;;1 Main Street;Springfield;IL;62701;United States of"
        " America\r\n"
        "LABEL;WORK;PREF;ENCODING=QUOTED-PRINTABLE:1 Main Street=0D=0ASpringfie"
        "ld, IL 62701=0D=0AUnited States of Am=\r\n"
        "erica\r\n"
        "EMAIL;PREF;INTERNET:alex@example.com\r\n"
        "NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:Caf=C3=A9 meeting=0D=0Anext"
        " week\r\n"
        "X-MS-OL-DEFAULT-POSTAL-ADDRESS:2\r\n"
        "REV:20260915T120000Z\r\n"
        "END:VCARD\r\n"
    )


def google_shaped_3_0() -> String:
    """A vCard 3.0 in the shape Google Contacts exports: TYPE=INTERNET on
    EMAIL, a labelled URL in an item group, CATEGORIES."""
    return String(
        "BEGIN:VCARD\r\n"
        "VERSION:3.0\r\n"
        "FN:Alex Exemple\r\n"
        "N:Exemple;Alex;;;\r\n"
        "EMAIL;TYPE=INTERNET;TYPE=WORK:alex@example.com\r\n"
        "TEL;TYPE=CELL:+1 555-010-0004\r\n"
        "ADR;TYPE=HOME:;;2 Side St;Town;;12345;US\r\n"
        "ORG:Example Corp\r\n"
        "TITLE:Engineer\r\n"
        "BDAY:2001-02-03\r\n"
        "item1.URL:https\\://example.org/alex\r\n"
        "item1.X-ABLabel:profile\r\n"
        "CATEGORIES:myContacts,Friends\r\n"
        "NOTE:Line one\\nLine two\r\n"
        "END:VCARD\r\n"
    )
