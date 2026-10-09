# =============================================================================
# kci_cloud_gcp/tests/test_gcp_adapter_rules.mojo
# =============================================================================
#
# What GcpCloud answers without a call to the cloud (no connector is ever
# dialed here):
#   * coverage: service_account, container_job and grant are implemented,
#     every other catalog type is declared absent once, of the kind its
#     portability allows (kci_cloud's `artifact_problems` is empty);
#   * configure: project and region are required, any other key is a
#     finding, and so is a bootstrap registry name over 63 bytes;
#   * check: a service account whose description lines would pass 256 bytes
#     is refused at validate, counting the run-id line of a create and the
#     mark line of an adoption; a short one is not; a grant resource is
#     refused (the derived stamp's refusal, shared with the gcp fake);
#   * image_registry is pure and differs for two cells; registry_login
#     presents the access-token user;
#   * trust_check refuses every cell, saying trust checking is not
#     configured yet (its inputs are an open design question).
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_cloud import (
    Catalog,
    CellContext,
    Feed,
    Firing,
    Setting,
    artifact_problems,
    describe,
)
from kci_reconciler import CellScope, Creds, Provenance
from kci_resource_proto.resource import Resource
from komira_gcp_core import StaticTokenSource
from komira_http_core.transport.scripted import ScriptedConnector
from komira_proto_codec import decode_json

from kci_cloud_gcp import GcpCloud, GcpConnectors


comptime Cloud = GcpCloud[ScriptedConnector, StaticTokenSource]


def _cloud() raises -> Cloud:
    return Cloud(
        GcpConnectors[ScriptedConnector](
            ScriptedConnector(), ScriptedConnector(), ScriptedConnector(), ScriptedConnector(), ScriptedConnector()
        ),
        StaticTokenSource(String("unit-token")),
    )


def _settings(project: String = String("demo-project"), region: String = String("europe-west1")) -> List[Setting]:
    var s = List[Setting]()
    if project.byte_length() > 0:
        s.append(Setting(String("project"), project))
    if region.byte_length() > 0:
        s.append(Setting(String("region"), region))
    return s^


def _ctx(machine: String, cell: String, var settings: List[Setting], run: Optional[String] = None) -> CellContext:
    var scope = CellScope(machine, cell, Provenance(String("run-1"), String("rev-1")), validation_run_id=run)
    return CellContext(scope^, settings^)


def _rep(c: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += c
    return out^


def _check(mut cloud: Cloud, json: String) raises -> String:
    var r = decode_json[Resource](json)
    var findings = cloud.check(r, List[Feed](), List[Firing]())
    var out = String("")
    for i in range(len(findings)):
        out += findings[i].reason + String("\n")
    return out^


def test_coverage_names_every_type_once() raises:
    var cloud = _cloud()
    var problems = artifact_problems(Catalog.v1(), describe(cloud))
    assert_equal(len(problems), 0, problems[0] if len(problems) > 0 else String(""))
    assert_equal(len(cloud.implemented()), 3)
    assert_true(not cloud.complete())


def test_configure() raises:
    var cloud = _cloud()
    assert_equal(len(cloud.configure(_ctx(String("shop"), String("staging"), _settings()))), 0)
    var missing = cloud.configure(_ctx(String("shop"), String("staging"), _settings(String(""), String(""))))
    assert_equal(len(missing), 2)
    assert_equal(missing[0].field_path, "settings.project")
    assert_equal(missing[1].field_path, "settings.region")
    var extra = _settings()
    extra.append(Setting(String("zone"), String("b")))
    var unknown = cloud.configure(_ctx(String("shop"), String("staging"), extra^))
    assert_equal(len(unknown), 1)
    assert_equal(unknown[0].field_path, "settings.zone")
    var m = _rep("m", 30)
    var c = _rep("c", 30)
    var too_long = cloud.configure(_ctx(m, c, _settings()))
    assert_equal(len(too_long), 1)
    assert_true(too_long[0].reason.find("GCP allows 63") >= 0, too_long[0].reason)


def test_a_description_over_256_bytes_is_refused_at_validate() raises:
    var cloud = _cloud()
    # 60-byte machine, cell and resource id: the identity line alone is
    # 13 + 60 + 1 + 60 + 1 + 60 + 9 = 204 bytes, the retention line 21 more.
    var m = _rep("m", 60)
    var c = _rep("c", 60)
    var id = _rep("a", 60)
    _ = cloud.configure(_ctx(m, c, _settings()))
    var account = String('{"id":"') + id + String('","serviceAccount":{}}')
    assert_equal(_check(cloud, account), "", "225 bytes with no run id")
    # A 40-byte run id adds a 52-byte line: 277 bytes.
    _ = cloud.configure(_ctx(m, c, _settings(), _rep("r", 40)))
    var refused = _check(cloud, account)
    assert_true(refused.find("277-byte description; GCP allows 256") >= 0, refused)
    # An adopted account writes the mark line (16 bytes) instead: 242 bytes.
    var adopted = String('{"id":"') + id + String('","serviceAccount":{},"physicalName":"kitadopt","adopt":"ADOPT"}')
    assert_equal(_check(cloud, adopted), "", "an adoption counts the mark line, not the run id")
    # A job's own identity is an account too.
    var job = String('{"id":"') + id + String('","containerJob":{"image":{"digest":"sha256:a1"}}}')
    assert_true(_check(cloud, job).find("277-byte description") >= 0)


def test_a_grant_resource_is_refused() raises:
    var cloud = _cloud()
    _ = cloud.configure(_ctx(String("shop"), String("staging"), _settings()))
    var text = _check(cloud, String('{"id":"see","grant":{"principal":{"resource":"runner"},"target":{"resource":"peer"},"access":"DESCRIBE"}}'))
    assert_true(text.find("cannot be owned by a grant resource") >= 0, text)


def test_the_image_registry_is_pure_and_per_cell() raises:
    var cloud = _cloud()
    var a = cloud.image_registry(_ctx(String("shop"), String("staging"), _settings()))
    assert_equal(a, "europe-west1-docker.pkg.dev/demo-project/shop-staging-images")
    var b = cloud.image_registry(_ctx(String("shop"), String("prod"), _settings()))
    assert_true(a != b, "two cells never share a registry")
    var login = cloud.registry_login(Creds.none())
    assert_equal(login.user, "oauth2accesstoken")
    assert_equal(login.secret, "unit-token")


def test_trust_check_refuses_until_it_is_configured() raises:
    var cloud = _cloud()
    _ = cloud.configure(_ctx(String("shop"), String("staging"), _settings()))
    var f = cloud.trust_check(Creds.none(), CellScope(String("shop"), String("staging")))
    assert_equal(len(f), 1)
    assert_true(f[0].reason.find("trust checking is not configured yet") >= 0, f[0].reason)
    assert_true(f[0].reason.find("every cell is refused") >= 0, f[0].reason)


def main() raises:
    print("test_coverage_names_every_type_once")
    test_coverage_names_every_type_once()
    print("test_configure")
    test_configure()
    print("test_a_description_over_256_bytes_is_refused_at_validate")
    test_a_description_over_256_bytes_is_refused_at_validate()
    print("test_a_grant_resource_is_refused")
    test_a_grant_resource_is_refused()
    print("test_the_image_registry_is_pure_and_per_cell")
    test_the_image_registry_is_pure_and_per_cell()
    print("test_trust_check_refuses_until_it_is_configured")
    test_trust_check_refuses_until_it_is_configured()
    print("OK")
