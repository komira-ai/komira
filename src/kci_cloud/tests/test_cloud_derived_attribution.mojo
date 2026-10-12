# =============================================================================
# test_cloud_derived_attribution.mojo
# =============================================================================
#
# The DERIVED stamp of a member binding (derived.mojo) and the two refusals
# of a shape whose grants are DERIVED (shape/lower.mojo), with no cloud:
#
# 1. ATTRIBUTION: a member identity of this cell holding a mapped role on an
#    object this cell owns is the node `<P>/u-<h>`, read as the labels
#    `create_labels` writes for it, with the member's retention and run id;
#    everyone on the public role is `<T>/public`; a cell-scope binding hashes
#    `cell/<NAME>`; a composite's identity keeps its path and its owner; a
#    composite TARGET hashes its component path (`site/store`), never its
#    top resource, and a composite's public binding is `<component>/public`.
# 2. NOT OURS: an identity of another cell, or of another machine with the
#    same cell name (THE MEMBER CHECK, each coordinate alone), a role the
#    table does not map (or maps twice), a member that is not an identity, a
#    target of another cell or of another kind, a target kind's role held on
#    the cell scope, everyone on a non-public role: each is no attribution
#    (an unmanaged difference).
# 3. THE TABLE IS INJECTIVE: `role_table_problems` names a role on two rows
#    and a (target, access) with two roles, wherever in the table they are.
# 4. THE REFUSALS: on gcp (DERIVED) a `grant` resource and a `uses` line on a
#    workload with `run_as` are each a limit finding naming the fix; on aws
#    (labelled) neither is.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_reconciler import CellScope, Label, Provenance, RETAIN_DELETE, RETAIN_KEEP
from kci_resource_proto.resource import Resource
from kci_cloud import (
    ACCESS_PUBLIC,
    ALL_USERS,
    BindingEnd,
    DERIVED_CITATION,
    Finding,
    ProviderShape,
    RoleRow,
    attribute,
    create_labels,
    retained_by,
    role_table_problems,
    shape_limits,
    standard_identity_of,
    uses_role,
    validation_run_of,
)
from kci_cloud.feed import Feed
from kci_cloud.firing import Firing


comptime _SA = "iam.googleapis.com/ServiceAccount"
comptime _BUCKET = "storage.googleapis.com/Bucket"
comptime _RUN = "run.googleapis.com/Service"


def _scope(
    cell: String = String("blue"), run: Optional[String] = None, machine: String = String("shop")
) -> CellScope:
    var s = CellScope(machine, cell, Provenance(String("run-1"), String("rev-1")))
    s.validation_run_id = run.copy()
    return s^


def _object(scope: CellScope, owner: String, node: String, kind: String, retention: Int = RETAIN_DELETE) raises -> BindingEnd:
    """An object of `scope` at `node` of resource `owner`, born stamped."""
    return BindingEnd(kind, create_labels(scope.stamp(owner, node), retention))


def _rows() -> List[RoleRow]:
    var l = List[RoleRow]()
    l.append(RoleRow(String(_BUCKET), String("READ"), String("roles/storage.objectViewer")))
    l.append(RoleRow(String(_SA), String("DESCRIBE"), String("roles/iam.serviceAccountViewer")))
    l.append(RoleRow(String("cell/LOGS"), String("WRITE"), String("roles/logging.logWriter")))
    l.append(RoleRow(String(_RUN), String(ACCESS_PUBLIC), String("roles/run.invoker")))
    l.append(RoleRow(String(_RUN), String("CALL"), String("roles/run.developer")))
    return l^


def _cell() -> BindingEnd:
    return BindingEnd()


# ---- 1. attribution -----------------------------------------------------------------


def test_a_cell_member_on_an_owned_target_is_its_uses_node() raises:
    """Catches: a node id not `<P>/u-<h>` of (P, target path), labels that do
    not decode to that node, or a retention or run id not the member's."""
    var s = _scope(run=String("vr-7"))
    var member = _object(s, String("runner"), String("runner/identity"), String(_SA), RETAIN_KEEP)
    var target = _object(s, String("media"), String("media/bucket"), String(_BUCKET))
    var d = attribute(False, target, False, member, String("roles/storage.objectViewer"), _rows())
    assert_true(Bool(d), "attributed")
    var node = String("runner/") + uses_role(String("runner"), String("media"))
    assert_equal(d.value().node, node)
    assert_equal(d.value().machine, "shop")
    assert_equal(d.value().cell, "blue")
    assert_equal(standard_identity_of(d.value().labels), s.stamp(String("runner"), node).identity())
    assert_true(retained_by(d.value().labels), "the member's retention (KEEP)")
    assert_equal(validation_run_of(d.value().labels).value(), "vr-7", "the member's run id")
    print("  test_a_cell_member_on_an_owned_target_is_its_uses_node: PASS")


