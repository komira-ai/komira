# =============================================================================
# test_fake_composite.mojo: COMPOSITES, EXPANDED AND DEPLOYED, AT DEPTH.
# =============================================================================
#
# A composite instance goes through plan, apply and destroy on the generic
# fake cloud like any primitive, because expansion (kci_cloud/compose.mojo)
# runs before validate and every node is owned by the top-level resource.
# The list is one instance, `store`, of `acme.site@N`, which holds `logs` (a
# bucket) and `app`, an instance of `acme.app@N`: `ident` (a service
# account), `api` (a service running as `ident`, reading `files`' NAME and
# granted READ_WRITE on it), `files` (a KEEP bucket) and `scratch` (a DELETE
# bucket). Version 2 of `acme.app` drops `scratch`; version 3 also drops
# `files`. So `store/app/scratch` is at depth 2.
#
# 1. THE LOWERING IS DATA, GOLDEN: every node of the expanded list, owned by
#    `store` at every depth, with its resolved dependencies and inputs.
# 2. APPLY STAMPS THE TOP AS THE OWNER: every object is created; a depth-2
#    object's stamp names resource `store` and role `app/scratch/bucket`
#    (written `app_scratch_bucket`); the service reads the real NAME of the
#    bucket two levels down.
# 3. THE CLOSED WORLD AT DEPTH 2: applying version 2 deletes
#    `store/app/scratch/bucket` (a role of `store` the file no longer
#    lowers), reports no leftover, and leaves the rest alone.
# 4. RETENTION AT DEPTH 2: applying version 3 leaves the KEEP bucket
#    `store/app/files/bucket` BEHIND (reported, still live, no delete).
# 5. DESTROY AT DEPTH: everything goes but the KEEP bucket.
# 6. AN INSTANCE GONE FROM THE FILE: its objects are LEFTOVER (reported,
#    never deleted), as for a primitive.
# 7. THE ROLE LABEL BUDGET AT DEPTH 5: a bucket five instances down whose
#    role is 64 bytes encoded (segments 12, 12, 12, 12, 5 and `bucket`) is
#    one GRAPH finding at validate, and plan, apply and destroy refuse it
#    before the cloud serves any call; at 63 bytes (a 4-byte last segment)
#    it applies.
# 8. AN EXPANSION FINDING IS RETURNED ALONE by validate: the expanded graph
#    is not judged (here an id finding a primitive beside it would add).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    LABEL_RESOURCE,
    LABEL_ROLE,
    Label,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
)
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    Finding,
    FINDING_GRAPH,
    apply_resources,
    describe,
    destroy_resources,
    expand,
    lower_data,
    lowering_json,
    plan_resources,
    validate_for,
)

from kci_cloud_fake import FakeCloud, fake_bucket_name


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _reg(cloud: FakeCloud) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def _label(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return String("(none)")


def _lines(findings: List[Finding]) -> String:
    var s = String("")
    for i in range(len(findings)):
        s += findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason + String("\n")
    return s^


# ---- the definitions -----------------------------------------------------------------------------


def _app(version: Int) -> String:
    """`acme.app@<version>`: 1 has ident, api, files (KEEP) and scratch
    (DELETE); 2 drops scratch; 3 also drops files (and api's use of it)."""
    var api = String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"local":"ident"}')
    if version < 3:
        api = (
            String('{"id":"api","uses":[{"target":{"local":"files"},"access":"READ_WRITE"}],')
            + String('"service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"local":"ident"},')
            + String('"env":{"BUCKET":{"ref":{"local":"files","standard":"NAME"}}}')
        )
    var comps = String('{"id":"ident","serviceAccount":{}},') + api + String("}}")
    if version < 3:
        comps += String(',{"id":"files","retention":"KEEP","bucket":{}}')
    if version < 2:
        comps += String(',{"id":"scratch","retention":"DELETE","bucket":{}}')
    return String('{"name":"acme.app","version":"') + String(version) + String('","component":[') + comps + String("]}")


def _site(version: Int) -> String:
    return (
        String('{"name":"acme.site","version":"')
        + String(version)
        + String('","component":[{"id":"logs","retention":"DELETE","bucket":{}},')
        + String('{"id":"app","composite":{"definition":"acme.app","version":"')
        + String(version)
        + String('"}}]}')
    )


def _defs(version: Int) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    out.append(decode_json[CompositeDefinition](_app(version)))
    out.append(decode_json[CompositeDefinition](_site(version)))
    return out^


def _store(version: Int) -> String:
    return String('{"resource":[{"id":"store","composite":{"definition":"acme.site","version":"') + String(version) + String('"}}]}')


