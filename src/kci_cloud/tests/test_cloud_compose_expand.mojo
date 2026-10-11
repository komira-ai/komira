# =============================================================================
# test_cloud_compose_expand.mojo
# =============================================================================
#
# EXPANSION (compose.mojo) of well-formed lists, as goldens. Pure: no cloud.
#
# 1. A NESTED COMPOSITE, GOLDEN. `acme.shop@3` holds an instance of
#    `acme.web@1` (depth 2), and a top-level service reads the shop's
#    declared output and grants itself READ on an exported bucket two levels
#    down. The expanded list is frozen one resource per line (proto3 JSON),
#    and so is the tree. Between them they pin: the path ids; `local` ->
#    `P/<local>`; a REF input -> what the instance bound (a sibling of the
#    enclosing definition); a STRING input -> the bound value, and an unbound
#    one with a default -> the default; `path` through two exports; `named`
#    followed through two declared outputs to the primitive's standard
#    output; the order (the authored order, each instance's primitives in its
#    place, components in definition order); the digest of each definition
#    in the tree. The digests are `definition_digest` of each definition,
#    and one is pinned as its literal value.
# 2. AN OPTIONAL INPUT LEFT UNBOUND removes what names it: the env entry
#    (`Value.input`), the `uses` target (`Ref.input`) and an optional
#    reference field (`run_as`); everything else is kept.
# 3. EVERY REFERENCE POSITION IS REWRITTEN (the census): one definition with
#    a component of every type that holds a reference, each position naming
#    a sibling by `local`. `ref_sites` finds all 23 positions, and after
#    expansion every one names the full path and none holds `local`. A
#    position `_walk` did not know would be caught by `unrewritten`, and
#    `unrewritten` itself finds a `local`, an `input` and a `path` that are
#    left in place.
# 4. A LIST WITH NO INSTANCE IS UNCHANGED: same resources, same order, no
#    produced id, every reference as written.
# 5. THE OWNER OF A PATH is its first segment at any depth.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, encode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    Catalog,
    Expansion,
    definition_digest,
    expand,
    owner_of_node,
    ref_sites,
    unrewritten,
)


def _defs(texts: List[String]) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    for i in range(len(texts)):
        out.append(decode_json[CompositeDefinition](texts[i]))
    return out^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(x: Expansion) raises -> String:
    var s = String("")
    for i in range(len(x.resources)):
        s += encode_json(x.resources[i]) + String("\n")
    return s^


def _findings(x: Expansion) -> String:
    var s = String("")
    for i in range(len(x.findings)):
        s += x.findings[i].resource_id + String(" ") + x.findings[i].field_path + String(": ") + x.findings[i].reason + String("\n")
    return s^


# ---- 1. a nested composite, golden ------------------------------------------------------

comptime _WEB = (
    '{"name":"acme.web","version":"1",'
    + '"input":[{"name":"domain","type":"INPUT_STRING"},'
    + '{"name":"port","type":"INPUT_STRING","default":{"literal":"8080"}},'
    + '{"name":"reads","type":"INPUT_REF"}],'
    + '"component":['
    + '{"id":"ident","serviceAccount":{}},'
    + '{"id":"api","uses":[{"target":{"input":"reads"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"local":"ident"},'
    + '"env":{"DOMAIN":{"input":"domain"},"PORT":{"input":"port"}}}},'
    + '{"id":"files","retention":"KEEP","bucket":{}},'
    + '{"id":"g-files","grant":{"principal":{"local":"ident"},"target":{"local":"files"},"access":"READ_WRITE"}}],'
    + '"output":[{"name":"url","from":{"local":"api","standard":"URL"}}],'
    + '"export":["ident","files"]}'
)

comptime _SHOP = (
    '{"name":"acme.shop","version":"3",'
    + '"input":[{"name":"domain","type":"INPUT_STRING","required":true}],'
    + '"component":['
    + '{"id":"web","composite":{"definition":"acme.web","version":"1",'
    + '"input":{"domain":{"input":"domain"},"reads":{"ref":{"local":"data"}}}}},'
    + '{"id":"data","bucket":{}},'
    + '{"id":"events-dl","queue":{}},'
    + '{"id":"events","queue":{"deadLetter":{"local":"events-dl"}}},'
    + '{"id":"reader","uses":[{"target":{"local":"web","path":"files"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:b2"},"internal":{},'
    + '"env":{"WEB_URL":{"ref":{"local":"web","named":"url"}}}}}],'
    + '"output":[{"name":"url","from":{"local":"web","named":"url"}}],'
    + '"export":["web"]}'
)

