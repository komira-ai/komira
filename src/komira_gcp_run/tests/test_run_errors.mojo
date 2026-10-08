# A non-2xx answer to each generated Cloud Run method raises through
# komira_gcp_core's `gcp_status_error`: the error names the verb, the RPC,
# the HTTP status and the canonical code of the `google.rpc.Status`
# envelope, and counts bytes. It never repeats a byte of the body: a Cloud
# Run error `message` names the project, the service, job or execution and
# the permission, and each test checks that the project is not repeated.
#
# One envelope per method, each an error a caller of that method meets,
# hand-written in the form the Cloud APIs error model documents. The
# connector is komira_http_core's ScriptedConnector; no socket is used.
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_run.execution import (
    CancelExecutionRequest,
    ExecutionsClient,
    GetExecutionRequest,
)
from komira_gcp_run.job import (
    CreateJobRequest,
    DeleteJobRequest,
    GetJobRequest,
    JobsClient,
    ListJobsRequest,
    RunJobRequest,
    UpdateJobRequest,
)
from komira_gcp_run.operations import (
    GetOperationRequest,
    OperationsClient,
    WaitOperationRequest,
)
from komira_gcp_run.revision import (
    DeleteRevisionRequest,
    ListRevisionsRequest,
    RevisionsClient,
)
from komira_gcp_run.service import (
    CreateServiceRequest,
    DeleteServiceRequest,
    GetServiceRequest,
    ListServicesRequest,
    ServicesClient,
    UpdateServiceRequest,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _envelope(code: Int, status: String, message: String) -> String:
    return (
        String('{"error":{"code":')
        + String(code)
        + ',"message":"'
        + message
        + '","status":"'
        + status
        + '"}}'
    )


def _http(status_line: String, body: String) -> HttpClient[ScriptedConnector]:
    var answer = _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    return HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(answer^))
    )


def _token() raises -> StaticTokenSource:
    return StaticTokenSource(String("test-access-token"))


def _services(
    status_line: String, body: String
) raises -> ServicesClient[ScriptedConnector, StaticTokenSource]:
    var c = ServicesClient[ScriptedConnector, StaticTokenSource](
        _http(status_line, body), _token()
    )
    c.set_rest_host(String("localhost"))
    return c^


def _revisions(
    status_line: String, body: String
) raises -> RevisionsClient[ScriptedConnector, StaticTokenSource]:
    var c = RevisionsClient[ScriptedConnector, StaticTokenSource](
        _http(status_line, body), _token()
    )
    c.set_rest_host(String("localhost"))
    return c^


def _jobs(
    status_line: String, body: String
) raises -> JobsClient[ScriptedConnector, StaticTokenSource]:
    var c = JobsClient[ScriptedConnector, StaticTokenSource](
        _http(status_line, body), _token()
    )
    c.set_rest_host(String("localhost"))
    return c^


def _executions(
    status_line: String, body: String
) raises -> ExecutionsClient[ScriptedConnector, StaticTokenSource]:
    var c = ExecutionsClient[ScriptedConnector, StaticTokenSource](
        _http(status_line, body), _token()
    )
    c.set_rest_host(String("localhost"))
    return c^


def _operations(
    status_line: String, body: String
) raises -> OperationsClient[ScriptedConnector, StaticTokenSource]:
    var c = OperationsClient[ScriptedConnector, StaticTokenSource](
        _http(status_line, body), _token()
    )
    c.set_rest_host(String("localhost"))
    return c^


def _expected(head: String, message: String, body: String) -> String:
    return (
        head
        + ", error.message "
        + String(message.byte_length())
        + " bytes, body "
        + String(body.byte_length())
        + " bytes"
    )