# ---- 1. the lowering is data, golden -------------------------------------------------------------

comptime _GOLDEN = (
    '[\n'
    + '  {"id":"store/logs/bucket","owner":"store","kind":"bucket","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"expiry_days":"never","versioning":"false","tier":"STANDARD","stores":"true"}},\n'
    + '  {"id":"store/app/ident/identity","owner":"store","kind":"identity","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"account":"true"}},\n'
    + '  {"id":"store/app/ident/u-mkfxm4","owner":"store","kind":"grant","wanted":true,"retention":"delete","depends_on":["store/app/ident/identity"],"inputs":[],"desired":{"principal":"store/app/ident","cell":"LOGS","access":"WRITE"}},\n'
    + '  {"id":"store/app/api/identity","owner":"store","kind":"identity","wanted":false,"retention":"delete","depends_on":[],"inputs":[],"desired":{}},\n'
    + '  {"id":"store/app/api/run","owner":"store","kind":"run","wanted":true,"retention":"delete","depends_on":["store/app/ident/identity"],"inputs":[{"producer":"store/app/files/bucket","output":"NAME","field":"service.env.BUCKET"}],"desired":{"img":"sha256:a1@linux/amd64","port":"8080","size":"1000m/512MB","scale":"0..10","health":"","timeout":"60s0n","concurrency":"0","run_as":"store/app/ident","serves":"true"}},\n'
    + '  {"id":"store/app/api/public","owner":"store","kind":"public","wanted":false,"retention":"delete","depends_on":["store/app/api/run"],"inputs":[],"desired":{"mechanism":"invoker"}},\n'
    + '  {"id":"store/app/api/u-a5mnki","owner":"store","kind":"grant","wanted":true,"retention":"delete","depends_on":["store/app/ident/identity","store/app/files/bucket"],"inputs":[],"desired":{"principal":"store/app/ident","target":"store/app/files","access":"READ_WRITE"}},\n'
    + '  {"id":"store/app/files/bucket","owner":"store","kind":"bucket","wanted":true,"retention":"keep","depends_on":[],"inputs":[],"desired":{"expiry_days":"never","versioning":"false","tier":"STANDARD","stores":"true"}},\n'
    + '  {"id":"store/app/scratch/bucket","owner":"store","kind":"bucket","wanted":true,"retention":"delete","depends_on":[],"inputs":[],"desired":{"expiry_days":"never","versioning":"false","tier":"STANDARD","stores":"true"}}\n'
    + ']'
)


def test_the_lowering_of_an_expanded_composite_is_golden() raises:
    """Catches: a node owned by its path instead of the top, a dependency or
    input left on a bare path instead of the primary node, and the
    retention of a component lost on the way down."""
    var x = expand(Catalog.v1(), _defs(1), _list(_store(1)))
    assert_equal(len(x.findings), 0, _lines(x.findings))
    var cloud = FakeCloud()
    assert_equal(lowering_json(lower_data(cloud, x.resources)), String(_GOLDEN))
    print("  test_the_lowering_of_an_expanded_composite_is_golden: PASS")


# ---- 2. apply stamps the top as the owner ----------------------------------------------------------


def test_apply_stamps_the_top_as_the_owner() raises:
    """Catches: an object stamped with its path as its resource (two owners
    for one top), a role label that is not the rest of the path, and a
    value that does not reach the service from two levels down."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var st = InMemoryStateStore()
    var applied = _done(apply_resources(reg, cloud, _ctx(), _list(_store(1)), Creds.none(), st, _defs(1)))
    for id in [String("store/logs/bucket"), String("store/app/ident/identity"), String("store/app/api/run"), String("store/app/files/bucket"), String("store/app/scratch/bucket")]:
        assert_equal(_verb(applied, id), VERB_CREATE, id + " is created")
    var labels = cloud.live_labels(String("store/app/scratch/bucket"))
    assert_equal(_label(labels, String(LABEL_RESOURCE)), "store", "the owner is the top")
    assert_equal(_label(labels, String(LABEL_ROLE)), "app_scratch_bucket", "the role is the rest of the path")
    var i = cloud.store[].find(String("store/app/api/run"))
    assert_true(i >= 0)
    var digest = cloud.store[].digests[i].copy()
    assert_true(digest.find(String("service.env.BUCKET=") + fake_bucket_name(String("store/app/files"))) >= 0, digest)
    print("  test_apply_stamps_the_top_as_the_owner: PASS")


# ---- 3. the closed world at depth 2 ------------------------------------------------------------------


def test_the_closed_world_at_depth_two() raises:
    """Catches: a component a definition dropped treated as the object of a
    resource the file no longer names (LEFTOVER, never deleted) instead of a
    role of `store` no longer lowered (deleted)."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_store(1)), Creds.none(), st, _defs(1)))
    var out = apply_resources(reg, cloud, _ctx(), _list(_store(2)), Creds.none(), st, _defs(2))
    var applied = _done(out)
    assert_equal(_verb(applied, String("store/app/scratch/bucket")), VERB_DELETE, "the dropped component is deleted")
    assert_true(cloud.store[].find(String("store/app/scratch/bucket")) < 0, "and gone from the cloud")
    assert_equal(len(out.leftover), 0, "nothing is leftover")
    assert_equal(len(out.left_behind), 0, "nothing is left behind")
    assert_true(cloud.store[].find(String("store/app/files/bucket")) >= 0, "the rest is kept")
    assert_true(cloud.store[].find(String("store/logs/bucket")) >= 0)
    print("  test_the_closed_world_at_depth_two: PASS")


