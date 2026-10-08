# =============================================================================
# test_cloud_dns_rules.mojo
# =============================================================================
#
# The name primitives in kci_cloud (DNS zone, DNS record, certificate): their
# catalog rows, and the name rules (dns.mojo) through `graph_findings`, the
# cloud-independent half of validate. No cloud is needed: the fakes in
# kci_cloud_fake run these graphs on every shape.
#
# 1. THE ROWS: a DNS zone (field 18, the eighth body arm, after the
#    secret), a DNS record (26, the fifteenth, after the grant) and a
#    certificate (27, the sixteenth); each PORTABLE; a zone and a certificate
#    expose NAME only, a record HOST only; none accepts a verb; each takes
#    retention, default DELETE (a written KEEP wins); a reference lands on
#    `<id>/zone`, `<id>/record` and `<id>/cert`.
# 2. EVERY NAME REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason (the list is in the test), with nothing else reported.
# 3. A GOOD NAME GRAPH IS CLEAN: a zone and a zone below it; a CNAME that
#    follows a service's HOST, and a wildcard CNAME to a literal name; A,
#    AAAA, MX and TXT record sets at the zone's own name, two values each
#    where the type allows; a record in the lower zone; TTLs at both ends of
#    the range; a certificate for the zone's name and its wildcard; a
#    service reading a record's HOST, a zone's NAME and a certificate's
#    NAME; KEEP and DELETE written.
# 4. THE HELPERS: `dns_name_problem` (every branch), `in_zone`,
#    `zone_name_of`, `ttl_seconds` (written, and the versioned default),
#    `record_type_word`, and `dns_findings` on another type.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_CERTIFICATE,
    FIELD_DNS_RECORD,
    FIELD_DNS_ZONE,
    FIELD_GRANT,
    FIELD_SECRET,
    FIELD_QUEUE,
    PORTABLE,
    RETENTION_DELETE,
    RETENTION_KEEP,
    TTL_DEFAULT_SECONDS,
    Catalog,
    Finding,
    body_arms,
    dns_findings,
    dns_name_problem,
    effective_retention,
    graph_findings,
    in_zone,
    primary_node,
    record_type_word,
    ttl_seconds,
    zone_name_of,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


# ---- 1. the rows ------------------------------------------------------------------


def test_the_name_rows() raises:
    """Catches: a row at another field or arm position (a decoded zone,
    record or certificate would map to another type), a portability other
    than PORTABLE, an output the design does not give (a record's NAME, a
    zone's HOST or ADDRESS), any accepted verb (a grant to a zone would be
    MANAGE, which is held), a default other than DELETE or no retention at
    all, and a primary role other than `zone`, `record` and `cert`."""
    var c = Catalog.v1()
    assert_equal(FIELD_DNS_ZONE, 18)
    assert_equal(FIELD_DNS_RECORD, 26)
    assert_equal(FIELD_CERTIFICATE, 27)
    var arms = body_arms()
    assert_equal(arms[6].field, FIELD_SECRET, "the secret stays the seventh arm")
    assert_equal(arms[7].field, FIELD_DNS_ZONE, "the eighth arm, after the secret")
    assert_equal(arms[13].field, FIELD_GRANT, "the grant is the fourteenth (the schedule 22 to the registry 24 before)")
    assert_equal(arms[14].field, FIELD_DNS_RECORD, "the fifteenth arm, after the grant")
    assert_equal(arms[15].field, FIELD_CERTIFICATE, "the sixteenth arm")
    var fields = [FIELD_DNS_ZONE, FIELD_DNS_RECORD, FIELD_CERTIFICATE]
    var names = ["dns_zone", "dns_record", "certificate"]
    var outs = ["NAME", "HOST", "NAME"]
    var roles = ["zone", "record", "cert"]
    for i in range(3):
        ref t = c.types[c.index_of(fields[i])]
        assert_equal(t.name, String(names[i]))
        assert_equal(t.portability, PORTABLE, String(names[i]))
        assert_equal(len(t.exposes), 1, String(names[i]) + " exposes one output")
        assert_true(t.exposes_output(String(outs[i])), String(names[i]) + " exposes " + String(outs[i]))
        assert_equal(len(t.accepts), 0, String(names[i]) + " accepts no verb")
        assert_true(t.takes_retention(), String(names[i]) + " takes retention")
        assert_equal(t.retention_default, RETENTION_DELETE, String(names[i]) + " is deleted by default")
        assert_equal(t.primary_role, String(roles[i]))
    var l = _list(
        String('{"resource":[{"id":"site","dnsZone":{"name":"example.com"}},')
        + String('{"id":"kept","retention":"KEEP","dnsZone":{"name":"example.org"}},')
        + String('{"id":"www","dnsRecord":{}},{"id":"tls","certificate":{}}]}')
    )
    assert_equal(effective_retention(c, l[0]), RETENTION_DELETE, "unset: DELETE")
    assert_equal(effective_retention(c, l[1]), RETENTION_KEEP, "written KEEP")
    assert_equal(primary_node(c, l, String("site")), "site/zone")
    assert_equal(primary_node(c, l, String("www")), "www/record")
    assert_equal(primary_node(c, l, String("tls")), "tls/cert")
    print("  test_the_name_rows: PASS")