def test_everyone_on_the_public_role_is_the_public_node() raises:
    var s = _scope()
    var target = _object(s, String("api"), String("api/run"), String(_RUN))
    var d = attribute(False, target, True, BindingEnd(), String("roles/run.invoker"), _rows())
    assert_true(Bool(d), "attributed")
    assert_equal(d.value().node, "api/public")
    assert_equal(standard_identity_of(d.value().labels), s.stamp(String("api"), String("api/public")).identity())
    assert_false(Bool(validation_run_of(d.value().labels)), "no run id: the target carries none")
    print("  test_everyone_on_the_public_role_is_the_public_node: PASS")


def test_a_cell_scope_binding_hashes_the_cell_path() raises:
    var s = _scope()
    var member = _object(s, String("api"), String("api/identity"), String(_SA))
    var d = attribute(True, _cell(), False, member, String("roles/logging.logWriter"), _rows())
    assert_true(Bool(d), "attributed")
    assert_equal(d.value().node, String("api/") + uses_role(String("api"), String("cell/LOGS")))
    print("  test_a_cell_scope_binding_hashes_the_cell_path: PASS")


def test_a_composite_identity_keeps_its_path_and_owner() raises:
    var s = _scope()
    var member = _object(s, String("web"), String("web/account/identity"), String(_SA))
    var d = attribute(True, _cell(), False, member, String("roles/logging.logWriter"), _rows())
    assert_true(Bool(d), "attributed")
    var node = String("web/account/") + uses_role(String("web/account"), String("cell/LOGS"))
    assert_equal(d.value().node, node)
    assert_equal(standard_identity_of(d.value().labels), s.stamp(String("web"), node).identity(), "owned by the top")
    print("  test_a_composite_identity_keeps_its_path_and_owner: PASS")


def test_a_composite_target_hashes_its_component_path() raises:
    """Lowering hashes a `uses` target's expanded id (grants.mojo:
    `uses_role(owner, "site/store")` for a sibling component). Catches: the
    target path taken as the target's top resource (`site`) or the public
    node put on it (`site/public`): the derived node would then differ from
    the wanted one, and every apply would delete and re-create the grant."""
    var s = _scope()
    var member = _object(s, String("runner"), String("runner/identity"), String(_SA))
    var target = _object(s, String("site"), String("site/store/bucket"), String(_BUCKET))
    var d = attribute(False, target, False, member, String("roles/storage.objectViewer"), _rows())
    assert_true(Bool(d), "attributed")
    assert_equal(d.value().node, String("runner/") + uses_role(String("runner"), String("site/store")))
    var run = _object(s, String("site"), String("site/web/run"), String(_RUN))
    var p = attribute(False, run, True, BindingEnd(), String("roles/run.invoker"), _rows())
    assert_true(Bool(p), "attributed")
    assert_equal(p.value().node, "site/web/public")
    assert_equal(
        standard_identity_of(p.value().labels), s.stamp(String("site"), String("site/web/public")).identity(),
        "owned by the top",
    )
    print("  test_a_composite_target_hashes_its_component_path: PASS")


# ---- 2. not ours --------------------------------------------------------------------


def test_an_identity_of_another_cell_is_never_this_cells() raises:
    """THE MEMBER CHECK. Catches: a foreign member holding a mapped role on an
    object this cell owns read as this cell's (it would be a node of the
    cell, and an apply could remove or rewrite it)."""
    var s = _scope()
    var other = _scope(String("green"))
    var member = _object(other, String("runner"), String("runner/identity"), String(_SA))
    var target = _object(s, String("media"), String("media/bucket"), String(_BUCKET))
    var d = attribute(False, target, False, member, String("roles/storage.objectViewer"), _rows())
    assert_false(Bool(d), "another cell's identity on this cell's bucket is not attributed")
    # On the cell scope it is attributed, but to ITS cell, never to this one.
    var c = attribute(True, _cell(), False, member, String("roles/logging.logWriter"), _rows())
    assert_true(Bool(c) and c.value().cell == "green", "another cell's own cell-scope binding")
    print("  test_an_identity_of_another_cell_is_never_this_cells: PASS")


