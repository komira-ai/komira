# =============================================================================
# test_cloud_metadata_rules.mojo
# =============================================================================
#
# The metadata rules (metadata.mojo) and the catalog's `takes_name` column,
# through `graph_findings` (the cloud-independent half of validate) and the
# helpers deploy.mojo calls. No cloud is needed: the fakes in kci_cloud_fake
# run these graphs on every shape (test_fake_metadata).
#
# 1. EVERY METADATA REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason: label keys (empty, an uppercase start, a digit first, a
#    trailing `-`, a character outside the rule, 64 bytes, `kci_` and `kci-`
#    keys), label values (a leading `-`, a trailing `_`, a space, 64 bytes),
#    cloud names (written empty, uppercase, `--`, a trailing `-`, `_`, 64
#    bytes, on a grant, on a DNS record, the same name twice for one type),
#    and `adopt` with no name. Nothing else is reported.
# 2. A GOOD METADATA GRAPH IS CLEAN: every boundary on its legal side (63
#    bytes, one byte, an empty value, `_` and `-` inside, the bare key
#    `kci`), one name on a bucket and on a table (two types), adopt with a
#    name.
# 3. THE LABEL FIELDS: one `label.<key>` per label, sorted by key whatever
#    order they were written in; none for a resource with no labels.
# 4. A CHANGED CLOUD NAME: `name_change_findings` refuses set -> other, set
#    -> unset and unset -> set, and nothing else (same name, both unset, a
#    turned-off node, an object of another node).
# 5. ADOPT: `adopted_nodes` names each adopting resource's primary node (by
#    the catalog's primary role), and `with_adopted` adds each once beside
#    the scope's own adopt list.
# 6. KCI'S OWN LABELS: every label kci writes itself (identity, run id,
#    retention) is in the space an author may not write (`kci_`, `kci-`), and
#    there are `KCI_LABELS_MAX` of them at most.
# 7. THE CATALOG COLUMN: every type takes a name except a grant and a DNS
#    record.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import CellScope, Provenance, RETAIN_KEEP
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_DNS_RECORD,
    FIELD_GRANT,
    KCI_LABELS_MAX,
    LABEL_MAX_BYTES,
    NAME_MAX_BYTES,
    Catalog,
    CellContext,
    Finding,
    LoweredNode,
    OwnedRecord,
    Setting,
    adopted_nodes,
    create_labels,
    graph_findings,
    label_fields,
    label_key_problem,
    name_change_findings,
    with_adopted,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _all(lines: List[String]) -> String:
    var s = String("")
    for i in range(len(lines)):
        s += lines[i] + String("\n")
    return s^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    for i in range(len(lines)):
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + _all(lines))


def _bytes(n: Int, c: String = String("a")) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


# ---- 1. every refusal, in one pass ------------------------------------------------


