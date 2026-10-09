# =============================================================================
# kci_gcp_emulator/tests/test_gcp_adapter_wire.mojo
# =============================================================================
#
# What kci_cloud_gcp's adapter writes, read straight from the emulator's
# state (never through the adapter):
#   * an apply under a validation run: each account's description is the
#     three lines, in order, and its display name the node id; the job's
#     fields are where Cloud Run reads them (the environment carrying peer's
#     email, the identity it runs as, its labels with the run id); runner's
#     binding is on peer's policy with the viewer role, and each cell LOGS
#     binding on the project's with the log writer role, beside the owner;
#   * an adoption under a validation run writes the identity, the retention
#     mark and the adoption mark, and NO run-id line;
#   * a job's adoption keeps a label a human wrote, and its release drops
#     every kci label and keeps that one;
#   * whoami names the emulator's principal;
#   * gcp lowers as the gcp fake does, byte for byte.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from kci_cloud import (
    Catalog,
    CellContext,
    Clouds,
    ProviderShape,
    Setting,
    apply_resources,
    describe,
    lower_data,
    lowering_json,
    uses_role,
)
from kci_cloud_fake import FakeCloud
from kci_cloud_gcp import ROLE_ACCOUNT_VIEWER, ROLE_LOG_WRITER, account_email, account_member, derived_name, job_resource
from kci_reconciler import CellScope, Creds, InMemoryStateStore, Provenance
from kci_resource_proto.resource import Resource, ResourceList
from komira_json import JsonValue
from komira_proto_codec import decode_json

from kci_gcp_emulator import EMU_DEPLOYER, OWNER_MEMBER, EmuAccount, EmuJob, EmulatedGcpCloud, GcpEmulator
from kci_gcp_emulator.emu_http import parse_object


comptime _RUN = "kit-run-5e0b71"
comptime _PROJECT = "demo-project"


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx(run: Optional[String] = None) -> CellContext:
    var settings = List[Setting]()
    settings.append(Setting(String("project"), String(_PROJECT)))
    settings.append(Setting(String("region"), String("europe-west1")))
    return CellContext(
        CellScope(String("shop"), String("staging"), Provenance(String("run-1"), String("rev-1")), validation_run_id=run),
        settings^,
    )


def _base() -> String:
    return (
        String('{"resource":[{"id":"peer","serviceAccount":{}},')
        + String('{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"peer"},"access":"DESCRIBE"}]},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:a1"},"command":["run"],')
        + String('"env":{"PEER":{"ref":{"resource":"peer","standard":"NAME"}}}}}]}')
    )


def _email(node: String) -> String:
    return account_email(derived_name(String("shop"), String("staging"), node), String(_PROJECT))


def _account(emu: ArcPointer[GcpEmulator], email: String) raises -> EmuAccount:
    var i = emu[].account_index(email)
    if i < 0:
        raise Error(String("no account ") + email)
    return emu[].accounts[i].copy()


def _apply(mut target: EmulatedGcpCloud, ctx: CellContext, json: String) raises:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(target))
    var store = InMemoryStateStore()
    var out = apply_resources(reg, target, ctx, _list(json), Creds.none(), store)
    if out.error:
        raise Error(String("the apply stopped: ") + out.error.value())


def _members(emu: ArcPointer[GcpEmulator], resource: String, role: String) -> String:
    var p = emu[].policy_index(resource)
    if p < 0:
        return String("")
    var out = String("")
    for b in range(len(emu[].policies[p].bindings)):
        if emu[].policies[p].bindings[b].role != role:
            continue
        for m in range(len(emu[].policies[p].bindings[b].members)):
            if out.byte_length() > 0:
                out += String(",")
            out += emu[].policies[p].bindings[b].members[m]
    return out^


def test_an_apply_writes_what_g4_says() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var target = EmulatedGcpCloud(emu)
    _apply(target, _ctx(String(_RUN)), _base())
    var peer = _account(emu, _email(String("peer/identity")))
    assert_equal(
        peer.description,
        String("kci:v1 owner=shop/staging/peer/identity\nkci-retention=delete\nkci-run-id=") + _RUN,
    )
    assert_equal(peer.display_name, "peer/identity")
    var j = emu[].job_index(job_resource(String(_PROJECT), String("europe-west1"), derived_name(String("shop"), String("staging"), String("nightly/run"))))
    assert_true(j >= 0, "the job was created under its derived name")
    ref body = emu[].jobs[j].body
    var task = body.get("template").get("template")
    var c = task.get("containers").element_at(0)
    assert_equal(c.get("image").as_string(), "sha256:a1")
    assert_equal(c.get("command").element_at(0).as_string(), "run")
    var env = c.get("env").element_at(0)
    assert_equal(env.get("name").as_string(), "PEER")
    assert_equal(env.get("value").as_string(), _email(String("peer/identity")), "the reference was bound to peer's NAME")
    assert_equal(task.get("serviceAccount").as_string(), _email(String("nightly/identity")), "it runs as its own identity")
    assert_equal(task.get("timeout").as_string(), "600s")
    var labels = body.get("labels")
    assert_equal(labels.get("kci_resource").as_string(), "nightly")
    assert_equal(labels.get("kci_role").as_string(), "run")
    assert_equal(labels.get("kci-run-id").as_string(), _RUN)
    assert_equal(labels.get("kci-retention").as_string(), "delete")
    var peer_resource = String("projects/") + _PROJECT + String("/serviceAccounts/") + _email(String("peer/identity"))
    assert_equal(_members(emu, peer_resource, String(ROLE_ACCOUNT_VIEWER)), account_member(_email(String("runner/identity"))))
    var writers = _members(emu, String("projects/") + _PROJECT, String(ROLE_LOG_WRITER))
    assert_true(writers.find(account_member(_email(String("peer/identity")))) >= 0, writers)
    assert_true(writers.find(account_member(_email(String("runner/identity")))) >= 0, writers)
    assert_true(writers.find(account_member(_email(String("nightly/identity")))) >= 0, writers)
    assert_equal(_members(emu, String("projects/") + _PROJECT, String("roles/owner")), OWNER_MEMBER, "the owner is kept")


