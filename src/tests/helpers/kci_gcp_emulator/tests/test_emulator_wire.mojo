# =============================================================================
# kci_gcp_emulator/tests/test_emulator_wire.mojo
# =============================================================================
#
# The emulator answered through komira's generated clients and
# komira_gcp_core's token-information read, over `EmulatorConnector` (no
# socket, no DNS), so the kit's runs stand on routes that answer as GCP's
# do. Each case says what it pins:
#   * IAM accounts: create, get, delete; a list follows nextPageToken (the
#     emulator answers at most two a page); a missing account is NOT_FOUND,
#     an existing id ALREADY_EXISTS, an id outside IAM's rule
#     INVALID_ARGUMENT, a description over 256 bytes INVALID_ARGUMENT, each
#     read back from the client's error by status code;
#   * a policy read-modify-write with the etag it read succeeds, and a write
#     with a stale etag is ABORTED;
#   * the project's policy starts with its human owner;
#   * Cloud Run jobs: create, get, list, delete; a label outside GCP's rule
#     is INVALID_ARGUMENT;
#   * a request without the emulator's token is UNAUTHENTICATED;
#   * the token-information endpoint names the token's principal and
#     refuses another token with `invalid_token`.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_cloudresourcemanager.iam_policy import GetIamPolicyRequest as CrmGetPolicyRequest
from komira_gcp_cloudresourcemanager.projects import ProjectsClient
from komira_gcp_core import (
    CODE_ABORTED,
    CODE_ALREADY_EXISTS,
    CODE_INVALID_ARGUMENT,
    CODE_NOT_FOUND,
    CODE_UNAUTHENTICATED,
    GcpConnectorTransport,
    StaticTokenSource,
    fetch_token_info,
    gcp_status_error_code,
)
from komira_gcp_iam.iam import (
    CreateServiceAccountRequest,
    DeleteServiceAccountRequest,
    GetServiceAccountRequest,
    IAMClient,
    ListServiceAccountsRequest,
)
from komira_gcp_iam.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_iam.policy import Binding, Policy
from komira_gcp_run.job import CreateJobRequest, DeleteJobRequest, GetJobRequest, Job, JobsClient, ListJobsRequest
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_proto_codec import decode_json

from kci_gcp_emulator import (
    CRM_HOST,
    EMU_DEPLOYER,
    EMU_TOKEN,
    IAM_HOST,
    OWNER_MEMBER,
    RUN_HOST,
    TOKENINFO_HOST,
    EmulatorConnector,
    GcpEmulator,
)


comptime _RT = BlockingRuntime[NoopSink]
comptime Iam = IAMClient[EmulatorConnector, StaticTokenSource]


def _rt() raises -> _RT:
    return _RT.new(NoopSink(_placeholder=UInt8(0)))


def _iam(emu: ArcPointer[GcpEmulator], token: String = String(EMU_TOKEN)) raises -> Iam:
    var c = Iam(HttpClient[EmulatorConnector].with_defaults(EmulatorConnector(emu)), StaticTokenSource(token))
    c.set_rest_endpoint(String(IAM_HOST), UInt16(0), True)
    return c^


def _create(mut c: Iam, id: String, description: String = String("")) raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.create_service_account[_RT](
        decode_json[CreateServiceAccountRequest](
            String('{"name":"projects/demo-project","accountId":"') + id
            + String('","serviceAccount":{"displayName":"d","description":"') + description + String('"}}')
        ),
        reactor,
    )


def _code(e: String, verb: String, rpc: String) -> Int:
    return gcp_status_error_code(verb, rpc, e)


def _email(id: String) -> String:
    return id + String("@") + String("demo-project.iam.gserviceaccount.com")


def test_accounts() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var c = _iam(emu)
    _create(c, String("alpha-1"))
    _create(c, String("bravo-2"))
    _create(c, String("charlie-3"))
    var rt = _rt()
    ref reactor = rt.reactor()
    var first = c.list_service_accounts[_RT](ListServiceAccountsRequest(String("projects/demo-project"), Int32(100), String("")), reactor)
    assert_equal(len(first.accounts), 2)
    assert_true(first.next_page_token.byte_length() > 0, "a list follows nextPageToken")
    var second = c.list_service_accounts[_RT](
        ListServiceAccountsRequest(String("projects/demo-project"), Int32(100), first.next_page_token.copy()), reactor
    )
    assert_equal(len(second.accounts), 1)
    assert_equal(second.next_page_token, "")
    var name = String("projects/demo-project/serviceAccounts/") + _email(String("bravo-2"))
    var got = c.get_service_account[_RT](GetServiceAccountRequest(name.copy()), reactor)
    assert_equal(got.email, _email(String("bravo-2")))
    _ = c.delete_service_account[_RT](DeleteServiceAccountRequest(name.copy()), reactor)
    var code = -1
    try:
        _ = c.get_service_account[_RT](GetServiceAccountRequest(name.copy()), reactor)
    except e:
        code = _code(String(e), String("GET"), String("GetServiceAccount"))
    assert_equal(code, CODE_NOT_FOUND)


