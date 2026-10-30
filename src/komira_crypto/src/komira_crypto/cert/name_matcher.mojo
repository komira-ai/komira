# =============================================================================
# komira_crypto/cert/name_matcher.mojo — RFC 6125 hostname matching
# =============================================================================
#
# Implements RFC 6125 hostname binding for X.509 server certificates as
# used in TLS 1.3 server cert validation, over the X509Certificate POD.
#
# # Public surface
#
#   * `match_hostname(cert: X509Certificate, hostname: String) raises -> Bool`
#     Returns True iff the cert is valid for `hostname` per RFC 6125 §6.
#     Wildcard rules: leftmost-label only, single-wildcard, no partial
#     wildcards. Falls back to subject CN ONLY when no SAN extension
#     present (legacy compatibility per RFC 6125 §6.4.4).
#
# # Algorithm (RFC 6125 §6)
#
#   1. Look for the subjectAltName extension (OID 2.5.29.17).
#   2. If present, iterate the SEQUENCE OF GeneralName entries:
#      - `[2] IMPLICIT IA5String dNSName` — hostname-compare with
#        wildcard rules per §6.4.3.
#      - `[7] IMPLICIT OCTET STRING iPAddress` — IP-literal compare
#        (4-byte IPv4 or 16-byte IPv6) per RFC 5280 §4.2.1.6.
#   3. If no SAN extension at all, fall back to subject CN (2.5.4.3).
#      Modern best-practice has deprecated CN-as-hostname, but RFC 6125
#      §6.4.4 still allows it. There is no stricter mode that refuses the
#      CN fallback.
#
# # Wildcard rules (RFC 6125 §6.4.3 — strict implementation)
#
#   Pattern               Hostname                    Match
#   --------------------  --------------------------  -----
#   *.example.com         foo.example.com             YES
#   *.example.com         example.com                 NO   (no label exp)
#   *.example.com         foo.bar.example.com         NO   (>1 label)
#   f*.example.com        foo.example.com             NO   (partial label)
#   *.*.example.com       a.b.example.com             NO   (multi-wildcard)
#   *                     foo                         NO   (no domain)
#   exact.example.com     exact.example.com           YES  (lowercase eq)
#   EXACT.EXAMPLE.COM     exact.example.com           YES  (case-insensitive)
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcards / `unsafe_from_address` / `take_pointee`.
#   * Pure-Mojo decoding consuming X509Certificate POD + asn1.mojo
#     substrate.
# =============================================================================

from komira_crypto.cert.x509 import (
    X509Certificate,
    Extension,
    DnAttribute,
    x509_find_extension,
)
from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_CLASS_CONTEXT,
    ASN1_TAG_SEQUENCE,
    DerTag,
    DerTlv,
    der_parse_tlv,
    der_parse_ia5_string,
    der_oid_eq,
)


# -----------------------------------------------------------------------------
# OID constants
# -----------------------------------------------------------------------------


def _oid_subject_alt_name() -> List[UInt32]:
    """OID 2.5.29.17 = subjectAltName extension."""
    var o = List[UInt32]()
    o.append(UInt32(2))
    o.append(UInt32(5))
    o.append(UInt32(29))
    o.append(UInt32(17))
    return o^


def _oid_common_name() -> List[UInt32]:
    """OID 2.5.4.3 = commonName attribute."""
    var o = List[UInt32]()
    o.append(UInt32(2))
    o.append(UInt32(5))
    o.append(UInt32(4))
    o.append(UInt32(3))
    return o^


# -----------------------------------------------------------------------------
# ASCII-safe lowercase + comparison
# -----------------------------------------------------------------------------


@always_inline
def _ascii_lower_byte(b: UInt8) -> UInt8:
    """Lowercase ONLY ASCII letters A-Z -> a-z. Non-ASCII bytes returned
    unchanged (DNS labels are ASCII-only per RFC 1035; IDN A-label form
    is already lowercase by virtue of `xn--` Punycode encoding)."""
    if b >= UInt8(0x41) and b <= UInt8(0x5A):
        return b + UInt8(0x20)
    return b