comptime _STORE = (
    '{"resource":['
    + '{"id":"store","composite":{"definition":"acme.shop","version":"3",'
    + '"input":{"domain":{"literal":"shop.example.com"}}}},'
    + '{"id":"reports","uses":[{"target":{"resource":"store","path":"web/files"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:c3"},"internal":{},'
    + '"env":{"SHOP_URL":{"ref":{"resource":"store","named":"url"}}}}}]}'
)

comptime _GOLDEN_LIST = (
    '{"id":"store/web/ident","serviceAccount":{}}\n'
    + '{"id":"store/web/api","uses":[{"target":{"resource":"store/data"},"access":"READ"}],"service":{"image":{"digest":"sha256:a1"},"env":{"DOMAIN":{"literal":"shop.example.com"},"PORT":{"literal":"8080"}},"runAs":{"resource":"store/web/ident"},"internal":{}}}\n'
    + '{"id":"store/web/files","retention":"KEEP","bucket":{}}\n'
    + '{"id":"store/web/g-files","grant":{"principal":{"resource":"store/web/ident"},"target":{"resource":"store/web/files"},"access":"READ_WRITE"}}\n'
    + '{"id":"store/data","bucket":{}}\n'
    + '{"id":"store/events-dl","queue":{}}\n'
    + '{"id":"store/events","queue":{"deadLetter":{"resource":"store/events-dl"}}}\n'
    + '{"id":"store/reader","uses":[{"target":{"resource":"store/web/files"},"access":"READ"}],"service":{"image":{"digest":"sha256:b2"},"env":{"WEB_URL":{"ref":{"resource":"store/web/api","standard":"URL"}}},"internal":{}}}\n'
    + '{"id":"reports","uses":[{"target":{"resource":"store/web/files"},"access":"READ"}],"service":{"image":{"digest":"sha256:c3"},"env":{"SHOP_URL":{"ref":{"resource":"store/web/api","standard":"URL"}}},"internal":{}}}\n'
)

comptime _GOLDEN_TREE = (
    "store: acme.shop@3 <shop>\n"
    + "  store/web: acme.web@1 <web>\n"
    + "    store/web/ident: service_account\n"
    + "    store/web/api: service\n"
    + "    store/web/files: bucket\n"
    + "    store/web/g-files: grant\n"
    + "  store/data: bucket\n"
    + "  store/events-dl: queue\n"
    + "  store/events: queue\n"
    + "  store/reader: service\n"
    + "reports: service\n"
)

# The digest of `_WEB`: sha256 of its bytes as this kci encodes them. Pinned
# literally, so a change of what is hashed (another encoding, the JSON text)
# is seen: it would show every stored plan's definitions as edited.
comptime _WEB_DIGEST = "sha256:e6eb742482a04edc7cc27493200885b1acf817e9c6e854a31c23f1d6061db0fd"


def test_a_nested_composite_expands_to_its_golden() raises:
    """Catches: a wrong path id, a local / input / path / named rewrite, a
    default not applied, a bound value not substituted, a wrong order, a
    definition's primitives out of place, and a tree that does not say
    which definition, version and digest each instance is."""
    var defs: List[String] = [String(_WEB), String(_SHOP)]
    var x = expand(Catalog.v1(), _defs(defs), _list(String(_STORE)))
    assert_equal(len(x.findings), 0, _findings(x))
    assert_equal(_lines(x), String(_GOLDEN_LIST), "the expanded list")
    var want_tree = String(_GOLDEN_TREE).replace(
        "<web>", definition_digest(decode_json[CompositeDefinition](String(_WEB)))
    ).replace("<shop>", definition_digest(decode_json[CompositeDefinition](String(_SHOP))))
    assert_equal(x.tree, want_tree, "the tree")
    assert_equal(definition_digest(decode_json[CompositeDefinition](String(_WEB))), String(_WEB_DIGEST), "the digest")
    var produced: List[String] = [
        "store/web/ident", "store/web/api", "store/web/files", "store/web/g-files",
        "store/data", "store/events-dl", "store/events", "store/reader",
    ]
    assert_equal(len(x.produced), len(produced), "every primitive below store is produced")
    for i in range(len(produced)):
        assert_equal(x.produced[i], produced[i])
    print("  test_a_nested_composite_expands_to_its_golden: PASS")