# ---- 4. retention at depth 2 ---------------------------------------------------------------------------


def test_a_kept_component_dropped_at_depth_two_is_left_behind() raises:
    """Catches: a KEEP component deleted when its definition drops it (the
    retention of a primitive must hold at any depth)."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_store(2)), Creds.none(), st, _defs(2)))
    var out = apply_resources(reg, cloud, _ctx(), _list(_store(3)), Creds.none(), st, _defs(3))
    var applied = _done(out)
    assert_true(_verb(applied, String("store/app/files/bucket")) != VERB_DELETE, "no delete was issued")
    assert_true(cloud.store[].find(String("store/app/files/bucket")) >= 0, "the KEEP bucket is still live")
    assert_equal(len(out.left_behind), 1, "it is reported")
    assert_equal(out.left_behind[0], "store/app/files/bucket")
    print("  test_a_kept_component_dropped_at_depth_two_is_left_behind: PASS")


# ---- 5. destroy at depth -----------------------------------------------------------------------------------


def test_destroy_at_depth_keeps_only_the_kept() raises:
    """Catches: a destroy that misses the objects below the top, or deletes
    a KEEP one."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_store(1)), Creds.none(), st, _defs(1)))
    _ = destroy_resources(reg, cloud, _ctx(), _list(_store(1)), Creds.none(), st, _defs(1))
    assert_equal(cloud.live_count(), 1, "one object is left")
    assert_true(cloud.store[].find(String("store/app/files/bucket")) >= 0, "the KEEP bucket")
    print("  test_destroy_at_depth_keeps_only_the_kept: PASS")


# ---- 6. an instance gone from the file -------------------------------------------------------------------