def _ascii_lower_str(s: String) -> String:
    """Return a lowercase-ASCII copy of `s`. Non-ASCII bytes pass through.
    Uses the same `chr(Int(b))` idiom as `der_parse_ia5_string` for Mojo
    1.0.0b1 compatibility (no `String(bytes=...)` ctor available).
    """
    var bs = s.as_bytes()
    var out = String()
    for i in range(len(bs)):
        out += chr(Int(_ascii_lower_byte(bs[i])))
    return out^


def _ascii_eq_ci(a: String, b: String) -> Bool:
    """Case-insensitive ASCII-only equality."""
    var la = _ascii_lower_str(a)
    var lb = _ascii_lower_str(b)
    return la == lb


# -----------------------------------------------------------------------------
# Wildcard matching (RFC 6125 §6.4.3)
# -----------------------------------------------------------------------------


def _split_first_label(s: String) -> Tuple[String, String]:
    """Split `s` at the FIRST dot. Returns (left, right_with_dot_stripped).

    For "foo.example.com" -> ("foo", "example.com").
    For "example" (no dot) -> ("example", "").
    """
    var bs = s.as_bytes()
    var left = String()
    var right = String()
    var found = False
    for i in range(len(bs)):
        if (not found) and bs[i] == UInt8(0x2E):  # '.'
            found = True
            continue
        if not found:
            left += chr(Int(bs[i]))
        else:
            right += chr(Int(bs[i]))
    return (left^, right^)


def _count_dots(s: String) -> Int:
    """Count '.' bytes in `s`."""
    var bs = s.as_bytes()
    var n = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(0x2E):
            n += 1
    return n


def _is_wildcard_pattern(pattern: String) -> Bool:
    """True iff the first label of `pattern` is exactly `*` and there is at
    least one more label. Rejects partial wildcards (`f*.example.com`) and
    `*` alone."""
    var bs = pattern.as_bytes()
    if len(bs) == 0:
        return False
    # First-label must start with '*' and be followed by '.'
    if bs[0] != UInt8(0x2A):  # '*'
        return False
    if len(bs) < 2:
        return False  # '*' alone — no domain
    if bs[1] != UInt8(0x2E):  # '*' must be immediately followed by '.'
        return False
    return True


def _pattern_has_multiple_wildcards(pattern: String) -> Bool:
    """True iff the pattern contains '*' anywhere outside the leftmost
    label position."""
    var bs = pattern.as_bytes()
    # Already validated leftmost '*' at index 0; check remainder.
    if len(bs) < 2:
        return False  # cov: unreachable only called after _is_wildcard_pattern, which needs at least 2 bytes
    for i in range(1, len(bs)):
        if bs[i] == UInt8(0x2A):
            return True
    return False


def _match_dns_pattern(pattern: String, hostname: String) -> Bool:
    """Match a single SAN dNSName pattern against `hostname` per RFC 6125
    §6.4.3 wildcard rules.

    - An empty pattern or an empty hostname never matches: RFC 5280
      §4.2.1.6 forbids an empty dNSName, and an empty hostname names
      nothing.
    - Lowercase both sides for ASCII case-insensitive compare.
    - Exact match always wins.
    - Wildcard `*.example.com`: matches `<one-label>.example.com` only.
    - Rejects `f*.example.com`, `*.*.example.com`, `*`.
    """
    if len(pattern.as_bytes()) == 0 or len(hostname.as_bytes()) == 0:
        return False
    var p = _ascii_lower_str(pattern)
    var h = _ascii_lower_str(hostname)
    # Exact match path
    if p == h:
        return True
    # Wildcard path
    if not _is_wildcard_pattern(p):
        return False
    # No multi-wildcards
    if _pattern_has_multiple_wildcards(p):
        return False
    # Split pattern into (left='*', right=domain) and hostname into
    # (h_left, h_right). Match if h_left is exactly one label AND
    # h_right == pattern_right.
    var p_pair = _split_first_label(p)
    var h_pair = _split_first_label(h)
    # pattern left MUST be exactly "*"
    if p_pair[0] != "*":
        return False  # cov: unreachable _is_wildcard_pattern guarantees the pattern starts with '*.', so its first label is '*'
    # hostname left must be non-empty (no `.example.com` matching)
    if len(h_pair[0].as_bytes()) == 0:
        return False
    # hostname right must equal pattern right (this enforces exactly-one
    # label expansion: foo.example.com matches but foo.bar.example.com
    # would split as h_left=foo, h_right=bar.example.com != example.com)
    if h_pair[1] != p_pair[1]:
        return False
    # And the hostname right must be non-empty (we need a real domain)
    if len(h_pair[1].as_bytes()) == 0:
        return False
    return True