def test_every_metadata_refusal_in_one_pass() raises:
    """Catches: each label key, label value and cloud name rule dropped or
    loosened (each bad value lowered and refused, or silently mangled, by a
    cloud), kci's own label space open to an author (a label could forge an
    owner or a retention mark), a name taken on a type with no name of its
    own, one name taken for two objects of one type, adopt taken with no
    name, and a rule that fires on a good value (the total)."""
    var k64 = _bytes(64)
    var g = _list(
        String('{"resource":[')
        + String('{"id":"k1","labels":{"":"x","Team":"x","9lives":"x","team-":"x","te.am":"x"},"bucket":{}},')
        + String('{"id":"k2","labels":{"kci_role":"x","kci-retention":"retain","') + k64 + String('":"x"},"bucket":{}},')
        + String('{"id":"v1","labels":{"a":"-x","b":"x_","c":"has space","d":"') + k64 + String('"},"bucket":{}},')
        + String('{"id":"n-empty","physicalName":"","bucket":{}},')
        + String('{"id":"n-upper","physicalName":"Acme","bucket":{}},')
        + String('{"id":"n-dash2","physicalName":"acme--logs","bucket":{}},')
        + String('{"id":"n-tail","physicalName":"acme-","bucket":{}},')
        + String('{"id":"n-under","physicalName":"acme_logs","bucket":{}},')
        + String('{"id":"n-long","physicalName":"') + k64 + String('","bucket":{}},')
        + String('{"id":"first","physicalName":"shared","bucket":{}},')
        + String('{"id":"second","physicalName":"shared","bucket":{}},')
        + String('{"id":"reader","serviceAccount":{}},')
        + String('{"id":"g","physicalName":"read-it","grant":{"principal":{"resource":"reader"},')
        + String('"target":{"resource":"first"},"access":"READ"}},')
        + String('{"id":"zone","dnsZone":{"name":"example.com"}},')
        + String('{"id":"www","physicalName":"www-rec","dnsRecord":{"zone":{"resource":"zone"},"name":"www.example.com",')
        + String('"type":"A","values":[{"literal":"192.0.2.1"}]}},')
        + String('{"id":"orphan","adopt":"ADOPT","bucket":{}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    _expect(l, "k1|labels.|", "a label key is not empty")
    _expect(l, "k1|labels.Team|", "a label key starts with a lowercase letter")
    _expect(l, "k1|labels.9lives|", "a label key starts with a lowercase letter")
    _expect(l, "k1|labels.team-|", "a label key ends with a letter or a digit")
    _expect(l, "k1|labels.te.am|", "a label key is lowercase letters, digits, '_' and '-' only")
    _expect(l, "k2|labels.kci_role|", "a label key starting kci_ or kci- is kci's own")
    _expect(l, "k2|labels.kci-retention|", "a label key starting kci_ or kci- is kci's own")
    _expect(l, String("k2|labels.") + k64 + String("|"), "a label key is at most 63 bytes; this one is 64")
    _expect(l, "v1|labels.a|", "a label value starts and ends with a letter or a digit")
    _expect(l, "v1|labels.b|", "a label value starts and ends with a letter or a digit")
    _expect(l, "v1|labels.c|", "a label value is lowercase letters, digits, '_' and '-' only")
    _expect(l, "v1|labels.d|", "a label value is at most 63 bytes; this one is 64")
    _expect(l, "n-empty|physical_name|", "physical_name is written empty")
    _expect(l, "n-upper|physical_name|", "a cloud name starts with a lowercase letter")
    _expect(l, "n-dash2|physical_name|", "a cloud name may not contain '--'")
    _expect(l, "n-tail|physical_name|", "a cloud name ends with a letter or a digit")
    _expect(l, "n-under|physical_name|", "a cloud name is lowercase letters, digits and '-' only")
    _expect(l, "n-long|physical_name|", "a cloud name is at most 63 bytes; this one is 64")
    _expect(l, "second|physical_name|", '"shared" is also the cloud name of bucket "first"; one name names one object')
    _expect(l, "g|physical_name|", "a grant has no cloud name of its own to write")
    _expect(l, "www|physical_name|", "a dns_record has no cloud name of its own to write")
    _expect(l, "orphan|adopt|", "adopt takes over the existing object named physical_name, and none is written")
    assert_equal(len(l), 22, String("nothing else is reported:\n") + _all(l))
    print("  test_every_metadata_refusal_in_one_pass: PASS")


# ---- 2. a good metadata graph is clean ----------------------------------------------


def test_a_good_metadata_graph_is_clean() raises:
    """Catches: a legal value refused at a boundary (63 bytes, one byte, an
    empty value, `_` or `-` inside, the bare key `kci`), one name refused on
    two TYPES (names are per kind), and adopt with a name refused."""
    var k63 = _bytes(63)
    var g = _list(
        String('{"resource":[')
        + String('{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT",')
        + String('"labels":{"kci":"","team_a":"x-1","b":"z","') + k63 + String('":"') + k63 + String('"},"bucket":{}},')
        + String('{"id":"rows","physicalName":"acme-logs","table":{"key":{"partition":{"name":"id","type":"STRING"}}}},')
        + String('{"id":"tiny","physicalName":"a","bucket":{}},')
        + String('{"id":"wide","physicalName":"') + k63 + String('","bucket":{}},')
        + String('{"id":"api","physicalName":"api-9","labels":{"tier":"gold"},"service":{')
        + String('"image":{"digest":"sha256:0011"},"internal":{}}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    assert_equal(len(l), 0, String("a good metadata graph is clean:\n") + _all(l))
    assert_equal(LABEL_MAX_BYTES, 63)
    assert_equal(NAME_MAX_BYTES, 63)
    print("  test_a_good_metadata_graph_is_clean: PASS")


# ---- 3. the label fields ------------------------------------------------------------------


def test_label_fields_are_sorted_by_key() raises:
    """Catches: label fields written in map order (a digest that moves
    with the order an author wrote the labels in, so a reordered file is an
    update), a field name other than `label.<key>`, and fields for a
    resource with no labels."""
    var l = _list(
        String('{"resource":[{"id":"a","labels":{"tier":"gold","app":"web","team":"data"},"bucket":{}},')
        + String('{"id":"b","bucket":{}}]}')
    )
    var f = label_fields(l[0])
    assert_equal(len(f), 3)
    assert_equal(f[0].key, "label.app")
    assert_equal(f[0].value, "web")
    assert_equal(f[1].key, "label.team")
    assert_equal(f[2].key, "label.tier")
    assert_equal(f[2].value, "gold")
    assert_equal(len(label_fields(l[1])), 0, "no labels, no fields")
    print("  test_label_fields_are_sorted_by_key: PASS")


# ---- 4. a changed cloud name -----------------------------------------------------------


def _node(id: String, name: String, wanted: Bool = True) -> LoweredNode:
    var d = List[Setting]()
    d.append(Setting(String("format"), String("x")))
    if name.byte_length() > 0:
        d.append(Setting(String("physical_name"), name))
    var owner = String(id[byte = 0 : id.find("/")])
    return LoweredNode(id, owner, String("bucket"), desired=d^, wanted=wanted)


def _rec(node: String, name: String) -> OwnedRecord:
    return OwnedRecord(
        String("bucket"), node, String("fake"), String("none"), String(""), String("r"),
        True, node, False, String(""), None, name,
    )


def test_a_changed_cloud_name_is_refused() raises:
    """Catches: a rename taken as an update (it would create a second
    object and leave the first, stamped, behind), in each direction (set
    -> other, set -> unset, unset -> set), and a refusal of a node whose
    name did not change, of a turned-off node, or matched against another
    node's object."""
    var nodes = List[LoweredNode]()
    nodes.append(_node(String("same/bucket"), String("keep-me")))
    nodes.append(_node(String("plain/bucket"), String("")))
    nodes.append(_node(String("moved/bucket"), String("new-name")))
    nodes.append(_node(String("dropped/bucket"), String("")))
    nodes.append(_node(String("added/bucket"), String("fresh")))
    nodes.append(_node(String("off/bucket"), String("other"), wanted=False))
    var owned = List[OwnedRecord]()
    owned.append(_rec(String("same/bucket"), String("keep-me")))
    owned.append(_rec(String("plain/bucket"), String("")))
    owned.append(_rec(String("moved/bucket"), String("old-name")))
    owned.append(_rec(String("dropped/bucket"), String("was-named")))
    owned.append(_rec(String("added/bucket"), String("")))
    owned.append(_rec(String("off/bucket"), String("before")))
    owned.append(_rec(String("gone/bucket"), String("whatever")))
    var l = _lines(name_change_findings(nodes, owned))
    _expect(l, "moved|physical_name|", 'the cloud name of moved/bucket changed from "old-name" to "new-name"')
    _expect(l, "dropped|physical_name|", "changed from \"was-named\" to the cloud's own")
    _expect(l, "added|physical_name|", "changed from the cloud's own to \"fresh\"")
    _expect(l, "moved|physical_name|", "a new name is a new object")
    assert_equal(len(l), 3, String("only the three renames:\n") + _all(l))
    print("  test_a_changed_cloud_name_is_refused: PASS")


# ---- 5. adopt -------------------------------------------------------------------------------


def test_adopt_names_the_primary_node() raises:
    """Catches: adopt keyed on the resource id (the engine adopts NODES: the
    bare id is no node, so nothing would be adopted), on a role other than
    the catalog's primary one, a resource without adopt added, and an id
    added twice or the scope's own adopt list dropped."""
    var l = _list(
        String('{"resource":[')
        + String('{"id":"logs","physicalName":"acme-logs","adopt":"ADOPT","bucket":{}},')
        + String('{"id":"api","physicalName":"api-1","adopt":"ADOPT","service":{"image":{"digest":"sha256:0011"},"internal":{}}},')
        + String('{"id":"who","physicalName":"who-1","adopt":"ADOPT","serviceAccount":{}},')
        + String('{"id":"plain","physicalName":"plain-1","bucket":{}}')
        + String("]}")
    )
    var nodes = adopted_nodes(Catalog.v1(), l)
    assert_equal(len(nodes), 3)
    assert_equal(nodes[0], "logs/bucket")
    assert_equal(nodes[1], "api/run")
    assert_equal(nodes[2], "who/identity")
    var mine = List[String]()
    mine.append(String("legacy/run"))
    mine.append(String("logs/bucket"))
    var ctx = CellContext(CellScope(String("shop"), String("blue"), Provenance.none(), mine^))
    var got = with_adopted(ctx, l)
    assert_equal(len(got.scope.adopt), 4, "legacy/run, logs/bucket once, api/run, who/identity")
    assert_equal(got.scope.adopt[0], "legacy/run", "the scope's own list is kept")
    assert_true(got.scope.adopts(String("api/run")))
    assert_true(got.scope.adopts(String("who/identity")))
    assert_true(not got.scope.adopts(String("plain/bucket")), "no adopt, not adopted")
    assert_equal(len(ctx.scope.adopt), 2, "the caller's context is not changed")
    print("  test_adopt_names_the_primary_node: PASS")


# ---- 6. kci's own labels --------------------------------------------------------------------


def test_every_label_kci_writes_is_in_its_own_space() raises:
    """Catches: a label kci writes that an author could also write (a new
    mark outside `kci_` / `kci-`, which an author's label could forge or
    clobber), and `KCI_LABELS_MAX` below what kci writes (a cloud's cap
    would be overrun at create)."""
    var scope = CellScope(
        String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1")),
        List[String](), Optional[String](String("run-77")),
    )
    var labels = create_labels(scope.stamp(String("api"), String("api/run")), RETAIN_KEEP)
    assert_equal(len(labels), KCI_LABELS_MAX, "identity (6), run id, retention")
    for i in range(len(labels)):
        assert_true(
            label_key_problem(labels[i].key).find("kci's own") >= 0,
            labels[i].key + String(" must be refused as an author's label"),
        )
    print("  test_every_label_kci_writes_is_in_its_own_space: PASS")


# ---- 7. the catalog column ------------------------------------------------------------------


def test_only_a_grant_and_a_dns_record_take_no_name() raises:
    """Catches: a type that has a cloud name refused one, and a grant or a
    DNS record (no name of their own) given one."""
    var c = Catalog.v1()
    var none = 0
    for i in range(len(c.types)):
        ref t = c.types[i]
        if t.field == FIELD_GRANT or t.field == FIELD_DNS_RECORD:
            assert_true(not t.takes_name, t.name + String(" takes no name"))
            none += 1
        else:
            assert_true(t.takes_name, t.name + String(" takes a name"))
    assert_equal(none, 2)
    print("  test_only_a_grant_and_a_dns_record_take_no_name: PASS")


def main() raises:
    print("test_cloud_metadata_rules")
    test_every_metadata_refusal_in_one_pass()
    test_a_good_metadata_graph_is_clean()
    test_label_fields_are_sorted_by_key()
    test_a_changed_cloud_name_is_refused()
    test_adopt_names_the_primary_node()
    test_every_label_kci_writes_is_in_its_own_space()
    test_only_a_grant_and_a_dns_record_take_no_name()
    print("ALL kci_cloud METADATA RULE TESTS PASSED")