# ---- 2. an optional input left unbound -----------------------------------------------------

comptime _OPT = (
    '{"name":"acme.opt","version":"1",'
    + '"input":[{"name":"note","type":"INPUT_STRING"},{"name":"reads","type":"INPUT_REF"},'
    + '{"name":"acct","type":"INPUT_REF"}],'
    + '"component":['
    + '{"id":"api","uses":[{"target":{"input":"reads"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"input":"acct"},'
    + '"env":{"NOTE":{"input":"note"},"KEEP":{"literal":"yes"}}}}]}'
)


def test_an_unbound_optional_input_removes_what_names_it() raises:
    """Catches: an unbound input left as `input` (the guard would raise), a
    removed entry that takes others with it, and an unbound input read as
    an empty value instead of removing it."""
    var defs: List[String] = [String(_OPT)]
    var x = expand(
        Catalog.v1(),
        _defs(defs),
        _list(String('{"resource":[{"id":"o","composite":{"definition":"acme.opt","version":"1"}}]}')),
    )
    assert_equal(len(x.findings), 0, _findings(x))
    assert_equal(len(x.resources), 1)
    ref api = x.resources[0]
    assert_equal(api.id, "o/api")
    assert_equal(len(api.uses), 1, "the uses line stays")
    assert_false(Bool(api.uses[0].target), "its target named the unbound input: removed")
    ref s = api.service.value()
    assert_false(Bool(s.run_as), "run_as named the unbound input: removed")
    assert_equal(len(s.env), 1, "the env entry that named it is removed")
    assert_equal(s.env["KEEP"].literal.value(), "yes", "the other entry is kept")
    print("  test_an_unbound_optional_input_removes_what_names_it: PASS")


# ---- 3. every reference position is rewritten ----------------------------------------------

comptime _ALL = (
    '{"name":"acme.all","version":"1","component":['
    + '{"id":"b","bucket":{}},{"id":"sa","serviceAccount":{}},{"id":"sec","secret":{}},'
    + '{"id":"net","network":{"ipv4Cidr":"198.51.100.0/24"}},'
    + '{"id":"sn","subnet":{"network":{"local":"net"},"ipv4Cidr":"198.51.100.0/26"}},'
    + '{"id":"s","uses":[{"target":{"local":"b"},"access":"READ"}],"service":{"image":{"digest":"sha256:a1"},"internal":{},'
    + '"env":{"V":{"ref":{"local":"b","standard":"NAME"}}},"secretEnv":{"S":{"secret":{"local":"sec"}}},'
    + '"runAs":{"local":"sa"},"network":{"local":"sn"}}},'
    + '{"id":"j","containerJob":{"image":{"digest":"sha256:a1"},'
    + '"env":{"V":{"ref":{"local":"b","standard":"NAME"}}},"secretEnv":{"S":{"secret":{"local":"sec"}}},"runAs":{"local":"sa"}}},'
    + '{"id":"w","worker":{"image":{"digest":"sha256:a1"},'
    + '"env":{"V":{"ref":{"local":"b","standard":"NAME"}}},"secretEnv":{"S":{"secret":{"local":"sec"}}},"runAs":{"local":"sa"}}},'
    + '{"id":"g","grant":{"principal":{"local":"sa"},"target":{"local":"b"},"access":"READ"}},'
    + '{"id":"q2","queue":{}},{"id":"q","queue":{"deadLetter":{"local":"q2"}}},'
    + '{"id":"t","topic":{}},{"id":"sub","subscription":{"topic":{"local":"t"},"queue":{"local":"q"}}},'
    + '{"id":"z","dnsZone":{"name":"example.com"}},'
    + '{"id":"r","dnsRecord":{"name":"www.example.com","zone":{"local":"z"},"type":"CNAME","values":[{"ref":{"local":"s","standard":"HOST"}}]}},'
    + '{"id":"c","certificate":{"domains":["www.example.com"],"zone":{"local":"z"}}},'
    + '{"id":"cron","schedule":{"cron":"0 3 * * *","target":{"local":"j"}}},'
    + '{"id":"ev","eventTrigger":{"source":{"local":"b"},"event":"OBJECT_CREATED","target":{"local":"s"}}}]}'
)