def test_an_adoption_writes_no_run_id() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var email = account_email(String("kitadopt"), String(_PROJECT))
    emu[].accounts.append(EmuAccount(String("kitadopt"), email, String("kitadopt/identity"), String(""), String("9")))
    var target = EmulatedGcpCloud(emu)
    _apply(
        target,
        _ctx(String(_RUN)),
        String('{"resource":[{"id":"kitadopt","serviceAccount":{},"physicalName":"kitadopt","adopt":"ADOPT"}]}'),
    )
    var a = _account(emu, email)
    assert_equal(
        a.description,
        String("kci:v1 owner=shop/staging/kitadopt/identity\nkci-retention=delete\nkci_adopted=true"),
        "an adoption writes the identity, the retention mark and the adoption mark, never a run id",
    )
    assert_equal(emu[].creates_of(email), 0, "adopted, not created")


def test_a_job_adoption_and_release_keep_a_human_label() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var name = job_resource(String(_PROJECT), String("europe-west1"), String("jobadopt"))
    var body = parse_object(
        String('{"name":"') + name + String('","labels":{"owner-team":"data"},"template":{"template":{"containers":[')
        + String('{"image":"sha256:a1","resources":{"limits":{"cpu":"1000m","memory":"512Mi"}}}],')
        + String('"maxRetries":0,"timeout":"600s"}}}')
    )
    emu[].jobs.append(EmuJob(name, body^))
    var target = EmulatedGcpCloud(emu)
    var adopting = String(
        '{"resource":[{"id":"jobadopt","containerJob":{"image":{"digest":"sha256:a1"}},"physicalName":"jobadopt","adopt":"ADOPT"}]}'
    )
    _apply(target, _ctx(), adopting)
    var j = emu[].job_index(name)
    var labels = emu[].jobs[j].body.get("labels")
    assert_equal(labels.get("kci_adopted").as_string(), "true")
    assert_equal(labels.get("kci_resource").as_string(), "jobadopt")
    assert_equal(labels.get("owner-team").as_string(), "data", "an adoption keeps the labels it was not handed")
    assert_false(labels.has("kci-run-id"))
    assert_equal(emu[].creates_of(name), 0, "adopted, not created")
    # Its resource leaves the list: the job is released, not deleted.
    _apply(target, _ctx(), String('{"resource":[]}'))
    j = emu[].job_index(name)
    assert_true(j >= 0, "a release never deletes")
    var left = emu[].jobs[j].body.get("labels")
    assert_equal(left.num_members(), 1, left.serialize())
    assert_equal(left.get("owner-team").as_string(), "data")


def test_a_dropped_resource_s_nodes_are_leftover() raises:
    # list_owned reads the project's policy too: the cell LOGS binding of a
    # resource the file no longer names is reported as leftover, beside its
    # account and its job, and nothing is deleted.
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var target = EmulatedGcpCloud(emu)
    _apply(target, _ctx(), _base())
    var before = emu[].live_count()
    var reg = Clouds(Catalog.v1())
    reg.add(describe(target))
    var store = InMemoryStateStore()
    var without = String('{"resource":[{"id":"peer","serviceAccount":{}},')
    without += String('{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"peer"},"access":"DESCRIBE"}]}]}')
    var out = apply_resources(reg, target, _ctx(), _list(without), Creds.none(), store)
    assert_true(not out.error, out.error.value() if out.error else String(""))
    var left = String(",")
    for i in range(len(out.leftover)):
        left += out.leftover[i] + String(",")
    assert_true(left.find(",nightly/run,") >= 0, left)
    assert_true(left.find(",nightly/identity,") >= 0, left)
    var binding = String("nightly/") + uses_role(String("nightly"), String("cell/LOGS"))
    assert_true(left.find(String(",") + binding + String(",")) >= 0, String("the project's binding: ") + left)
    assert_equal(emu[].live_count(), before, "a leftover is reported, never deleted")


def test_whoami_names_the_token_s_principal() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var target = EmulatedGcpCloud(emu)
    _ = target.configure(_ctx())
    var who = target.whoami(Creds.none())
    assert_equal(who.principal, EMU_DEPLOYER)
    assert_equal(who.account, String("projects/") + _PROJECT)


def test_gcp_lowers_as_the_gcp_fake() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var gcp = EmulatedGcpCloud(emu)
    var fake = FakeCloud(shape=ProviderShape.gcp())
    var resources = _list(_base())
    assert_equal(lowering_json(lower_data(gcp, resources)), lowering_json(lower_data(fake, resources)))


def main() raises:
    print("test_an_apply_writes_what_g4_says")
    test_an_apply_writes_what_g4_says()
    print("test_an_adoption_writes_no_run_id")
    test_an_adoption_writes_no_run_id()
    print("test_a_job_adoption_and_release_keep_a_human_label")
    test_a_job_adoption_and_release_keep_a_human_label()
    print("test_a_dropped_resource_s_nodes_are_leftover")
    test_a_dropped_resource_s_nodes_are_leftover()
    print("test_whoami_names_the_token_s_principal")
    test_whoami_names_the_token_s_principal()
    print("test_gcp_lowers_as_the_gcp_fake")
    test_gcp_lowers_as_the_gcp_fake()
    print("OK")
