# =============================================================================
# test_cloud_identity_rules.mojo
# =============================================================================
#
# Identity and grants, as kci decides them (grants.mojo, validate.mojo). No
# cloud is needed: these are the cloud-independent rules.
#
# 1. THE ROLE OF AN EDGE is `u-` and 6 base32 characters of
#    sha256(principal + "|" + target path), pinned by LITERAL values worked
#    out independently of this code (python3 hashlib, the RFC 4648 alphabet
#    in lowercase). A real collision pair is pinned too.
# 2. THE EDGES OF A RESOURCE: `uses` lines in order, then the implicit
#    `cell LOGS WRITE` when the resource holds its own identity and does not
#    write that edge; a `run_as` resource's lines belong to its account and
#    get no implicit edge; a grant resource's one edge is `grant`.
# 3. EVERY IDENTITY REFUSAL IN ONE PASS: `run_as` naming a non-account or
#    nothing; a grant principal that is not an identity (a bucket, or a
#    compute resource that runs as an account); two edges for one
#    (principal, target) pair, a `uses` line, a grant and the implicit edge
#    counting alike; a `u-<h>` collision; `uses` on a grant; a verb the
#    target does not accept (a resource or a cell resource); an edge with
#    both or neither of target and cell; retention on a service account.
# 4. A GOOD IDENTITY GRAPH IS CLEAN.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    Catalog,
    Finding,
    FINDING_GRAPH,
    EDGE_TARGET_CELL,
    EDGE_TARGET_UNKNOWN,
    GrantEdge,
    edges_for,
    edges_of,
    graph_findings,
    grant_hash,
    holds_own_identity,
    identity_owner,
    principal_node,
    uses_role,
)