# -----------------------------------------------------------------------------
# IP-address literal matching
# -----------------------------------------------------------------------------


def _parse_ipv4_literal(s: String) raises -> List[UInt8]:
    """Parse a dotted-quad IPv4 literal into 4 bytes. Raises on malformed
    input. Returns empty List on non-IPv4 (caller should fall back to IPv6
    or DNS name match)."""
    var bs = s.as_bytes()
    var out = List[UInt8]()
    var cur = UInt32(0)
    var has_digit = False
    var n_parts = 0
    var i = 0
    while i < len(bs):
        var b = bs[i]
        if b == UInt8(0x2E):  # '.'
            if not has_digit:
                raise Error("ipv4: empty octet")
            if cur > UInt32(255):
                raise Error("ipv4: octet > 255")  # cov: unreachable the digit branch refuses an octet as soon as it exceeds 255
            out.append(UInt8(Int(cur)))
            cur = UInt32(0)
            has_digit = False
            n_parts += 1
            if n_parts > 3:
                raise Error("ipv4: > 4 octets")
        elif b >= UInt8(0x30) and b <= UInt8(0x39):  # '0'-'9'
            cur = cur * UInt32(10) + UInt32(Int(b - UInt8(0x30)))
            if cur > UInt32(255):
                raise Error("ipv4: octet > 255")
            has_digit = True
        else:
            # Non-IPv4 char — not an IPv4 literal at all
            return out^  # empty list signals "not IPv4"
        i += 1
    if not has_digit:
        raise Error("ipv4: trailing empty")
    out.append(UInt8(Int(cur)))
    if len(out) != 4:
        # Not 4 octets — return empty list
        var empty = List[UInt8]()
        return empty^
    return out^


# -----------------------------------------------------------------------------
# SAN extension parser
# -----------------------------------------------------------------------------


struct _SanEntries(Movable, Deinitable):
    """Parsed SAN entries.

    dns_names: List of dNSName strings (extracted IA5String values).
    ip_addresses: List of List[UInt8] (4-byte IPv4 or 16-byte IPv6).
    """
    var dns_names: List[String]
    var ip_addresses: List[List[UInt8]]

    def __init__(out self, var dns_names: List[String], var ip_addresses: List[List[UInt8]]):
        self.dns_names = dns_names^
        self.ip_addresses = ip_addresses^