def test_an_identity_of_another_machine_is_never_this_cells() raises:
    """THE MEMBER CHECK, its machine half. Two machines may name a cell the
    same in one project. Catches: a check that compares only the cells, so
    the other machine's identity holding a mapped role on this cell's bucket
    reads as this cell's node (an apply could remove or rewrite it)."""
    var s = _scope()
    var other = _scope(machine=String("depot"))
    var member = _object(other, String("runner"), String("runner/identity"), String(_SA))
    var target = _object(s, String("media"), String("media/bucket"), String(_BUCKET))
    var d = attribute(False, target, False, member, String("roles/storage.objectViewer"), _rows())
    assert_false(Bool(d), "another machine's identity of the same cell name on this cell's bucket")
    # Its own machine's bucket of the same cell name: attributed, to that machine.
    var its = _object(other, String("media"), String("media/bucket"), String(_BUCKET))
    var e = attribute(False, its, False, member, String("roles/storage.objectViewer"), _rows())
    assert_true(Bool(e) and e.value().machine == "depot", "the other machine's own binding")
    print("  test_an_identity_of_another_machine_is_never_this_cells: PASS")


def test_what_the_table_does_not_map_is_not_ours() raises:
    """Catches: an unmapped or twice-mapped role read as a verb, a role of
    another kind on the target, and a target kind's role on the cell scope
    read as a node (`<P>/u-h(P, <kind>)`: owned, unwanted, deleted by an
    apply) when the cell-scope branch does not require a `cell/<NAME>` row."""
    var s = _scope()
    var member = _object(s, String("runner"), String("runner/identity"), String(_SA))
    var target = _object(s, String("media"), String("media/bucket"), String(_BUCKET))
    assert_false(Bool(attribute(False, target, False, member, String("roles/owner"), _rows())), "unmapped")
    var twice = _rows()
    twice.append(RoleRow(String(_SA), String("READ"), String("roles/storage.objectViewer")))
    assert_false(
        Bool(attribute(False, target, False, member, String("roles/storage.objectViewer"), twice)),
        "a role on two rows reads back to no verb",
    )
    assert_false(
        Bool(attribute(True, _cell(), False, member, String("roles/storage.objectViewer"), _rows())),
        "a bucket's role on the cell scope: no cell/<NAME> row, so no node",
    )
    var wrong_kind = _object(s, String("media"), String("media/bucket"), String(_SA))
    assert_false(
        Bool(attribute(False, wrong_kind, False, member, String("roles/storage.objectViewer"), _rows())),
        "the role is a bucket's, the target is not a bucket",
    )
    print("  test_what_the_table_does_not_map_is_not_ours: PASS")


def test_a_member_or_target_kci_does_not_own_is_not_ours() raises:
    var s = _scope()
    var target = _object(s, String("media"), String("media/bucket"), String(_BUCKET))
    var run = _object(s, String("api"), String("api/run"), String(_RUN))
    var role = String("roles/storage.objectViewer")
    assert_false(Bool(attribute(False, target, False, BindingEnd(String(_SA)), role, _rows())), "unstamped member")
    assert_false(Bool(attribute(False, target, False, run, role, _rows())), "a member that is not an identity")
    var member = _object(s, String("runner"), String("runner/identity"), String(_SA))
    assert_false(Bool(attribute(False, BindingEnd(String(_BUCKET)), False, member, role, _rows())), "unstamped target")
    var theirs = _object(_scope(String("green")), String("media"), String("media/bucket"), String(_BUCKET))
    assert_false(Bool(attribute(False, theirs, False, member, role, _rows())), "another cell's target")
    assert_false(
        Bool(attribute(False, target, True, BindingEnd(), role, _rows())), "everyone on a role that is not public"
    )
    assert_false(
        Bool(attribute(False, run, False, member, String("roles/run.invoker"), _rows())),
        "an identity on the public role",
    )
    print("  test_a_member_or_target_kci_does_not_own_is_not_ours: PASS")


# ---- 3. the table is injective --------------------------------------------------------


def test_the_role_table_must_be_injective() raises:
    """Catches: a check that compares only the first row with the rest (the
    collisions below sit after it)."""
    assert_equal(len(role_table_problems(_rows())), 0, "the test table is injective")
    var role_twice = _rows()
    role_twice.append(RoleRow(String("cell/LOGS"), String("READ"), String("roles/run.developer")))
    var p = role_table_problems(role_twice)
    assert_equal(len(p), 1, "one problem")
    assert_true(p[0].find("roles/run.developer") >= 0, p[0])
    var verb_twice = _rows()
    verb_twice.append(RoleRow(String("cell/LOGS"), String("WRITE"), String("roles/logging.admin")))
    var q = role_table_problems(verb_twice)
    assert_equal(len(q), 1, "one problem")
    assert_true(q[0].find("cell/LOGS WRITE has two roles") >= 0, q[0])
    print("  test_the_role_table_must_be_injective: PASS")


