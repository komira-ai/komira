# =============================================================================
# test_cloud_adoption_rules.mojo
# =============================================================================
#
# The rules of safe adoption (adoption.mojo, metadata.mojo, labels.mojo) as
# pure functions over values: no cloud is realized here. The fake clouds
# run them end to end (kci_cloud_fake tests/test_fake_adoption*.mojo).
#
# 1. THE GRAPH RULE: `adopt_deletable` written true without `adopt` is one
#    GRAPH finding on `adopt_deletable`; written false, or with `adopt`, it
#    is none (`adopt_deletable_of` reads the value, not the presence).
# 2. WHAT AN ADOPTION COMPARES (`existing_mismatches`): the kind, the cloud
#    name and every field both sides hold, each named with both values; the
#    author's labels and a field only the cloud reports are not compared.
# 3. WHOSE OPT-IN COUNTS (`resource_of_node`, `deletable`): the longest
#    resource id that prefixes the node, so `top/a/files/bucket` belongs to
#    `top/a/files`, never to `top/a`; a node no resource prefixes has none.
# 4. THE ADOPTED NODES (`adopted_nodes_of`): the nodes taken over this run,
#    then each node whose object carries the mark, each once.
# 5. A DELETE OF AN ADOPTED OBJECT (`delete_findings`): refused when a plan
#    turns its node off or a destroy reaches it, unless kept by retention or
#    its resource writes `adopt_deletable`; a wanted node on a plan, an
#    unmarked object, or a node not in the run is not refused.
# 6. A REPLACE OF AN ADOPTED NODE (`replace_findings`): refused unless its
#    resource writes `adopt_deletable`, naming the engine's reason; an
#    update, or a replace of a node kci created, is not.
# 7. THE MARK (`adoption_labels`, `adopted_by`, `is_kci_label_key`): one
#    label `kci_adopted=true`, read back only at that value, inside kci's
#    label space (so a release drops it, and an author may not write it);
#    the standard rule takes it, and it is not part of the identity.
# 8. THE MARK ON A LOWERED NODE: `to_json` writes `"adopted":true` on a node
#    marked adopted and nothing on one that is not, so every earlier
#    lowering golden is unchanged. (Which node `lower_data` marks is the
#    fakes': test_fake_adoption.mojo.)
# 9. THE PLAN SAYS SO (`group_plan`, `render_plan`): `(adopted)` beside each
#    adopted node's verb, and one release line per released node under its
#    owner, after the actions.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import (
    ChangeAction,
    InputRef,
    Label,
    OwnerStamp,
    Provenance,
    RETAIN_DELETE,
    VERB_DELETE,
    VERB_NOOP,
    VERB_REPLACE,
    VERB_UPDATE,
)
from kci_resource_proto.resource import Resource, ResourceList
from kci_cloud import (
    ExistingObject,
    FINDING_ADOPTION,
    FINDING_GRAPH,
    LoweredNode,
    OwnedRecord,
    PlanReport,
    Setting,
    adopt_deletable_of,
    adopted_by,
    adopted_nodes_of,
    adoption_labels,
    deletable,
    delete_findings,
    existing_mismatches,
    group_plan,
    is_kci_label_key,
    label_key_problem,
    label_problems,
    metadata_findings,
    render_plan,
    replace_findings,
    resource_of_node,
    standard_identity_of,
    standard_label_rule,
    Catalog,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _node(id: String, wanted: Bool = True, adopted: Bool = True) -> LoweredNode:
    """`id` as a bucket node that declares versioning false, tier STANDARD,
    one label and the cloud name `acme-logs`."""
    var desired = List[Setting]()
    desired.append(Setting(String("versioning"), String("false")))
    desired.append(Setting(String("tier"), String("STANDARD")))
    desired.append(Setting(String("label.team"), String("data")))
    desired.append(Setting(String("physical_name"), String("acme-logs")))
    var owner = String(id[byte = 0 : id.find("/")])
    return LoweredNode(
        id, owner, String("bucket"), List[String](), List[InputRef](), desired^, wanted, RETAIN_DELETE, adopted
    )


def _seen(kind: String, name: String, versioning: String, team: String) -> ExistingObject:
    var fields = List[Setting]()
    fields.append(Setting(String("versioning"), versioning))
    fields.append(Setting(String("label.team"), team))
    fields.append(Setting(String("region"), String("only-the-cloud-says")))
    return ExistingObject(True, False, kind, name, fields^)


def _record(node: String, adopted: Bool, retained: Bool = False) -> OwnedRecord:
    return OwnedRecord(
        String("bucket"),
        node,
        String("here"),
        String("none"),
        String("1"),
        String("run-1"),
        True,
        node,
        retained,
        String(""),
        None,
        String("acme-logs"),
        adopted,
    )


# ---- 1. the graph rule ------------------------------------------------------------------


def test_adopt_deletable_needs_adopt() raises:
    """Catches: the graph finding dropped (mutant: `adopt_deletable` without
    `adopt` accepted), a written false refused (the rule reading presence,
    not the value), and the finding made with `adopt` written."""
    var l = _list(
        String('{"resource":[')
        + String('{"id":"a","physicalName":"a-1","adoptDeletable":true,"bucket":{}},')
        + String('{"id":"b","physicalName":"b-1","adoptDeletable":false,"bucket":{}},')
        + String('{"id":"c","physicalName":"c-1","adopt":true,"adoptDeletable":true,"bucket":{}},')
        + String('{"id":"d","physicalName":"d-1","adopt":true,"bucket":{}}')
        + String("]}")
    )
    var cat = Catalog.v1()
    var a = metadata_findings(cat, l, l[0])
    assert_equal(len(a), 1, "adopt_deletable without adopt: one finding")
    assert_equal(a[0].kind, FINDING_GRAPH)
    assert_equal(a[0].field_path, "adopt_deletable")
    assert_true(a[0].reason.find("writes no adopt") >= 0, a[0].reason)
    assert_equal(len(metadata_findings(cat, l, l[1])), 0, "a written false is the same as unset")
    assert_equal(len(metadata_findings(cat, l, l[2])), 0, "with adopt it is taken")
    assert_true(adopt_deletable_of(l[0]) and not adopt_deletable_of(l[1]) and not adopt_deletable_of(l[3]))
    print("  test_adopt_deletable_needs_adopt: PASS")


# ---- 2. what an adoption compares ---------------------------------------------------------


def test_existing_mismatches_name_both_sides() raises:
    """Catches: the kind, the name or a field not compared (each mutant
    leaves one line out), a side missing from a line, the author's labels
    compared (an adoption writes them, so a different label must pass), and
    a field only the cloud reports compared."""
    var n = _node(String("logs/bucket"))
    assert_equal(len(existing_mismatches(n, _seen("bucket", "acme-logs", "false", "other"))), 0, "the same object")
    var d = existing_mismatches(n, _seen("queue", "old-logs", "true", "data"))
    assert_equal(len(d), 3, "kind, name and versioning")
    assert_equal(d[0], 'kind: the resource declares "bucket", the cloud holds "queue"')
    assert_equal(d[1], 'cloud name: the resource declares "acme-logs", the cloud holds "old-logs"')
    assert_equal(d[2], 'versioning: the resource declares "false", the cloud holds "true"')
    var unnamed = existing_mismatches(n, _seen("bucket", "", "false", "data"))
    assert_equal(len(unnamed), 1)
    assert_equal(unnamed[0], 'cloud name: the resource declares "acme-logs", the cloud holds none')
    print("  test_existing_mismatches_name_both_sides: PASS")


# ---- 3. whose opt-in counts ----------------------------------------------------------------


def test_the_resource_of_a_node_is_the_longest_prefix() raises:
    """Catches: the shortest prefix taken (`top/a` would answer for
    `top/a/files/bucket`), a bare string prefix (`top/a` is not a prefix of
    `top/ab/x`), and the opt-in read from presence."""
    var l = _list(
        String('{"resource":[')
        + String('{"id":"top/a","physicalName":"a-1","adopt":true,"adoptDeletable":true,"bucket":{}},')
        + String('{"id":"top/a/files","physicalName":"f-1","adopt":true,"adoptDeletable":false,"bucket":{}},')
        + String('{"id":"logs","physicalName":"l-1","adopt":true,"adoptDeletable":true,"bucket":{}}')
        + String("]}")
    )
    assert_equal(resource_of_node(l, String("top/a/files/bucket")), 1, "the longest prefix")
    assert_equal(resource_of_node(l, String("top/a/bucket")), 0)
    assert_equal(resource_of_node(l, String("top/ab/bucket")), -1, "a prefix ends at a /")
    assert_equal(resource_of_node(l, String("gone/bucket")), -1, "a resource that left the list")
    assert_true(not deletable(l, String("top/a/files/bucket")), "written false: not deletable")
    assert_true(deletable(l, String("top/a/bucket")))
    assert_true(deletable(l, String("logs/bucket")))
    assert_true(not deletable(l, String("gone/bucket")), "no resource, no opt-in")
    print("  test_the_resource_of_a_node_is_the_longest_prefix: PASS")


# ---- 4. the adopted nodes -------------------------------------------------------------------


def test_adopted_nodes_are_taken_and_marked_once() raises:
    """Catches: a marked object left out, an unmarked one put in, and a node
    both taken and marked listed twice."""
    var owned = List[OwnedRecord]()
    owned.append(_record(String("logs/bucket"), True))
    owned.append(_record(String("made/bucket"), False))
    owned.append(_record(String("old/bucket"), True))
    var taking = List[String]()
    taking.append(String("new/bucket"))
    taking.append(String("logs/bucket"))
    var got = adopted_nodes_of(owned, taking)
    assert_equal(len(got), 3)
    assert_equal(got[0], "new/bucket")
    assert_equal(got[1], "logs/bucket")
    assert_equal(got[2], "old/bucket")
    print("  test_adopted_nodes_are_taken_and_marked_once: PASS")


# ---- 5. a delete of an adopted object -------------------------------------------------------


def test_a_delete_of_an_adopted_object_is_refused() raises:
    """Catches: the check dropped (mutant: no finding), a wanted node refused
    on a plan, a destroy let through, an object kept by retention refused,
    an unmarked object refused, and the opt-in ignored."""
    var l = _list(
        String('{"resource":[')
        + String('{"id":"logs","physicalName":"acme-logs","adopt":true,"bucket":{}},')
        + String('{"id":"own","physicalName":"own-1","adopt":true,"adoptDeletable":true,"bucket":{}},')
        + String('{"id":"kept","physicalName":"kept-1","adopt":true,"bucket":{}},')
        + String('{"id":"made","bucket":{}}')
        + String("]}")
    )
    var owned = List[OwnedRecord]()
    owned.append(_record(String("logs/bucket"), True))
    owned.append(_record(String("own/bucket"), True))
    owned.append(_record(String("kept/bucket"), True, retained=True))
    owned.append(_record(String("made/bucket"), False))
    owned.append(_record(String("elsewhere/bucket"), True))
    var off = List[LoweredNode]()
    off.append(_node(String("logs/bucket"), wanted=False))
    off.append(_node(String("own/bucket"), wanted=False))
    off.append(_node(String("kept/bucket"), wanted=False))
    off.append(_node(String("made/bucket"), wanted=False, adopted=False))
    var plan = delete_findings(off, owned, l, False)
    assert_equal(len(plan), 1, "only logs: own opted in, kept is retained, made is kci's")
    assert_equal(plan[0].kind, FINDING_ADOPTION)
    assert_equal(plan[0].resource_id, "logs")
    assert_equal(plan[0].field_path, "adopt_deletable")
    assert_true(plan[0].reason.startswith("logs/bucket: kci adopted this object"), plan[0].reason)
    assert_true(plan[0].reason.find("the resource no longer lowers it") >= 0, plan[0].reason)
    assert_true(plan[0].reason.find("release the object") >= 0, plan[0].reason)
    var on = List[LoweredNode]()
    on.append(_node(String("logs/bucket")))
    on.append(_node(String("own/bucket")))
    assert_equal(len(delete_findings(on, owned, l, False)), 0, "a wanted node is not deleted by a plan")
    var gone = delete_findings(on, owned, l, True)
    assert_equal(len(gone), 1, "a destroy reaches logs; own opted in")
    assert_true(gone[0].reason.find("this destroy would delete it") >= 0, gone[0].reason)
    print("  test_a_delete_of_an_adopted_object_is_refused: PASS")


# ---- 6. a replace of an adopted node --------------------------------------------------------


def test_a_replace_of_an_adopted_node_is_refused() raises:
    """Catches: the check dropped, an update refused, a replace of a node kci
    created refused, the opt-in ignored, and the engine's reason lost."""
    var l = _list(
        String('{"resource":[')
        + String('{"id":"logs","physicalName":"acme-logs","adopt":true,"bucket":{}},')
        + String('{"id":"own","physicalName":"own-1","adopt":true,"adoptDeletable":true,"bucket":{}},')
        + String('{"id":"made","bucket":{}}')
        + String("]}")
    )
    var actions = List[ChangeAction]()
    actions.append(ChangeAction(String("logs/bucket"), VERB_REPLACE, String("tier is fixed"), RETAIN_DELETE))
    actions.append(ChangeAction(String("own/bucket"), VERB_REPLACE, String("tier is fixed"), RETAIN_DELETE))
    actions.append(ChangeAction(String("made/bucket"), VERB_REPLACE, String("tier is fixed"), RETAIN_DELETE))
    actions.append(ChangeAction(String("logs/bucket"), VERB_UPDATE, String("drifted"), RETAIN_DELETE))
    var adopted = List[String]()
    adopted.append(String("logs/bucket"))
    adopted.append(String("own/bucket"))
    var got = replace_findings(actions, adopted, l)
    assert_equal(len(got), 1)
    assert_equal(got[0].resource_id, "logs")
    assert_true(got[0].reason.find("this change would replace it") >= 0, got[0].reason)
    assert_true(got[0].reason.find("tier is fixed") >= 0, "the engine's reason is kept: " + got[0].reason)
    print("  test_a_replace_of_an_adopted_node_is_refused: PASS")


# ---- 7. the mark ----------------------------------------------------------------------------


def test_the_adoption_mark() raises:
    """Catches: a mark written when not adopted, another key or value, a mark
    read back at any value, a key outside kci's label space (an author could
    forge it, and a release would keep it), a key the standard rule refuses,
    and the mark read as part of the identity."""
    assert_equal(len(adoption_labels(False)), 0)
    var m = adoption_labels(True)
    assert_equal(len(m), 1)
    assert_equal(m[0].key, "kci_adopted")
    assert_equal(m[0].value, "true")
    assert_true(adopted_by(m))
    var other = List[Label]()
    other.append(Label(String("kci_adopted"), String("yes")))
    assert_true(not adopted_by(other), "only `true` is adopted")
    assert_true(is_kci_label_key(m[0].key), "inside kci's label space")
    assert_true(is_kci_label_key(String("kci-retention")) and is_kci_label_key(String("kci_cell")))
    assert_true(not is_kci_label_key(String("team")) and not is_kci_label_key(String("kcix")))
    assert_true(label_key_problem(m[0].key).byte_length() > 0, "an author may not write it")
    assert_equal(len(label_problems(m)), 0, "the standard rule takes it")
    var stamp = OwnerStamp(
        String("shop"), String("blue"), String("logs"), String("bucket"), 1, Provenance.none(), None
    )
    var labels = standard_label_rule(stamp)
    var with_mark = labels.copy()
    with_mark.extend(m.copy())
    assert_equal(standard_identity_of(with_mark), standard_identity_of(labels), "not part of the identity")
    print("  test_the_adoption_mark: PASS")


# ---- 8. the lowering marks the primary node only --------------------------------------------


def test_only_the_adopted_node_renders_adopted() raises:
    """Catches: `adopted` written on every node's JSON (every lowering golden
    would move) or on none."""
    var on = _node(String("logs/bucket")).to_json()
    var off = _node(String("logs/bucket"), adopted=False).to_json()
    assert_true(on.find('"retention":"delete","adopted":true,') >= 0, on)
    assert_true(off.find("adopted") < 0, off)
    print("  test_only_the_adopted_node_renders_adopted: PASS")


# ---- 9. the plan says so --------------------------------------------------------------------


def test_the_plan_marks_adoptions_and_releases() raises:
    """Catches: the `(adopted)` mark dropped or put on another node, a
    release not printed, printed under the wrong owner, or printed before
    the actions."""
    var actions = List[ChangeAction]()
    actions.append(ChangeAction(String("logs/bucket"), VERB_UPDATE, String("x"), RETAIN_DELETE, String("logs")))
    actions.append(ChangeAction(String("reader/identity"), VERB_NOOP, String("x"), RETAIN_DELETE, String("reader")))
    var adopted = List[String]()
    adopted.append(String("logs/bucket"))
    var released = List[String]()
    released.append(String("old/bucket"))
    released.append(String("site/app/files/bucket"))
    var text = render_plan(PlanReport(actions^, adopted^, released^))
    assert_equal(
        text,
        String("logs: update logs/bucket (adopted)\n")
        + String("reader: noop reader/identity\n")
        + String("old: release old/bucket (adopted; kci drops its stamp and record and leaves it standing)\n")
        + String("site: release site/app/files/bucket (adopted; kci drops its stamp and record and leaves it standing)"),
    )
    var bare = List[ChangeAction]()
    bare.append(ChangeAction(String("logs/bucket"), VERB_UPDATE, String("x"), RETAIN_DELETE, String("logs")))
    assert_equal(group_plan(bare), "logs: update logs/bucket", "no mark without adoptions")
    print("  test_the_plan_marks_adoptions_and_releases: PASS")


def main() raises:
    print("test_cloud_adoption_rules")
    test_adopt_deletable_needs_adopt()
    test_existing_mismatches_name_both_sides()
    test_the_resource_of_a_node_is_the_longest_prefix()
    test_adopted_nodes_are_taken_and_marked_once()
    test_a_delete_of_an_adopted_object_is_refused()
    test_a_replace_of_an_adopted_node_is_refused()
    test_the_adoption_mark()
    test_only_the_adopted_node_renders_adopted()
    test_the_plan_marks_adoptions_and_releases()
    print("ALL ADOPTION RULE TESTS PASSED")