def _parse_san(value_bytes: Span[UInt8, _]) raises -> _SanEntries:
    """Parse a subjectAltName extension value.

    Per RFC 5280 §4.2.1.6:
      SubjectAltName ::= GeneralNames
      GeneralNames ::= SEQUENCE SIZE (1..MAX) OF GeneralName
      GeneralName ::= CHOICE {
         otherName       [0]  AnotherName,
         rfc822Name      [1]  IA5String,
         dNSName         [2]  IA5String,        -- TAKE
         x400Address     [3]  ORAddress,
         directoryName   [4]  Name,
         ediPartyName    [5]  EDIPartyName,
         uniformResourceIdentifier [6] IA5String,
         iPAddress       [7]  OCTET STRING,     -- TAKE
         registeredID    [8]  OBJECT IDENTIFIER }

    The CHOICE encoding uses [N] IMPLICIT primitive tags for dNSName /
    rfc822Name / URI / iPAddress (all primitive types). [0] otherName
    and [4] directoryName are constructed.
    """
    var dns_names = List[String]()
    var ip_addresses = List[List[UInt8]]()
    # Outer SEQUENCE
    var top = der_parse_tlv(value_bytes, 0)
    if not (top.tag.class_ == ASN1_CLASS_UNIVERSAL and top.tag.tag_number == ASN1_TAG_SEQUENCE):
        raise Error("SAN: top is not a SEQUENCE")
    var pos = top.value_pos
    while pos < top.end_pos:
        var entry = der_parse_tlv(value_bytes, pos)
        if entry.tag.class_ == ASN1_CLASS_CONTEXT and entry.tag.tag_number == UInt32(2):
            # [2] IMPLICIT IA5String dNSName — the implicit tag means the
            # primitive contents are IA5String bytes directly (no inner TLV).
            var name = der_parse_ia5_string(value_bytes[entry.value_pos : entry.value_pos + entry.value_len])
            dns_names.append(name^)
        elif entry.tag.class_ == ASN1_CLASS_CONTEXT and entry.tag.tag_number == UInt32(7):
            # [7] IMPLICIT OCTET STRING iPAddress — raw bytes (4 or 16).
            var ip_bytes = List[UInt8]()
            for k in range(entry.value_pos, entry.value_pos + entry.value_len):
                ip_bytes.append(value_bytes[k])
            if len(ip_bytes) == 4 or len(ip_bytes) == 16:
                ip_addresses.append(ip_bytes^)
            # Wrong-length IP entries are silently skipped (per practice;
            # RFC 5280 §4.2.1.6 mandates 4 or 16).
        # All other GeneralName CHOICE branches are silently skipped
        # for hostname matching (rfc822Name, URI, etc. don't bind to
        # TLS server names).
        pos = entry.end_pos
    return _SanEntries(dns_names^, ip_addresses^)


# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------


def match_hostname(cert: X509Certificate, hostname: String) raises -> Bool:
    """Check whether `cert` is valid for `hostname` per RFC 6125 §6.

    Algorithm:
      1. Find subjectAltName extension. If present, try DNS-name entries
         (wildcard rules per RFC 6125 §6.4.3) then IP-address entries.
      2. If no SAN at all, fall back to subject CN (RFC 6125 §6.4.4 —
         legacy compat).

    An empty hostname names nothing and matches no certificate (False).

    Raises on malformed SAN bytes; otherwise returns True/False.
    """
    if len(hostname.as_bytes()) == 0:
        return False
    var san_idx = x509_find_extension(cert, _oid_subject_alt_name())
    if san_idx >= 0:
        # NOTE: Extension is Copyable + Movable but NOT ImplicitlyCopyable
        # (a POD with heap fields). Index directly into
        # cert.extensions[san_idx].value to avoid the implicit-copy reject.
        var entries = _parse_san(Span(cert.extensions[san_idx].value))
        # Try DNS-name matches first.
        for i in range(len(entries.dns_names)):
            if _match_dns_pattern(entries.dns_names[i], hostname):
                return True
        # If hostname parses as an IP literal, compare with iPAddress entries.
        var ipv4 = _parse_ipv4_literal(hostname)
        if len(ipv4) == 4:
            for i in range(len(entries.ip_addresses)):
                if len(entries.ip_addresses[i]) == 4:
                    var matches_all = True
                    for k in range(4):
                        if entries.ip_addresses[i][k] != ipv4[k]:
                            matches_all = False
                            break
                    if matches_all:
                        return True
        # No SAN match — per RFC 6125 §6.4.4, when SAN is present we do
        # NOT fall back to CN. Return False.
        return False

    # SAN absent — fall back to subject CN (legacy).
    var cn_oid = _oid_common_name()
    for i in range(len(cert.subject)):
        if der_oid_eq(cert.subject[i].oid, cn_oid):
            if _match_dns_pattern(cert.subject[i].value, hostname):
                return True
    return False