def test_an_instance_gone_from_the_file_is_leftover() raises:
    """Catches: the objects of a dropped top-level instance deleted, or not
    reported (the file names no `store` any more: they are leftover, as a
    primitive's would be)."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var st = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_store(1)), Creds.none(), st, _defs(1)))
    var live = cloud.live_count()
    var out = apply_resources(reg, cloud, _ctx(), _list(String('{"resource":[{"id":"other","bucket":{}}]}')), Creds.none(), st, _defs(1))
    _ = _done(out)
    assert_equal(cloud.live_count(), live + 1, "nothing of store is deleted")
    var reported = 0
    for i in range(len(out.leftover)):
        if out.leftover[i].startswith("store/"):
            reported += 1
    assert_equal(reported, live, "every object of store is reported as leftover")
    print("  test_an_instance_gone_from_the_file_is_leftover: PASS")


# ---- 7. the role label budget at depth 5 ----------------------------------------------------------------


def _rep(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _chain(last: Int) raises -> List[CompositeDefinition]:
    """`acme.d1` .. `acme.d5`: d1..d4 each hold one instance of the next under
    a 12-byte id (`aaaaaaaaaaaa`, `bbbbbbbbbbbb`, ...); d5 holds one bucket
    under an id of `last` bytes."""
    var out = List[CompositeDefinition]()
    var letters: List[String] = ["a", "b", "c", "d"]
    for k in range(1, 5):
        out.append(
            decode_json[CompositeDefinition](
                String('{"name":"acme.d') + String(k) + String('","version":"1","component":[{"id":"')
                + _rep(letters[k - 1], 12)
                + String('","composite":{"definition":"acme.d') + String(k + 1) + String('","version":"1"}}]}')
            )
        )
    out.append(
        decode_json[CompositeDefinition](
            String('{"name":"acme.d5","version":"1","component":[{"id":"') + _rep(String("e"), last) + String('","retention":"DELETE","bucket":{}}]}')
        )
    )
    return out^


comptime _DEEP = '{"resource":[{"id":"t","composite":{"definition":"acme.d1","version":"1"}}]}'


def _deep_node(last: Int) -> String:
    return (
        String("t/") + _rep(String("a"), 12) + String("/") + _rep(String("b"), 12) + String("/")
        + _rep(String("c"), 12) + String("/") + _rep(String("d"), 12) + String("/") + _rep(String("e"), last) + String("/bucket")
    )


def test_the_role_label_budget_at_depth_five() raises:
    """Catches: the budget measured on the role below the produced resource
    (`bucket`, 6 bytes) instead of below the top (the whole path), a bound
    off by one, and a verb that creates anything before it is checked."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var f = validate_for(reg, cloud, _list(String(_DEEP)), _chain(5))
    assert_equal(len(f), 1, _lines(f))
    assert_equal(f[0].kind, FINDING_GRAPH)
    assert_equal(f[0].resource_id, "t", "the finding is on the owner")
    assert_equal(
        f[0].reason,
        String('node "') + _deep_node(5) + String('": its role label is 64 bytes encoded; at most 63 (segment lengths 12, 12, 12, 12, 5, 6; shorter ids or less nesting fit)'),
    )
    for verb in [String("plan"), String("apply"), String("destroy")]:
        var c = FakeCloud()
        var st = InMemoryStateStore()
        var msg = String("")
        try:
            if verb == "plan":
                _ = plan_resources(reg, c, _ctx(), _list(String(_DEEP)), Creds.none(), st, _chain(5))
            elif verb == "apply":
                _ = apply_resources(reg, c, _ctx(), _list(String(_DEEP)), Creds.none(), st, _chain(5))
            else:
                _ = destroy_resources(reg, c, _ctx(), _list(String(_DEEP)), Creds.none(), st, _chain(5))
            msg = verb + String(": NOT REFUSED")
        except e:
            msg = String(e)
        assert_true(msg.find("its role label is 64 bytes encoded") >= 0, msg)
        assert_equal(len(c.store[].calls), 0, verb + ": the cloud served no call")
    assert_equal(_lines(validate_for(reg, cloud, _list(String(_DEEP)), _chain(4))), "", "63 bytes pass")
    var st = InMemoryStateStore()
    var applied = _done(apply_resources(reg, cloud, _ctx(), _list(String(_DEEP)), Creds.none(), st, _chain(4)))
    assert_equal(_verb(applied, _deep_node(4)), VERB_CREATE, "and apply")
    print("  test_the_role_label_budget_at_depth_five: PASS")


# ---- 8. an expansion finding is returned alone ----------------------------------------------------------


def test_an_expansion_finding_is_returned_alone() raises:
    """Catches: validate judging a graph whose expansion was refused (the
    graph below a refused instance is not known)."""
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var bad = String(
        '{"resource":[{"id":"store","composite":{"definition":"acme.site","version":"1"}},{"id":"Bad","bucket":{}},'
        '{"id":"r","uses":[{"target":{"resource":"store","path":"logs"}}],"serviceAccount":{}}]}'
    )
    var f = validate_for(reg, cloud, _list(bad), _defs(1))
    assert_equal(len(f), 1, _lines(f))
    assert_equal(f[0].resource_id, "r")
    assert_true(f[0].reason.find("component \"logs\" of acme.site@1 is not exported") >= 0, f[0].reason)
    var ok = String('{"resource":[{"id":"store","composite":{"definition":"acme.site","version":"1"}},{"id":"Bad","bucket":{}}]}')
    var g = validate_for(reg, cloud, _list(ok), _defs(1))
    assert_equal(len(g), 1, _lines(g))
    assert_equal(g[0].resource_id, "Bad", "the control: with the expansion clean, the graph is judged")
    print("  test_an_expansion_finding_is_returned_alone: PASS")


def main() raises:
    print("test_fake_composite: composites deployed at depth")
    test_the_closed_world_at_depth_two()
    test_the_lowering_of_an_expanded_composite_is_golden()
    test_apply_stamps_the_top_as_the_owner()
    test_a_kept_component_dropped_at_depth_two_is_left_behind()
    test_destroy_at_depth_keeps_only_the_kept()
    test_an_instance_gone_from_the_file_is_leftover()
    test_the_role_label_budget_at_depth_five()
    test_an_expansion_finding_is_returned_alone()
    print("ALL kci_cloud_fake COMPOSITE TESTS PASSED")