# ---- 4. the refusals of a DERIVED shape ------------------------------------------------


def _limits(shape: ProviderShape, json: String) raises -> List[Finding]:
    var out = List[Finding]()
    shape_limits(decode_json[Resource](json), List[Feed](), List[Firing](), shape, String("p-g"), out)
    return out^


def _derived_findings(f: List[Finding]) -> List[Finding]:
    var out = List[Finding]()
    for i in range(len(f)):
        if f[i].citation == DERIVED_CITATION:
            out.append(f[i].copy())
    return out^


comptime _GRANT = '{"id":"see","grant":{"principal":{"resource":"web"},"target":{"resource":"runner"},"access":"DESCRIBE"}}'
comptime _RUN_AS_USES = (
    '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"resource":"runner"}},'
    + '"uses":[{"target":{"resource":"store"},"access":"READ"}]}'
)
comptime _RUN_AS = '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"resource":"runner"}}}'
comptime _RUN_AS_CELL_USES = (
    '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},"runAs":{"resource":"runner"}},'
    + '"uses":[{"cell":"LOGS","access":"WRITE"}]}'
)
comptime _OWN_USES = (
    '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}},'
    + '"uses":[{"target":{"resource":"store"},"access":"READ"}]}'
)


def test_a_derived_shape_refuses_a_grant_resource() raises:
    """Catches: a grant resource accepted on a DERIVED shape (its node would
    be owned by the grant, not by its principal, and could not be derived)."""
    var f = _derived_findings(_limits(ProviderShape.gcp(), String(_GRANT)))
    assert_equal(len(f), 1, "one refusal")
    assert_equal(f[0].field_path, "grant")
    assert_true(f[0].reason.find("write a uses line on the principal instead") >= 0, f[0].reason)
    assert_equal(len(_derived_findings(_limits(ProviderShape.aws(), String(_GRANT)))), 0, "aws labels its grants")
    print("  test_a_derived_shape_refuses_a_grant_resource: PASS")


def test_a_derived_shape_refuses_uses_on_a_run_as_workload() raises:
    """Catches: a `uses` line on a workload with `run_as` accepted on a
    DERIVED shape (its node belongs to the workload, its member is the
    account), including a line on a cell resource, which has no target."""
    var f = _derived_findings(_limits(ProviderShape.gcp(), String(_RUN_AS_USES)))
    assert_equal(len(f), 1, "one refusal")
    assert_equal(f[0].field_path, "uses")
    assert_true(f[0].reason.find('write the uses line on "runner" itself') >= 0, f[0].reason)
    var c = _derived_findings(_limits(ProviderShape.gcp(), String(_RUN_AS_CELL_USES)))
    assert_equal(len(c), 1, "a cell uses line on a run_as workload: one refusal too")
    assert_equal(c[0].field_path, "uses")
    assert_equal(len(_derived_findings(_limits(ProviderShape.gcp(), String(_RUN_AS)))), 0, "run_as alone is fine")
    assert_equal(len(_derived_findings(_limits(ProviderShape.gcp(), String(_OWN_USES)))), 0, "own identity is fine")
    assert_equal(len(_derived_findings(_limits(ProviderShape.aws(), String(_RUN_AS_USES)))), 0, "aws")
    print("  test_a_derived_shape_refuses_uses_on_a_run_as_workload: PASS")


def main() raises:
    print("test_cloud_derived_attribution")
    test_a_cell_member_on_an_owned_target_is_its_uses_node()
    test_everyone_on_the_public_role_is_the_public_node()
    test_a_cell_scope_binding_hashes_the_cell_path()
    test_a_composite_identity_keeps_its_path_and_owner()
    test_a_composite_target_hashes_its_component_path()
    test_an_identity_of_another_cell_is_never_this_cells()
    test_an_identity_of_another_machine_is_never_this_cells()
    test_what_the_table_does_not_map_is_not_ours()
    test_a_member_or_target_kci_does_not_own_is_not_ours()
    test_the_role_table_must_be_injective()
    test_a_derived_shape_refuses_a_grant_resource()
    test_a_derived_shape_refuses_uses_on_a_run_as_workload()
    print("ALL kci_cloud DERIVED ATTRIBUTION TESTS PASSED")
