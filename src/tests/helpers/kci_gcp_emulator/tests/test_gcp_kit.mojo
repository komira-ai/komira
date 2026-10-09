# =============================================================================
# kci_gcp_emulator/tests/test_gcp_kit.mojo
# =============================================================================
#
# THE WHOLE KIT ON THE EMULATOR (docs/design/deploy_step.md, row G4's
# acceptance): kci_cloud's `run_conformance`, every step from the dry run to
# born stamped (15), over kci_cloud_gcp's adapter on the stateful emulator.
# Each step drives the adapter's real wire code (the generated IAM, Cloud
# Resource Manager and Cloud Run clients, the hand-written
# PatchServiceAccount), and the kit's hooks read and change the emulator's
# state, not the adapter's.
#
# The graph is G4's: accounts `peer` and `runner`, `runner` with
# `uses peer DESCRIBE` (a binding on peer's policy); a job `nightly` with
# its own identity, whose environment reads `peer`'s NAME (the value
# reference step 9 needs). Every resource that holds its own identity also
# gets the implicit `cell LOGS WRITE` edge, a binding on the project's
# policy. `changed` changes nightly's command; `roles_off` drops runner's
# `uses` line (step 8 deletes that binding); `tamper_node` is nightly's run.
# Step 13 adopts a copy of `peer`, a service account, so a description
# carrier: read_existing, the adoption mark in the description, an update
# that keeps it, and a release that leaves the description empty. Step 14
# plants on peer's policy and on the project's. Step 15 fails, after it
# lands, the create of every node in turn: the three accounts, the job,
# runner's binding on peer and each cell LOGS binding.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from kci_cloud import Catalog, CellContext, Clouds, Setting, describe, run_conformance
from kci_reconciler import CellScope, Provenance
from kci_resource_proto.resource import Resource, ResourceList
from komira_proto_codec import decode_json

from kci_gcp_emulator import EmulatedGcpCloud, GcpEmulator


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    var settings = List[Setting]()
    settings.append(Setting(String("project"), String("demo-project")))
    settings.append(Setting(String("region"), String("europe-west1")))
    return CellContext(
        CellScope(String("shop"), String("staging"), Provenance(String("run-1"), String("rev-1"))), settings^
    )


def _graph(command: String, uses: Bool) -> String:
    var runner_uses = String('"uses":[{"target":{"resource":"peer"},"access":"DESCRIBE"}]') if uses else String('"uses":[]')
    return (
        String('{"resource":[')
        + String('{"id":"peer","serviceAccount":{}},')
        + String('{"id":"runner","serviceAccount":{},') + runner_uses + String('},')
        + String('{"id":"nightly","containerJob":{"image":{"digest":"sha256:a1"},"command":') + command
        + String(',"env":{"PEER":{"ref":{"resource":"peer","standard":"NAME"}}}}}')
        + String("]}")
    )


def test_the_gcp_adapter_passes_the_kit_on_the_emulator() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var target = EmulatedGcpCloud(emu)
    var reg = Clouds(Catalog.v1())
    reg.add(describe(target))
    run_conformance(
        reg,
        target,
        _ctx(),
        _list(_graph(String('["run"]'), True)),
        _list(_graph(String('["run","--again"]'), True)),
        _list(_graph(String('["run","--again"]'), False)),
        String("nightly/run"),
    )
    # The kit ran on the wire: every create, patch, delete and policy write
    # was a request the emulator served.
    assert_true(emu[].mutations > 50, String("only ") + String(emu[].mutations) + " mutations were served")
    assert_true(emu[].requests > emu[].mutations, "reads were served too")


def main() raises:
    print("test_the_gcp_adapter_passes_the_kit_on_the_emulator")
    test_the_gcp_adapter_passes_the_kit_on_the_emulator()
    print("OK")