def test_account_refusals() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var c = _iam(emu)
    _create(c, String("alpha-1"))
    var dup = -1
    try:
        _create(c, String("alpha-1"))
    except e:
        dup = _code(String(e), String("POST"), String("CreateServiceAccount"))
    assert_equal(dup, CODE_ALREADY_EXISTS)
    var bad = -1
    try:
        _create(c, String("Nope"))
    except e:
        bad = _code(String(e), String("POST"), String("CreateServiceAccount"))
    assert_equal(bad, CODE_INVALID_ARGUMENT)
    var long_text = String("")
    for _ in range(257):
        long_text += String("x")
    var too_long = -1
    try:
        _create(c, String("delta-4"), long_text)
    except e:
        too_long = _code(String(e), String("POST"), String("CreateServiceAccount"))
    assert_equal(too_long, CODE_INVALID_ARGUMENT)
    var anon = _iam(emu, String("not-the-token"))
    var unauth = -1
    try:
        _create(anon, String("echo-55"))
    except e:
        unauth = _code(String(e), String("POST"), String("CreateServiceAccount"))
    assert_equal(unauth, CODE_UNAUTHENTICATED)


def test_a_stale_etag_is_aborted() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var c = _iam(emu)
    _create(c, String("alpha-1"))
    var resource = String("projects/demo-project/serviceAccounts/") + _email(String("alpha-1"))
    var rt = _rt()
    ref reactor = rt.reactor()
    var read = c.get_iam_policy[_RT](GetIamPolicyRequest(resource.copy(), None), reactor)
    var p = read.copy()
    var members = List[String]()
    members.append(String("serviceAccount:") + _email(String("alpha-1")))
    p.bindings.append(Binding(String("roles/iam.serviceAccountViewer"), members^, None))
    var written = c.set_iam_policy[_RT](SetIamPolicyRequest(resource.copy(), p.copy(), None), reactor)
    assert_equal(len(written.bindings), 1)
    assert_true(written.etag != read.etag, "a write changes the etag")
    var aborted = -1
    try:
        _ = c.set_iam_policy[_RT](SetIamPolicyRequest(resource.copy(), p^, None), reactor)
    except e:
        aborted = _code(String(e), String("POST"), String("SetIamPolicy"))
    assert_equal(aborted, CODE_ABORTED)


def test_the_project_policy_starts_with_its_owner() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var c = ProjectsClient[EmulatorConnector, StaticTokenSource](
        HttpClient[EmulatorConnector].with_defaults(EmulatorConnector(emu)), StaticTokenSource(String(EMU_TOKEN))
    )
    c.set_rest_endpoint(String(CRM_HOST), UInt16(0), True)
    var rt = _rt()
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](CrmGetPolicyRequest(String("projects/demo-project"), None), reactor)
    assert_equal(len(p.bindings), 1)
    assert_equal(p.bindings[0].role, "roles/owner")
    assert_equal(p.bindings[0].members[0], OWNER_MEMBER)


def test_jobs() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var c = JobsClient[EmulatorConnector, StaticTokenSource](
        HttpClient[EmulatorConnector].with_defaults(EmulatorConnector(emu)), StaticTokenSource(String(EMU_TOKEN))
    )
    c.set_rest_endpoint(String(RUN_HOST), UInt16(0), True)
    var rt = _rt()
    ref reactor = rt.reactor()
    var parent = String("projects/demo-project/locations/europe-west1")
    var job = decode_json[Job](String('{"labels":{"team":"data"},"template":{"template":{"containers":[{"image":"sha256:a1"}]}}}'))
    var op = c.create_job[_RT](CreateJobRequest(parent.copy(), job.copy(), String("nightly"), False), reactor)
    assert_true(op.done, "the emulator completes a change before it answers")
    var got = c.get_job[_RT](GetJobRequest(parent + String("/jobs/nightly")), reactor)
    assert_equal(got.name, parent + String("/jobs/nightly"))
    assert_equal(got.labels["team"], "data")
    var listed = c.list_jobs[_RT](ListJobsRequest(parent.copy(), Int32(100), String(""), False), reactor)
    assert_equal(len(listed.jobs), 1)
    var bad = decode_json[Job](String('{"labels":{"Team":"data"}}'))
    var refused = -1
    try:
        _ = c.create_job[_RT](CreateJobRequest(parent.copy(), bad^, String("other"), False), reactor)
    except e:
        refused = _code(String(e), String("POST"), String("CreateJob"))
    assert_equal(refused, CODE_INVALID_ARGUMENT)
    _ = c.delete_job[_RT](DeleteJobRequest(parent + String("/jobs/nightly"), False, String("")), reactor)
    var gone = -1
    try:
        _ = c.get_job[_RT](GetJobRequest(parent + String("/jobs/nightly")), reactor)
    except e:
        gone = _code(String(e), String("GET"), String("GetJob"))
    assert_equal(gone, CODE_NOT_FOUND)


def test_token_information() raises:
    var emu = ArcPointer[GcpEmulator](GcpEmulator())
    var t = GcpConnectorTransport[EmulatorConnector](HttpClientConfig.defaults(), EmulatorConnector(emu))
    var info = fetch_token_info(t, String(EMU_TOKEN), String("http"), String(TOKENINFO_HOST), 80)
    assert_equal(info.principal(), EMU_DEPLOYER)
    var refused = String("")
    try:
        _ = fetch_token_info(t, String("another"), String("http"), String(TOKENINFO_HOST), 80)
    except e:
        refused = String(e)
    assert_equal(refused, "token info refused: HTTP 400 (invalid_token)")


def main() raises:
    print("test_accounts")
    test_accounts()
    print("test_account_refusals")
    test_account_refusals()
    print("test_a_stale_etag_is_aborted")
    test_a_stale_etag_is_aborted()
    print("test_the_project_policy_starts_with_its_owner")
    test_the_project_policy_starts_with_its_owner()
    print("test_jobs")
    test_jobs()
    print("test_token_information")
    test_token_information()
    print("OK")