def test_every_reference_position_is_rewritten() raises:
    """Catches: a reference position `_walk` skips (its `local` survives, and
    `unrewritten` makes expansion raise; the count drops), a position
    rewritten to a wrong path, and an `unrewritten` that misses a key."""
    var d = decode_json[CompositeDefinition](String(_ALL))
    var sites = 0
    for i in range(len(d.component)):
        sites += len(ref_sites(d.component[i]))
    assert_equal(sites, 23, "every reference position of every type that holds one")
    var defs: List[String] = [String(_ALL)]
    var x = expand(
        Catalog.v1(),
        _defs(defs),
        _list(String('{"resource":[{"id":"x","composite":{"definition":"acme.all","version":"1"}}]}')),
    )
    assert_equal(len(x.findings), 0, _findings(x))
    var after = 0
    for i in range(len(x.resources)):
        ref r = x.resources[i]
        assert_equal(unrewritten(r), "", r.id + " holds no reference of the composite form")
        var rs = ref_sites(r)
        after += len(rs)
        for k in range(len(rs)):
            var named = String("")
            if rs[k].ref_:
                named = rs[k].ref_.value().resource.copy()
            else:
                named = rs[k].value.value().ref_.value().resource.copy()
            assert_true(named.startswith("x/"), r.id + " " + rs[k].path + " names a full path: " + named)
    assert_equal(after, 23, "no position lost")
    ref s = x.resources[5]
    assert_equal(s.id, "x/s")
    assert_equal(s.service.value().run_as.value().resource, "x/sa", "run_as -> x/sa")
    assert_equal(s.service.value().secret_env["S"].secret.value().resource, "x/sec", "a secret -> x/sec")
    assert_equal(s.uses[0].target.value().resource, "x/b", "uses -> x/b")

    var left = _list(
        String('{"resource":[{"id":"a","grant":{"principal":{"local":"sa"}}},')
        + String('{"id":"b","service":{"env":{"V":{"input":"x"}}}},')
        + String('{"id":"c","queue":{"deadLetter":{"resource":"q","path":"p"}}}]}')
    )
    assert_equal(unrewritten(left[0]), '"local":', "a local is found")
    assert_equal(unrewritten(left[1]), '"input":', "an input is found")
    assert_equal(unrewritten(left[2]), '"path":', "a path is found")
    print("  test_every_reference_position_is_rewritten: PASS")


# ---- 4. a list with no instance --------------------------------------------------------------

comptime _PLAIN = (
    '{"resource":[{"id":"db","bucket":{}},'
    + '{"id":"api","uses":[{"target":{"resource":"db"},"access":"READ"}],'
    + '"service":{"image":{"digest":"sha256:a1"},"internal":{},"env":{"DB":{"ref":{"resource":"db","standard":"NAME"}}}}}]}'
)


def test_a_list_with_no_instance_is_unchanged() raises:
    """Catches: an expansion that reorders, renames or rewrites a list of
    primitives only, or reports one of its ids as produced."""
    var l = _list(String(_PLAIN))
    var x = expand(Catalog.v1(), List[CompositeDefinition](), l)
    assert_equal(len(x.findings), 0, _findings(x))
    assert_equal(len(x.produced), 0)
    assert_equal(len(x.resources), len(l))
    for i in range(len(l)):
        assert_equal(encode_json(x.resources[i]), encode_json(l[i]), l[i].id + " is unchanged")
    assert_equal(x.tree, "db: bucket\napi: service\n")
    print("  test_a_list_with_no_instance_is_unchanged: PASS")


# ---- 5. the owner of a path ------------------------------------------------------------------


def test_the_owner_of_a_path_is_its_first_segment() raises:
    """Catches: an owner read from the last segment, or from the whole path."""
    assert_equal(owner_of_node(String("store/web/api/run")), "store")
    assert_equal(owner_of_node(String("store/web/api")), "store")
    assert_equal(owner_of_node(String("store")), "store")
    print("  test_the_owner_of_a_path_is_its_first_segment: PASS")


def main() raises:
    print("test_cloud_compose_expand: expansion goldens")
    test_a_nested_composite_expands_to_its_golden()
    test_an_unbound_optional_input_removes_what_names_it()
    test_every_reference_position_is_rewritten()
    test_a_list_with_no_instance_is_unchanged()
    test_the_owner_of_a_path_is_its_first_segment()
    print("ALL kci_cloud COMPOSE EXPAND TESTS PASSED")