# ---- 2. every refusal, in one pass ------------------------------------------------


def _rec(id: String, body: String) -> String:
    return String('{"id":"') + id + String('","dnsRecord":{') + body + String("}},")


def _site_rec(id: String, name: String, type: String, values: String, extra: String = String("")) -> String:
    """A record in zone `site` (example.com)."""
    return _rec(
        id,
        String('"name":"') + name + String('","zone":{"resource":"site"},"type":"') + type
        + String('","values":[') + values + String("]") + extra,
    )


def _lit(s: String) -> String:
    return String('{"literal":"') + s + String('"}')


def _cert(id: String, body: String) -> String:
    return String('{"id":"') + id + String('","certificate":{') + body + String("}},")


def test_every_name_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a rule that fires
    on the wrong resource or path, a rule that also fires on a good entry or
    reports one defect twice (the total). Every refusal branch of the
    literal checks has its own line: a TTL above the range or fractional;
    an IPv4 with a leading zero, three parts, an empty part, a part longer
    than three digits (it would wrap a 64-bit sum to a legal octet) or a
    letter; an IPv6 longer than 45 bytes, in uppercase or with one colon;
    an empty TXT; an MX preference above 65535, of six digits, not a
    number, before a bad host, or missing; and a CNAME written before
    another record set at its name as well as after one."""
    var txt256 = String("")
    for _ in range(256):
        txt256 += String("t")
    var v6long = String("::")
    for _ in range(44):
        v6long += String("a")  # 46 bytes, the right shape
    var many = String("")
    for i in range(11):
        many += String('"d') + String(i) + String('.example.com"') + (String(",") if i < 10 else String(""))
    var j = (
        String('{"resource":[')
        + String('{"id":"site","dnsZone":{"name":"example.com"}},')
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{}}},')
        + String('{"id":"q","queue":{}},')
        # zones
        + String('{"id":"dup-zone","dnsZone":{"name":"example.com"}},')
        + String('{"id":"z-case","dnsZone":{"name":"Example.net"}},')
        + String('{"id":"z-one","dnsZone":{"name":"localhost"}},')
        + String('{"id":"z-wild","dnsZone":{"name":"*.example.net"}},')
        + String('{"id":"z-empty","dnsZone":{}},')
        + String('{"id":"z-uses","dnsZone":{"name":"uses.example.net"},')
        + String('"uses":[{"target":{"resource":"site"},"access":"READ"}]},')
        # records: zone and name
        + _rec("r-nozone", String('"name":"a.example.com","type":"A","values":[') + _lit("192.0.2.1") + String("]"))
        + _rec("r-qzone", String('"name":"a.example.com","zone":{"resource":"q"},"type":"A","values":[')
               + _lit("192.0.2.1") + String("]"))
        + _rec("r-outzone", String('"name":"a.example.com","zone":{"resource":"site","standard":"NAME"},')
               + String('"type":"A","values":[') + _lit("192.0.2.1") + String("]"))
        + _rec("r-gone", String('"name":"a.example.com","zone":{"resource":"nope"},"type":"A","values":[')
               + _lit("192.0.2.1") + String("]"))
        + _site_rec("r-notin", "www.example.org", "A", _lit("192.0.2.1"))
        + _site_rec("r-badname", "bad_name.example.com", "A", _lit("192.0.2.1"))
        + _site_rec("r-wild-mid", "a.*.example.com", "A", _lit("192.0.2.1"))
        # records: type and values
        + _rec("r-notype", String('"name":"t.example.com","zone":{"resource":"site"},"values":[')
               + _lit("192.0.2.1") + String("]"))
        + _site_rec("r-novalues", "nv.example.com", "A", String(""))
        + _site_rec("r-cname2", "c2.example.com", "CNAME", _lit("a.example.net") + String(",") + _lit("b.example.net"))
        + _site_rec("r-apex", "example.com", "CNAME", _lit("x.example.net"))
        + _site_rec("r-badip", "ip.example.com", "A", _lit("192.0.2.256"))
        + _site_rec("r-bad6", "ip6.example.com", "AAAA", _lit("2001:db8::g"))
        + _site_rec("r-badcn", "cn.example.com", "CNAME", _lit("not a name"))
        + _site_rec("r-txt", "txt.example.com", "TXT", _lit(txt256))
        + _site_rec("r-mx", "mx.example.com", "MX", _lit("mail.example.com"))
        + _site_rec("r-refa", "ra.example.com", "A", String('{"ref":{"resource":"api","standard":"HOST"}}'))
        + _site_rec("r-refname", "rn.example.com", "CNAME", String('{"ref":{"resource":"q","standard":"NAME"}}'))
        + _site_rec("r-refq", "rq.example.com", "CNAME", String('{"ref":{"resource":"q","standard":"HOST"}}'))
        + _site_rec("r-param", "p.example.com", "TXT", String('{"param":"region"}'))
        + _site_rec("r-ttl", "ttl.example.com", "A", _lit("192.0.2.1"), String(',"ttl":"30s"'))
        + _site_rec("r-ttl-hi", "ttlhi.example.com", "A", _lit("192.0.2.1"), String(',"ttl":"86401s"'))
        + _site_rec("r-ttl-frac", "ttlfr.example.com", "A", _lit("192.0.2.1"), String(',"ttl":"60.500s"'))
        # records: each literal check of its type
        + _site_rec("r-ip-lead0", "ip1.example.com", "A", _lit("192.0.2.01"))
        + _site_rec("r-ip-three", "ip2.example.com", "A", _lit("192.0.2"))
        + _site_rec("r-ip-empty", "ip3.example.com", "A", _lit("192..2.1"))
        + _site_rec("r-ip-long", "ip4.example.com", "A", _lit("18446744073709551617.0.2.1"))
        + _site_rec("r-ip-alpha", "ip5.example.com", "A", _lit("192.0.2.a"))
        + _site_rec("r-v6-long", "ip6a.example.com", "AAAA", _lit(v6long))
        + _site_rec("r-v6-upper", "ip6b.example.com", "AAAA", _lit("2001:DB8::1"))
        + _site_rec("r-v6-colon", "ip6c.example.com", "AAAA", _lit("2001db8:1"))
        + _site_rec("r-txt-empty", "txt0.example.com", "TXT", _lit(""))
        + _site_rec("r-mx-big", "mx1.example.com", "MX", _lit("65536 mail.example.com"))
        + _site_rec("r-mx-six", "mx2.example.com", "MX", _lit("000010 mail.example.com"))
        + _site_rec("r-mx-alpha", "mx3.example.com", "MX", _lit("x1 mail.example.com"))
        + _site_rec("r-mx-host", "mx4.example.com", "MX", _lit("10 Mail.example.com"))
        + _site_rec("r-mx-lead", "mx5.example.com", "MX", _lit(" mail.example.com"))
        # records: one set per name and type, a CNAME alone
        + _site_rec("r-dup1", "dup.example.com", "A", _lit("192.0.2.1"))
        + _site_rec("r-dup2", "dup.example.com", "A", _lit("192.0.2.2"))
        + _site_rec("r-cn-side", "dup.example.com", "CNAME", _lit("x.example.net"))
        + _site_rec("r-cn-first", "cnf.example.com", "CNAME", _lit("x.example.net"))
        + _site_rec("r-cn-after", "cnf.example.com", "TXT", _lit("v=spf1 -all"))
        + String('{"id":"r-uses","dnsRecord":{"name":"u.example.com","zone":{"resource":"site"},"type":"A",')
        + String('"values":[') + _lit("192.0.2.1") + String(']},"uses":[{"cell":"LOGS","access":"WRITE"}]},')
        # certificates
        + _cert("c-nozone", String('"domains":["example.com"]'))
        + _cert("c-none", String('"zone":{"resource":"site"}'))
        + _cert("c-many", String('"domains":[') + many + String('],"zone":{"resource":"site"}'))
        + _cert("c-out", String('"domains":["example.org"],"zone":{"resource":"site"}'))
        + _cert("c-wild", String('"domains":["*.*.example.com"],"zone":{"resource":"site"}'))
        + _cert("c-twice", String('"domains":["www.example.com","www.example.com"],"zone":{"resource":"site"}'))
        + String('{"id":"c-uses","certificate":{"domains":["example.com"],"zone":{"resource":"site"}},')
        + String('"uses":[{"target":{"resource":"site"},"access":"READ"}]}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), _list(j)))
    # zones
    _expect(l, "dup-zone|dns_zone.name|", 'zone "site" already holds "example.com"; a domain has one zone in a list')
    _expect(l, "z-case|dns_zone.name|", 'label "Example" is not 1 to 63 lowercase letters, digits and inner hyphens')
    _expect(l, "z-one|dns_zone.name|", '"localhost" is not a DNS name: it has fewer than two labels')
    _expect(l, "z-wild|dns_zone.name|", "a wildcard `*` is only the first label of a record name or a certificate")
    _expect(l, "z-empty|dns_zone.name|", "no name")
    _expect(l, "z-uses|uses|", "a dns_zone runs as no identity, so it cannot use another resource")
    # records: zone and name
    _expect(l, "r-nozone|dns_record.zone|", "no zone")
    _expect(l, "r-qzone|dns_record.zone|", 'must name a dns_zone; "q" is not one')
    _expect(l, "r-outzone|dns_record.zone|", "names a dns_zone, not one of its outputs")
    _expect(l, "r-gone|dns_record.zone|", 'ref to missing resource "nope"')
    _expect(l, "r-notin|dns_record.name|", '"www.example.org" is not in zone "site" (example.com)')
    _expect(l, "r-badname|dns_record.name|", 'label "bad_name" is not 1 to 63')
    _expect(l, "r-wild-mid|dns_record.name|", "a wildcard `*` is only the first label")
    # records: type and values
    _expect(l, "r-notype|dns_record.type|", "a record type: A, AAAA, CNAME, TXT or MX")
    _expect(l, "r-novalues|dns_record.values|", "no values")
    _expect(l, "r-cname2|dns_record.values|", "a CNAME has exactly one value")
    _expect(l, "r-apex|dns_record.name|", "a CNAME is never at its zone's own name")
    _expect(l, "r-badip|dns_record.values[0]|", '"192.0.2.256" is not an IPv4 address')
    _expect(l, "r-bad6|dns_record.values[0]|", '"2001:db8::g" is not an IPv6 address')
    _expect(l, "r-badcn|dns_record.values[0]|", '"not a name" is not a DNS name: it has fewer than two labels')
    _expect(l, "r-txt|dns_record.values[0]|", "a TXT value is 1 to 255 bytes")
    _expect(l, "r-mx|dns_record.values[0]|", '"mail.example.com" is not an MX value')
    _expect(l, "r-refa|dns_record.values[0]|", "a reference is only a CNAME's value (the HOST it follows); the values of a A record")
    _expect(l, "r-refname|dns_record.values[0]|", "a CNAME follows a HOST, not NAME")
    _expect(l, "r-refq|dns_record.values[0]|", '"q" (queue) does not expose HOST')
    _expect(l, "r-param|dns_record.values[0]|", 'release parameter "region" is unresolved')
    _expect(l, "r-ttl|dns_record.ttl|", "whole seconds from 60 to 86400; unset means 300")
    _expect(l, "r-ttl-hi|dns_record.ttl|", "whole seconds from 60 to 86400")
    _expect(l, "r-ttl-frac|dns_record.ttl|", "whole seconds from 60 to 86400")
    _expect(l, "r-ip-lead0|dns_record.values[0]|", '"192.0.2.01" is not an IPv4 address')
    _expect(l, "r-ip-three|dns_record.values[0]|", '"192.0.2" is not an IPv4 address')
    _expect(l, "r-ip-empty|dns_record.values[0]|", '"192..2.1" is not an IPv4 address')
    _expect(l, "r-ip-long|dns_record.values[0]|", '"18446744073709551617.0.2.1" is not an IPv4 address')
    _expect(l, "r-ip-alpha|dns_record.values[0]|", '"192.0.2.a" is not an IPv4 address')
    _expect(l, "r-v6-long|dns_record.values[0]|", "is not an IPv6 address")
    _expect(l, "r-v6-upper|dns_record.values[0]|", '"2001:DB8::1" is not an IPv6 address')
    _expect(l, "r-v6-colon|dns_record.values[0]|", '"2001db8:1" is not an IPv6 address')
    _expect(l, "r-txt-empty|dns_record.values[0]|", "a TXT value is 1 to 255 bytes")
    _expect(l, "r-mx-big|dns_record.values[0]|", '"65536 mail.example.com" is not an MX value')
    _expect(l, "r-mx-six|dns_record.values[0]|", '"000010 mail.example.com" is not an MX value')
    _expect(l, "r-mx-alpha|dns_record.values[0]|", '"x1 mail.example.com" is not an MX value')
    _expect(l, "r-mx-host|dns_record.values[0]|", '"10 Mail.example.com" is not an MX value')
    _expect(l, "r-mx-lead|dns_record.values[0]|", '" mail.example.com" is not an MX value')
    _expect(l, "r-dup2|dns_record|", '"r-dup1" already holds the A records of "dup.example.com"')
    _expect(l, "r-cn-side|dns_record|", '"r-dup1" holds the A records of "dup.example.com"; a CNAME is the only')
    _expect(l, "r-cn-after|dns_record|", '"r-cn-first" holds the CNAME records of "cnf.example.com"; a CNAME is the only')
    _expect(l, "r-uses|uses|", "a dns_record runs as no identity")
    # certificates
    _expect(l, "c-nozone|certificate.zone|", "no zone")
    _expect(l, "c-none|certificate.domains|", "from 1 to 10 domains, not 0")
    _expect(l, "c-many|certificate.domains|", "from 1 to 10 domains, not 11")
    _expect(l, "c-out|certificate.domains[0]|", '"example.org" is not in zone "site" (example.com)')
    _expect(l, "c-wild|certificate.domains[0]|", "a wildcard `*` is only the first label")
    _expect(l, "c-twice|certificate.domains[1]|", '"www.example.com" is listed twice')
    _expect(l, "c-uses|uses|", "a certificate runs as no identity")
    assert_equal(len(l), 54, "no other finding")
    print("  test_every_name_refusal_in_one_pass: PASS")


# ---- 3. a good graph is clean -----------------------------------------------------


comptime _GOOD = (
    '{"resource":['
    '{"id":"site","retention":"KEEP","dnsZone":{"name":"example.com"}},'
    '{"id":"sub","dnsZone":{"name":"sub.example.com"}},'
    '{"id":"api","service":{"image":{"digest":"sha256:0011"},"internal":{}}},'
    '{"id":"www","dnsRecord":{"name":"www.example.com","zone":{"resource":"site"},"type":"CNAME",'
    '"values":[{"ref":{"resource":"api","standard":"HOST"}}],"ttl":"60s"}},'
    '{"id":"wild","dnsRecord":{"name":"*.example.com","zone":{"resource":"site"},"type":"CNAME",'
    '"values":[{"literal":"www.example.com"}],"ttl":"86400s"}},'
    '{"id":"apex","retention":"DELETE","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"A",'
    '"values":[{"literal":"192.0.2.1"},{"literal":"198.51.100.255"}]}},'
    '{"id":"v6","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"AAAA",'
    '"values":[{"literal":"2001:db8::1"},{"literal":"::ffff:192.0.2.1"}]}},'
    '{"id":"mx","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"MX",'
    '"values":[{"literal":"10 mail.example.com"},{"literal":"65535 mail.example.net"}]}},'
    '{"id":"txt","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"TXT",'
    '"values":[{"literal":"v=spf1 -all"},{"literal":"x"}]}},'
    '{"id":"deep","dnsRecord":{"name":"a.sub.example.com","zone":{"resource":"sub"},"type":"A",'
    '"values":[{"literal":"0.0.0.0"}]}},'
    '{"id":"tls","retention":"KEEP","certificate":{"domains":["example.com","*.example.com"],'
    '"zone":{"resource":"site"}}},'
    '{"id":"web","service":{"image":{"digest":"sha256:0011"},"internal":{},'
    '"env":{"SITE":{"ref":{"resource":"www","standard":"HOST"}},'
    '"ZONE":{"ref":{"resource":"site","standard":"NAME"}},'
    '"CERT":{"ref":{"resource":"tls","standard":"NAME"}}}}}'
    "]}"
)


def test_a_good_name_graph_is_clean() raises:
    """Catches: a rule that refuses a legal file: a zone below another zone,
    a CNAME by reference or to a wildcard name, record sets of different
    types at one name, two values where the type allows them, an IPv4 at
    the ends of the octet range, an IPv6 with a dotted tail, an MX
    preference at its maximum, a TTL at either end of its range, a
    certificate's wildcard domain, a record's HOST, a zone's or a
    certificate's NAME read as a value, and KEEP or DELETE written."""
    var l = _lines(graph_findings(Catalog.v1(), _list(String(_GOOD))))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good name graph is clean:\n") + all)
    print("  test_a_good_name_graph_is_clean: PASS")