comptime IMG = '"image":{"digest":"sha256:0011"}'


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _all_text(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        s += findings[i].resource_id + String("|") + findings[i].field_path
        s += String("|") + findings[i].reason + String("\n")
    return s^


def _edge(e: GrantEdge) -> String:
    var s = e.role + String(" ") + e.principal + String("->") + e.target_path()
    s += String(" ") + e.access
    if e.implicit:
        s += String(" (implicit)")
    return s^


def _edges(r: Resource) raises -> String:
    var l = edges_of(r)
    var s = String("")
    for i in range(len(l)):
        if i > 0:
            s += String("; ")
        s += _edge(l[i])
    return s^


# ---- 1. the role of an edge -----------------------------------------------------------


def test_the_role_of_an_edge_is_pinned() raises:
    assert_equal(uses_role(String("runner"), String("store")), "u-2wfpfg")
    assert_equal(uses_role(String("nightly"), String("api")), "u-e4f3tk")
    assert_equal(uses_role(String("nightly"), String("cell/METRICS")), "u-3i6lmd")
    assert_equal(uses_role(String("nightly"), String("cell/LOGS")), "u-g2ewtg")
    assert_equal(uses_role(String("runner"), String("cell/LOGS")), "u-atqd3s")
    assert_equal(grant_hash(String(""), String("")), "zps47x", "sha256 of '|'")
    # A real collision: two targets of one principal, one role.
    assert_equal(uses_role(String("web"), String("b44557")), "u-u72wff")
    assert_equal(uses_role(String("web"), String("b73264")), "u-u72wff")
    # Direction matters: (a, b) is not (b, a).
    assert_true(uses_role(String("a"), String("b")) != uses_role(String("b"), String("a")))
    assert_equal(uses_role(String("runner"), String("store")).byte_length(), 8, "8 bytes")
    print("  test_the_role_of_an_edge_is_pinned: PASS")


# ---- 2. the edges of a resource -------------------------------------------------------


def _good() -> String:
    return (
        String('{"resource":[')
        + String('{"id":"runner","serviceAccount":{}},')
        + String('{"id":"store","bucket":{}},')
        + String('{"id":"api","service":{') + String(IMG)
        + String(',"public":{},"runAs":{"resource":"runner"}},')
        + String('"uses":[{"target":{"resource":"store"},"access":"READ_WRITE"}]},')
        + String('{"id":"nightly","containerJob":{') + String(IMG)
        + String('},')
        + String('"uses":[{"target":{"resource":"api"},"access":"CALL"},')
        + String('{"cell":"METRICS","access":"WRITE"}]},')
        + String('{"id":"see","grant":{"principal":{"resource":"nightly"},')
        + String('"target":{"resource":"runner"},"access":"DESCRIBE"}}')
        + String("]}")
    )


def test_the_edges_of_a_resource() raises:
    var l = _list(_good())
    # runner: a service account holds its own identity.
    assert_true(holds_own_identity(l[0]))
    assert_equal(identity_owner(l[0]), "runner")
    assert_equal(_edges(l[0]), "u-atqd3s runner->cell/LOGS WRITE (implicit)")
    # store: a bucket runs as nobody.
    assert_false(holds_own_identity(l[1]))
    assert_equal(identity_owner(l[1]), "")
    assert_equal(_edges(l[1]), "")
    # api: runs as runner, so its line is runner's, and no implicit edge.
    assert_false(holds_own_identity(l[2]))
    assert_equal(identity_owner(l[2]), "runner")
    assert_equal(_edges(l[2]), "u-2wfpfg runner->store READ_WRITE")
    assert_equal(edges_of(l[2])[0].principal_node(), "runner/identity")
    # nightly: its own identity; the lines as written, then the implicit edge.
    assert_equal(identity_owner(l[3]), "nightly")
    assert_equal(
        _edges(l[3]),
        "u-e4f3tk nightly->api CALL; u-3i6lmd nightly->cell/METRICS WRITE;"
        + " u-g2ewtg nightly->cell/LOGS WRITE (implicit)",
    )
    # see: a grant resource is one edge, role `grant`.
    assert_equal(_edges(l[4]), "grant nightly->runner DESCRIBE")
    assert_equal(principal_node(String("nightly")), "nightly/identity")
    # edges_for adds the target's type: the catalog field, or the cell.
    var nf = edges_for(l, l[3])
    assert_equal(nf[0].target_field, 10, "api is a service")
    assert_equal(nf[1].target_field, EDGE_TARGET_CELL)
    assert_equal(nf[2].target_field, EDGE_TARGET_CELL)
    assert_equal(edges_for(l, l[4])[0].target_field, 20, "runner is a service account")
    assert_equal(edges_of(l[4])[0].target_field, EDGE_TARGET_UNKNOWN, "edges_of leaves it unset")

    # Writing the LOGS edge yourself replaces the implicit one.
    var own = _list(
        String('{"resource":[{"id":"quiet","serviceAccount":{},')
        + String('"uses":[{"cell":"LOGS","access":"READ"}]}]}')
    )
    assert_equal(_edges(own[0]), "u-qya4yr quiet->cell/LOGS READ")
    print("  test_the_edges_of_a_resource: PASS")


# ---- 3. every identity refusal in one pass --------------------------------------------


def test_every_identity_refusal_in_one_pass() raises:
    var json = (
        String('{"resource":[')
        + String('{"id":"runner","serviceAccount":{},')
        + String('"uses":[{"target":{"resource":"store"},"access":"READ"}]},')
        + String('{"id":"store","bucket":{}},')
        + String('{"id":"b44557","bucket":{}},')
        + String('{"id":"b73264","bucket":{}},')
        + String('{"id":"web","service":{') + String(IMG) + String("},")
        + String('"uses":[{"target":{"resource":"b44557"},"access":"READ"},')
        + String('{"target":{"resource":"b73264"},"access":"READ"},')
        + String('{"target":{"resource":"runner"},"access":"CALL"}]},')
        + String('{"id":"api","service":{') + String(IMG)
        + String(',"runAs":{"resource":"store"}}},')
        + String('{"id":"lost","containerJob":{') + String(IMG)
        + String(',"runAs":{"resource":"nobody"}}},')
        + String('{"id":"worker","containerJob":{') + String(IMG)
        + String(',"runAs":{"resource":"runner"}},')
        + String('"uses":[{"cell":"LOGS","access":"WRITE"}]},')
        + String('{"id":"g1","grant":{"principal":{"resource":"store"},')
        + String('"target":{"resource":"web"},"access":"CALL"}},')
        + String('{"id":"g2","grant":{"principal":{"resource":"worker"},')
        + String('"target":{"resource":"store"},"access":"READ"}},')
        + String('{"id":"g3","grant":{"principal":{"resource":"runner"},')
        + String('"target":{"resource":"store"},"access":"WRITE"}},')
        + String('{"id":"g4","grant":{"principal":{"resource":"web"},')
        + String('"target":{"resource":"store"},"access":"DESCRIBE"}},')
        + String('{"id":"g5","grant":{"principal":{"resource":"web"},')
        + String('"cell":"ARTIFACTS","access":"WRITE"}},')
        + String('{"id":"g6","grant":{"principal":{"resource":"web"},')
        + String('"target":{"resource":"store"},"cell":"LOGS","access":"READ"}},')
        + String('{"id":"g7","grant":{"principal":{"resource":"web"},"access":"READ"}},')
        + String('{"id":"g8","grant":{"principal":{"resource":"runner"},')
        + String('"target":{"resource":"web"},"access":"CALL"},')
        + String('"uses":[{"target":{"resource":"store"},"access":"READ"}]},')
        + String('{"id":"acct-keep","retention":"KEEP","serviceAccount":{}}')
        + String("]}")
    )
    var f = graph_findings(Catalog.v1(), _list(json))
    var t = _all_text(f)
    for want in [
        'api|service.run_as|run_as must name a service_account; "store" is a bucket',
        'lost|container_job.run_as|ref to missing resource "nobody"',
        'g1|grant.principal|the principal must be a service_account, or a workload (a service, a'
        + ' container_job or a worker) with no run_as; "store" is a bucket',
        'g2|grant.principal|"worker" runs as "runner" and has no identity of its own;'
        + ' name "runner" as the principal',
        'g3|grant|a second edge from the identity of "runner" to store; the first is'
        + ' uses[0] of "runner" (one edge per principal and target)',
        'worker|uses[0]|a second edge from the identity of "runner" to cell/LOGS; the'
        + ' first is the implicit cell LOGS WRITE edge of "runner"',
        'web|uses[1]|uses[1] of "web" and uses[0] of "web" lower to one role, u-u72wff;'
        + " write one of them as a grant resource",
        'web|uses[2]|service_account "runner" does not accept access CALL',
        'g4|grant|bucket "store" does not accept access DESCRIBE',
        "g5|grant|the cell's ARTIFACTS does not accept access WRITE (it accepts READ)",
        "g6|grant|names a target and a cell resource; an edge has exactly one",
        "g7|grant|no target",
        "g8|uses|a grant is one edge and runs as no identity",
        "acct-keep|retention|a service_account takes no retention",
    ]:
        assert_true(_has(t, String(want)), String("missing: ") + String(want) + "\n" + t)
    assert_equal(len(f), 14, "exactly the findings above, each once:\n" + t)
    for i in range(len(f)):
        assert_equal(f[i].kind, FINDING_GRAPH)
    print("  test_every_identity_refusal_in_one_pass: PASS")


def test_held_values_are_refused() raises:
    """ACT_AS 7 and MANAGE 9, and the cell's held 4, cannot be spelled in
    JSON; they can arrive on the wire, and are refused as verbs and cells
    nothing accepts."""
    var l = _list(
        String('{"resource":[{"id":"runner","serviceAccount":{}},')
        + String('{"id":"other","serviceAccount":{}},')
        + String('{"id":"web","service":{') + String(IMG) + String("},")
        + String('"uses":[{"target":{"resource":"runner"},"access":"DESCRIBE"},')
        + String('{"cell":"METRICS","access":"WRITE"},')
        + String('{"target":{"resource":"other"},"access":"DESCRIBE"}]}]}')
    )
    l[2].uses[0].access.value = 7
    l[2].uses[1].cell.value = 4
    l[2].uses[2].access.value = 9
    var f = graph_findings(Catalog.v1(), l)
    var t = _all_text(f)
    assert_true(_has(t, 'web|uses[0]|service_account "runner" does not accept access 7'), t)
    assert_true(
        _has(t, "web|uses[1]|cell resource 4 is not one this kci knows (LOGS, METRICS, ARTIFACTS)"), t
    )
    assert_true(_has(t, 'web|uses[2]|service_account "other" does not accept access 9'), t)
    assert_equal(len(f), 3, t)
    print("  test_held_values_are_refused: PASS")


# ---- 4. a good identity graph ---------------------------------------------------------


def test_a_good_identity_graph_is_clean() raises:
    var f = graph_findings(Catalog.v1(), _list(_good()))
    assert_equal(len(f), 0, _all_text(f))
    print("  test_a_good_identity_graph_is_clean: PASS")


def main() raises:
    print("test_cloud_identity_rules")
    test_the_role_of_an_edge_is_pinned()
    test_the_edges_of_a_resource()
    test_every_identity_refusal_in_one_pass()
    test_held_values_are_refused()
    test_a_good_identity_graph_is_clean()
    print("ALL kci_cloud IDENTITY RULE TESTS PASSED")