def test_create_service_already_exists() raises:
    var message = String("Resource 'web' already exists in project private-project.")
    var body = _envelope(409, "ALREADY_EXISTS", message)
    var c = _services("409 Conflict", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.create_service[_RT](
            decode_json[CreateServiceRequest](
                '{"parent":"projects/private-project/locations/us-central1",'
                + '"serviceId":"web","service":{}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("POST CreateService: HTTP 409, ALREADY_EXISTS (code 6)", message, body),
    )
    assert_false("private-project" in got)


def test_get_service_not_found() raises:
    var message = String(
        "Resource 'projects/private-project/locations/us-central1/services/web' was not found"
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _services("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_service[_RT](
            decode_json[GetServiceRequest](
                '{"name":"projects/private-project/locations/us-central1/services/web"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET GetService: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)


def test_list_services_permission_denied() raises:
    var message = String(
        "Permission 'run.services.list' denied on resource 'projects/private-project/"
        + "locations/-' (or resource may not exist)."
    )
    var body = _envelope(403, "PERMISSION_DENIED", message)
    var c = _services("403 Forbidden", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.list_services[_RT](
            decode_json[ListServicesRequest](
                '{"parent":"projects/private-project/locations/-"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET ListServices: HTTP 403, PERMISSION_DENIED (code 7)", message, body),
    )
    assert_false("private-project" in got)


def test_update_service_invalid_argument() raises:
    var message = String(
        "Violation in UpdateServiceRequest.service.template.containers: should contain "
        + "exactly one container for private-project"
    )
    var body = _envelope(400, "INVALID_ARGUMENT", message)
    var c = _services("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_service[_RT](
            decode_json[UpdateServiceRequest](
                '{"service":{"name":"projects/private-project/locations/us-central1/services/'
                + 'web"}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("PATCH UpdateService: HTTP 400, INVALID_ARGUMENT (code 3)", message, body),
    )
    assert_false("private-project" in got)


def test_delete_service_aborted() raises:
    var message = String("Etag stale does not match the current etag of private-project web.")
    var body = _envelope(409, "ABORTED", message)
    var c = _services("409 Conflict", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.delete_service[_RT](
            decode_json[DeleteServiceRequest](
                '{"name":"projects/private-project/locations/us-central1/services/web",'
                + '"etag":"stale"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("DELETE DeleteService: HTTP 409, ABORTED (code 10)", message, body),
    )
    assert_false("private-project" in got)


def test_list_revisions_not_found() raises:
    var message = String(
        "Resource 'projects/private-project/locations/us-central1/services/web' was not found"
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _revisions("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.list_revisions[_RT](
            decode_json[ListRevisionsRequest](
                '{"parent":"projects/private-project/locations/us-central1/services/web"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET ListRevisions: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)


def test_delete_revision_failed_precondition() raises:
    var message = String(
        "Revision web-00003-kxv of private-project is serving traffic and cannot be deleted."
    )
    var body = _envelope(400, "FAILED_PRECONDITION", message)
    var c = _revisions("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.delete_revision[_RT](
            decode_json[DeleteRevisionRequest](
                '{"name":"projects/private-project/locations/us-central1/services/web/'
                + 'revisions/web-00003-kxv"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected(
            "DELETE DeleteRevision: HTTP 400, FAILED_PRECONDITION (code 9)",
            message,
            body,
        ),
    )
    assert_false("private-project" in got)


def test_create_job_already_exists() raises:
    var message = String("Resource 'build' already exists in project private-project.")
    var body = _envelope(409, "ALREADY_EXISTS", message)
    var c = _jobs("409 Conflict", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.create_job[_RT](
            decode_json[CreateJobRequest](
                '{"parent":"projects/private-project/locations/us-central1","jobId":"build",'
                + '"job":{}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("POST CreateJob: HTTP 409, ALREADY_EXISTS (code 6)", message, body),
    )
    assert_false("private-project" in got)


def test_get_job_not_found() raises:
    var message = String(
        "Resource 'projects/private-project/locations/us-central1/jobs/build' was not found"
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _jobs("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_job[_RT](
            decode_json[GetJobRequest](
                '{"name":"projects/private-project/locations/us-central1/jobs/build"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET GetJob: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)


def test_list_jobs_unauthenticated() raises:
    var message = String("Request had invalid authentication credentials for private-project.")
    var body = _envelope(401, "UNAUTHENTICATED", message)
    var c = _jobs("401 Unauthorized", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.list_jobs[_RT](
            decode_json[ListJobsRequest](
                '{"parent":"projects/private-project/locations/us-central1"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET ListJobs: HTTP 401, UNAUTHENTICATED (code 16)", message, body),
    )
    assert_false("private-project" in got)


def test_update_job_invalid_argument() raises:
    var message = String(
        "Violation in UpdateJobRequest.job.template: required for private-project"
    )
    var body = _envelope(400, "INVALID_ARGUMENT", message)
    var c = _jobs("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_job[_RT](
            decode_json[UpdateJobRequest](
                '{"job":{"name":"projects/private-project/locations/us-central1/jobs/build"}}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("PATCH UpdateJob: HTTP 400, INVALID_ARGUMENT (code 3)", message, body),
    )
    assert_false("private-project" in got)


def test_delete_job_failed_precondition() raises:
    var message = String("Job build of private-project has running executions.")
    var body = _envelope(400, "FAILED_PRECONDITION", message)
    var c = _jobs("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.delete_job[_RT](
            decode_json[DeleteJobRequest](
                '{"name":"projects/private-project/locations/us-central1/jobs/build"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("DELETE DeleteJob: HTTP 400, FAILED_PRECONDITION (code 9)", message, body),
    )
    assert_false("private-project" in got)


def test_run_job_resource_exhausted() raises:
    var message = String("Quota exceeded for running executions in private-project.")
    var body = _envelope(429, "RESOURCE_EXHAUSTED", message)
    var c = _jobs("429 Too Many Requests", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.run_job[_RT](
            decode_json[RunJobRequest](
                '{"name":"projects/private-project/locations/us-central1/jobs/build"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("POST RunJob: HTTP 429, RESOURCE_EXHAUSTED (code 8)", message, body),
    )
    assert_false("private-project" in got)


def test_get_execution_not_found() raises:
    var message = String(
        "Resource 'projects/private-project/locations/us-central1/jobs/build/executions/"
        + "build-x7k2p' was not found"
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _executions("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_execution[_RT](
            decode_json[GetExecutionRequest](
                '{"name":"projects/private-project/locations/us-central1/jobs/build/'
                + 'executions/build-x7k2p"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET GetExecution: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)


def test_cancel_execution_failed_precondition() raises:
    var message = String("Execution build-x7k2p of private-project has already completed.")
    var body = _envelope(400, "FAILED_PRECONDITION", message)
    var c = _executions("400 Bad Request", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.cancel_execution[_RT](
            decode_json[CancelExecutionRequest](
                '{"name":"projects/private-project/locations/us-central1/jobs/build/'
                + 'executions/build-x7k2p"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected(
            "POST CancelExecution: HTTP 400, FAILED_PRECONDITION (code 9)",
            message,
            body,
        ),
    )
    assert_false("private-project" in got)


def test_get_operation_not_found() raises:
    var message = String(
        "Operation projects/private-project/locations/us-central1/operations/0f8e3a not "
        + "found."
    )
    var body = _envelope(404, "NOT_FOUND", message)
    var c = _operations("404 Not Found", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.get_operation[_RT](
            decode_json[GetOperationRequest](
                '{"name":"projects/private-project/locations/us-central1/operations/0f8e3a"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("GET GetOperation: HTTP 404, NOT_FOUND (code 5)", message, body),
    )
    assert_false("private-project" in got)


def test_wait_operation_unavailable() raises:
    var message = String("The service is currently unavailable for private-project.")
    var body = _envelope(503, "UNAVAILABLE", message)
    var c = _operations("503 Service Unavailable", body)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.wait_operation[_RT](
            decode_json[WaitOperationRequest](
                '{"name":"projects/private-project/locations/us-central1/operations/0f8e3a",'
                + '"timeout":"30s"}'
            ),
            reactor,
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        _expected("POST WaitOperation: HTTP 503, UNAVAILABLE (code 14)", message, body),
    )
    assert_false("private-project" in got)


def main() raises:
    test_create_service_already_exists()
    test_get_service_not_found()
    test_list_services_permission_denied()
    test_update_service_invalid_argument()
    test_delete_service_aborted()
    test_list_revisions_not_found()
    test_delete_revision_failed_precondition()
    test_create_job_already_exists()
    test_get_job_not_found()
    test_list_jobs_unauthenticated()
    test_update_job_invalid_argument()
    test_delete_job_failed_precondition()
    test_run_job_resource_exhausted()
    test_get_execution_not_found()
    test_cancel_execution_failed_precondition()
    test_get_operation_not_found()
    test_wait_operation_unavailable()
    print("OK")