# ---- 4. the helpers -----------------------------------------------------------------


def test_the_helpers() raises:
    """Catches: a DNS name branch lost (each problem below, and a legal name
    or wildcard refused), a name below a zone confused with a name that only
    ends in its text, a zone lookup that answers for another type, a TTL
    default other than 300, and the name rules firing on another type."""
    assert_equal(dns_name_problem(String("example.com"), False), "")
    assert_equal(dns_name_problem(String("*.example.com"), True), "")
    assert_equal(dns_name_problem(String("a-1.b2.example.com"), False), "")
    assert_equal(dns_name_problem(String(""), True), "no name")
    var long = String("")
    for _ in range(26):
        long += String("abcdefghi.")
    long += String("com")  # 263 bytes
    assert_true(dns_name_problem(long, False).find("longer than 253 bytes") >= 0, "too long")
    assert_true(dns_name_problem(String("com"), False).find("fewer than two labels") >= 0, "one label")
    assert_true(dns_name_problem(String("*.example.com"), False).find("wildcard") >= 0, "no wildcard here")
    assert_true(dns_name_problem(String("example.com."), False).find('label ""') >= 0, "a trailing dot")
    assert_true(dns_name_problem(String("-a.example.com"), False).find('label "-a"') >= 0, "a leading hyphen")
    assert_true(dns_name_problem(String("a-.example.com"), False).find('label "a-"') >= 0, "a trailing hyphen")
    var label64 = String("")
    for _ in range(64):
        label64 += String("a")
    assert_true(dns_name_problem(label64 + String(".com"), False).find("label") >= 0, "a 64-byte label")

    assert_true(in_zone(String("example.com"), String("example.com")), "the zone's own name")
    assert_true(in_zone(String("a.b.example.com"), String("example.com")), "below it")
    assert_false(in_zone(String("badexample.com"), String("example.com")), "only ends in its text")

    var g = _list(String(_GOOD))
    assert_equal(zone_name_of(g, String("sub")), "sub.example.com")
    assert_equal(zone_name_of(g, String("www")), "", "a record is not a zone")
    assert_equal(zone_name_of(g, String("nope")), "")
    assert_equal(ttl_seconds(g[3]), 60, "written")
    assert_equal(ttl_seconds(g[5]), TTL_DEFAULT_SECONDS, "unset: the versioned default")
    assert_equal(TTL_DEFAULT_SECONDS, 300)
    assert_equal(record_type_word(1), "A")
    assert_equal(record_type_word(5), "MX")
    assert_equal(record_type_word(9), "9")
    var c = Catalog.v1()
    assert_equal(len(dns_findings(c, g, FIELD_QUEUE, g[0])), 0, "asked as another type: nothing")
    print("  test_the_helpers: PASS")


def main() raises:
    print("test_cloud_dns_rules")
    test_the_name_rows()
    test_every_name_refusal_in_one_pass()
    test_a_good_name_graph_is_clean()
    test_the_helpers()
    print("ALL kci_cloud NAME RULES TESTS PASSED")
