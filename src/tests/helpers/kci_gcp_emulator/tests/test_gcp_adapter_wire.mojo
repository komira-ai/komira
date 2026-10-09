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
#   * removing kci's membership (roles_off, a destroy) keeps every other
#     member of the same role, on an account's policy and the project's;
#   * a job's long-running operation not yet done is read again after each
#     wait of the bounded backoff until it is, and one that never ends
#     stops the apply after twelve reads;
#   * a job's adoption and release keep the fields kci does not model;
#   * another cell's account holding a mapped role on the project is never
#     listed, nor reported leftover;
#   * whoami names the emulator's principal;
#   * gcp lowers as the gcp fake does, byte for byte.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from kci_cloud import (
    Catalog,
    create_labels,
    description_lines,
    destroy_resources,
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
from kci_cloud_gcp import (
    ROLE_ACCOUNT_VIEWER,
    ROLE_LOG_WRITER,
    account_email,
    account_member,
    account_resource,
    derived_name,
    job_resource,
)
from kci_reconciler import CellScope, Creds, InMemoryStateStore, OwnerStamp, Provenance, RETAIN_DELETE
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


def _unmodelled_kept(emu: ArcPointer[GcpEmulator], name: String, when: String) raises:
    """The fields kci does not model, planted on the job, still stand."""
    var j = emu[].job_index(name)
    var t = emu[].jobs[j].body.get("template")
    assert_equal(t.get("parallelism").text, "3", String("the parallelism ") + when)
    var c = t.get("template").get("containers").element_at(0)
    assert_equal(c.get("workingDir").as_string(), "/srv", String("the working directory ") + when)
    assert_equal(c.get("image").as_string(), "sha256:a1")


def test_a_job_adoption_and_release_keep_a_human_label() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var name = job_resource(String(_PROJECT), String("europe-west1"), String("jobadopt"))
    var body = parse_object(
        String('{"name":"') + name + String('","labels":{"owner-team":"data"},"template":{"parallelism":3,"template":{"containers":[')
        + String('{"image":"sha256:a1","workingDir":"/srv","resources":{"limits":{"cpu":"1000m","memory":"512Mi"}}}],')
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
    _unmodelled_kept(emu, name, "after the adoption's update")
    # Its resource leaves the list: the job is released, not deleted.
    _apply(target, _ctx(), String('{"resource":[]}'))
    j = emu[].job_index(name)
    assert_true(j >= 0, "a release never deletes")
    var left = emu[].jobs[j].body.get("labels")
    assert_equal(left.num_members(), 1, left.serialize())
    assert_equal(left.get("owner-team").as_string(), "data")
    _unmodelled_kept(emu, name, "after the release")


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
    # An account of ANOTHER cell of the same machine, holding the log writer
    # role on the project: never this cell's, so never listed.
    var ghost_email = account_email(String("ghost-elsewhere"), String(_PROJECT))
    var ghost = description_lines(
        create_labels(OwnerStamp(String("shop"), String("staging-elsewhere"), String("ghost"), String("identity")), RETAIN_DELETE)
    )
    emu[].accounts.append(EmuAccount(String("ghost-elsewhere"), ghost_email, String(""), ghost, String("77"), True))
    var p = emu[].policy_of(String("projects/") + _PROJECT)
    emu[].policies[p].add(account_member(ghost_email), String(ROLE_LOG_WRITER))
    before = emu[].live_count()
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
    assert_true(left.find(",ghost/") < 0, String("another cell's binding is not this cell's: ") + left)
    var owned = target.list_owned(Creds.none(), _ctx().scope)
    for i in range(len(owned)):
        assert_true(owned[i].id.find(ghost_email) < 0, String("listed as this cell's: ") + owned[i].owner_node)
    assert_equal(_members(emu, String("projects/") + _PROJECT, String(ROLE_LOG_WRITER)).find(ghost_email) >= 0, True)


def _graph(uses: Bool) -> String:
    var runner = String('{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"peer"},"access":"DESCRIBE"}]}') if uses else String('{"id":"runner","serviceAccount":{}}')
    return String('{"resource":[{"id":"peer","serviceAccount":{}},') + runner + String("]}")


def test_a_removal_keeps_the_role_s_other_members() raises:
    # A human and an account of another project hold the SAME roles kci's
    # bindings hold, on peer's policy and on the project's. Removing kci's
    # membership (roles_off, then a destroy) takes kci's member out of the
    # role and leaves every other member in it.
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var target = EmulatedGcpCloud(emu)
    var reg = Clouds(Catalog.v1())
    reg.add(describe(target))
    var store = InMemoryStateStore()
    var on = apply_resources(reg, target, _ctx(), _list(_graph(True)), Creds.none(), store)
    assert_true(not on.error, on.error.value() if on.error else String(""))
    var human = String("user:human@demo-project.example")
    var foreign = account_member(account_email(String("someone-else"), String("other-project")))
    var peer = account_resource(String(_PROJECT), _email(String("peer/identity")))
    var project = String("projects/") + _PROJECT
    var planted = List[String]()
    planted.append(human)
    planted.append(foreign)
    for i in range(len(planted)):
        var pp = emu[].policy_of(peer)
        emu[].policies[pp].add(planted[i], String(ROLE_ACCOUNT_VIEWER))
        var pj = emu[].policy_of(project)
        emu[].policies[pj].add(planted[i], String(ROLE_LOG_WRITER))
    var off = apply_resources(reg, target, _ctx(), _list(_graph(False)), Creds.none(), store)
    assert_true(not off.error, off.error.value() if off.error else String(""))
    var viewers = _members(emu, peer, String(ROLE_ACCOUNT_VIEWER))
    assert_true(viewers.find(account_member(_email(String("runner/identity")))) < 0, String("runner's binding is gone: ") + viewers)
    assert_true(viewers.find(human) >= 0, String("the human viewer stays: ") + viewers)
    assert_true(viewers.find(foreign) >= 0, String("the foreign viewer stays: ") + viewers)
    _ = destroy_resources(reg, target, _ctx(), _list(_graph(False)), Creds.none(), store)
    var writers = _members(emu, project, String(ROLE_LOG_WRITER))
    assert_true(writers.find(account_member(_email(String("peer/identity")))) < 0, String("kci's writers are gone: ") + writers)
    assert_true(writers.find(human) >= 0, String("the human writer stays: ") + writers)
    assert_true(writers.find(foreign) >= 0, String("the foreign writer stays: ") + writers)


def test_an_operation_not_yet_done_is_polled_until_it_is() raises:
    # Every job operation is done only at its third read: the create is
    # read three times, waiting 500, 1000 and 2000 ms (never slept: the
    # target's sleeper records).
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    emu[].op_polls = 3
    var target = EmulatedGcpCloud(emu)
    _apply(target, _ctx(), _base())
    assert_equal(emu[].op_reads, 3)
    var waits = target.sleeps()
    assert_equal(len(waits), 3)
    assert_equal(waits[0], 500)
    assert_equal(waits[1], 1000)
    assert_equal(waits[2], 2000)


def test_an_operation_that_never_ends_fails_the_apply() raises:
    # An operation still not done after the last read stops the apply: the
    # job the call already made does not pass for one that settled.
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    emu[].op_polls = 1000
    var target = EmulatedGcpCloud(emu)
    var why = String("(it applied)")
    try:
        _apply(target, _ctx(), _base())
    except e:
        why = String(e)
    assert_true(why.find("did not finish after 12 reads of its operation") >= 0, why)
    assert_equal(emu[].op_reads, 12)
    assert_equal(len(target.sleeps()), 12)


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
    print("test_a_removal_keeps_the_role_s_other_members")
    test_a_removal_keeps_the_role_s_other_members()
    print("test_an_operation_not_yet_done_is_polled_until_it_is")
    test_an_operation_not_yet_done_is_polled_until_it_is()
    print("test_an_operation_that_never_ends_fails_the_apply")
    test_an_operation_that_never_ends_fails_the_apply()
    print("test_whoami_names_the_token_s_principal")
    test_whoami_names_the_token_s_principal()
    print("test_gcp_lowers_as_the_gcp_fake")
    test_gcp_lowers_as_the_gcp_fake()
    print("OK")
