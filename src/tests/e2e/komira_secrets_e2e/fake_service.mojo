# =============================================================================
# fake_service.mojo -- a stateful AWS Secrets Manager over awsJson 1.1
# =============================================================================
#
# `FakeSecretsManager` is a komira_http_server `RequestDispatcher`: each
# request the server parses is checked and answered as the service answers
# it, against the state in fake_store.mojo.
#
#   1. The signature (sigv4_check.mojo, independent of komira_aws_core),
#      over the request's own method, scoped to the fake's region and the
#      service signing name `secretsmanager`. A refused request is answered
#      with the service's error shape and never reaches the state.
#   2. The method (POST), the path (/) and the operation, from
#      `X-Amz-Target: secretsmanager.<Operation>`, with the awsJson 1.1
#      content type and a JSON object body.
#   3. A scripted fault armed for that operation, if one is: a 500 before the
#      state is touched, or the write applied and THEN a 500 (the answer is
#      lost on the way back, the case an idempotency token exists for).
#   4. The operation: CreateSecret, PutSecretValue, GetSecretValue,
#      DescribeSecret, DeleteSecret, RestoreSecret.
#
# ClientRequestToken: a write's token is the id of the version it makes. A
# write repeating a token the secret already has, with the same value, is
# answered as the first one was and changes nothing (`replayed_writes`
# counts it); with another value it is refused. The fake refuses a
# CreateSecret or PutSecretValue that carries no token: the generated client
# always fills one, so a request without one is a client defect here (the
# service itself accepts one; this fake is stricter). A CreateSecret with no
# SecretString makes no version and answers no VersionId, as the service
# does; a replay of its token is recognised from the token the secret keeps
# (`FakeSecret.create_token`).
#
# Error answers are HTTP 400 (500 for a scripted fault), content type
# `application/x-amz-json-1.1`, an `x-amzn-RequestId` header, and a body of
# `__type` and `Message`. As a worst-case service, a 4xx error body also
# repeats the request's SecretString when it had one (`SecretString`
# member): a client that put an error body into its error text would leak the
# value, and the custody checks look for exactly that. `error_bodies` keeps
# every error body sent, so a test can see that the leak was on the wire.
# A 5xx body never carries it: komira_http_server logs the body of every 5xx
# a handler returns (middleware/fault_report.mojo, `observe_error_response`),
# and its contract is that a handler's 5xx body holds no customer content.
#
# What the fake records: `wire` holds one `WireRecord` per request (the
# operation, its ClientRequestToken, the answer's status and code), and
# `log` one line per request (operation, status, code: by construction it
# has no field a value could be in). `server_log` holds, for every 5xx the
# fake returns, the exact line komira_http_server writes to stdout for it
# (`error_response_log_line`, the line `observe_error_response` emits), so a
# test can check the one server log line that carries a response body
# without capturing the process's stdout. The server's other log line, for a
# dispatcher that RAISES, is not mirrored: this fake answers every request
# it can parse and raises only on an internal defect.
#
# Threading: the server thread is the only one touching the fake while the
# duet runs (duet.mojo); the test reads it after the join.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.middleware import (
    error_response_log_line,
    trace_header_of,
)
from komira_json import JsonValue, parse_json_bytes

from .fake_store import (
    STAGE_CURRENT,
    SECONDS_PER_DAY,
    FakeSecret,
    SecretStore,
    SecretVersion,
)
from .sigv4_check import CannedCredential, SigV4Verdict, verify_sigv4

comptime AWS_JSON_11 = "application/x-amz-json-1.1"
comptime SECRETSMANAGER_SIGNING_NAME = "secretsmanager"
comptime _TARGET_PREFIX = "secretsmanager."

# A scripted fault's modes.
comptime FAULT_500_BEFORE_APPLY = 1
comptime FAULT_500_AFTER_APPLY = 2

comptime _HELD_NAME_MESSAGE = (
    "You can't create this secret because a secret with this name is already"
    " scheduled for deletion."
)
comptime _MARKED_MESSAGE = (
    "You can't perform this operation on the secret because it was marked"
    " for deletion."
)
comptime _NOT_FOUND_MESSAGE = "Secrets Manager can't find the specified secret."


struct WireRecord(Copyable, Movable):
    """One request as the fake saw it, and how it answered."""

    var operation: String
    # The body's ClientRequestToken, "" when it carried none.
    var token: String
    var status: Int
    # The error code answered, "" for a 200.
    var code: String

    def __init__(
        out self, var operation: String, var token: String, status: Int, var code: String
    ):
        self.operation = operation^
        self.token = token^
        self.status = status
        self.code = code^


struct ScriptedFault(Copyable, Movable):
    var operation: String
    var mode: Int
    var fired: Bool

    def __init__(out self, var operation: String, mode: Int):
        self.operation = operation^
        self.mode = mode
        self.fired = False


struct _Answer(Movable):
    var status: Int
    var code: String
    var body: String

    def __init__(out self, status: Int, var code: String, var body: String):
        self.status = status
        self.code = code^
        self.body = body^


def _ok(v: JsonValue) -> _Answer:
    return _Answer(200, String(""), v.serialize())


def _opt_string(j: JsonValue, key: String) raises -> Optional[String]:
    if not j.has(key):
        return Optional[String]()
    var v = j.get(key)
    if v.is_null():
        return Optional[String]()
    return Optional[String](v.as_string())


def _member(mut o: JsonValue, key: String, var v: String) raises:
    o.set_member(key, JsonValue.from_string(v^))


def _stages_json(stages: List[String]) raises -> JsonValue:
    var a = JsonValue.empty_array()
    for i in range(len(stages)):
        a.push(JsonValue.from_string(stages[i].copy()))
    return a^


def _error(status: Int, code: String, message: String) raises -> _Answer:
    var e = JsonValue.empty_object()
    _member(e, String("__type"), code.copy())
    _member(e, String("Message"), message.copy())
    return _Answer(status, code.copy(), e.serialize())


def _create_answer(
    arn: String, name: String, version_id: Optional[String]
) raises -> _Answer:
    """CreateSecret's answer; no VersionId when the create made no
    version."""
    var o = JsonValue.empty_object()
    _member(o, String("ARN"), arn.copy())
    _member(o, String("Name"), name.copy())
    if version_id:
        _member(o, String("VersionId"), version_id.value().copy())
    return _ok(o)


def _put_answer(s: FakeSecret, v: Int) raises -> _Answer:
    var o = JsonValue.empty_object()
    _member(o, String("ARN"), s.arn.copy())
    _member(o, String("Name"), s.name.copy())
    _member(o, String("VersionId"), s.versions[v].version_id.copy())
    o.set_member(String("VersionStages"), _stages_json(s.versions[v].stages))
    return _ok(o)


struct FakeSecretsManager(RequestDispatcher):
    var credentials: List[CannedCredential]
    var store: SecretStore
    var faults: List[ScriptedFault]
    var wire: List[WireRecord]
    var log: List[String]
    var server_log: List[String]
    var error_bodies: List[String]
    # Writes that changed the state, and writes answered from a token the
    # secret already had.
    var applied_writes: Int
    var replayed_writes: Int
    var _requests: Int

    def __init__(
        out self, var credentials: List[CannedCredential], var region: String
    ):
        self.credentials = credentials^
        # An account id of zeros: no account has it.
        self.store = SecretStore(region^, String("000000000000"))
        self.faults = List[ScriptedFault]()
        self.wire = List[WireRecord]()
        self.log = List[String]()
        self.server_log = List[String]()
        self.error_bodies = List[String]()
        self.applied_writes = 0
        self.replayed_writes = 0
        self._requests = 0

    def arm_fault(mut self, var operation: String, mode: Int):
        """The next `operation` request that passes the signature check is
        answered 500, before or after its write is applied (`mode`)."""
        self.faults.append(ScriptedFault(operation^, mode))

    def operations(self, operation: String) -> List[WireRecord]:
        """Every request of `operation`, in arrival order."""
        var out = List[WireRecord]()
        for i in range(len(self.wire)):
            if self.wire[i].operation == operation:
                out.append(self.wire[i].copy())
        return out^

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        return self.handle(req^)

    def handle(mut self, var req: HttpRequest) raises -> HttpResponse:
        """The answer to one request, recorded in `wire` and `log`."""
        self._requests += 1
        var target = req.headers.get(String("x-amz-target")).or_else(String(""))
        var operation = target.copy()
        if target.startswith(_TARGET_PREFIX):
            operation = String(target[byte = String(_TARGET_PREFIX).byte_length() : target.byte_length()])
        var body_json = JsonValue()
        var parsed = False
        try:
            body_json = parse_json_bytes(req.body)
            parsed = body_json.is_object()
        except:
            parsed = False
        var token = String("")
        var value = String("")
        if parsed:
            try:
                token = _opt_string(body_json, String("ClientRequestToken")).or_else(String(""))
                value = _opt_string(body_json, String("SecretString")).or_else(String(""))
            except:
                pass
        var answer = self._answer(req, operation, target, parsed, body_json)
        self.wire.append(WireRecord(operation.copy(), token^, answer.status, answer.code.copy()))
        self.log.append(
            String("secretsmanager ")
            + operation
            + " "
            + String(answer.status)
            + (String(" ") + answer.code if answer.code.byte_length() > 0 else String(""))
        )
        var body = answer.body.copy()
        if answer.status != 200:
            # The worst-case service: a 4xx repeats the request's value.
            if value.byte_length() > 0 and answer.status < 500:
                try:
                    var raw = List[UInt8]()
                    raw.extend(Span(answer.body.as_bytes()))
                    var e = parse_json_bytes(raw)
                    _member(e, String("SecretString"), value.copy())
                    body = e.serialize()
                except:
                    pass
            self.error_bodies.append(body.copy())
            if answer.status >= 500:
                # The line the server writes for this 5xx (dispatch.mojo
                # passes the same method, path and trace header; the
                # default config's trace project is empty).
                self.server_log.append(
                    error_response_log_line(
                        Int32(answer.status),
                        req.method.name(),
                        String(req.path),
                        body,
                        trace_header_of(req),
                        String(""),
                    )
                )
        var resp = HttpResponse(Int32(answer.status))
        resp.headers[String("content-type")] = String(AWS_JSON_11)
        resp.headers[String("x-amzn-requestid")] = (
            String("00000000-0000-4000-8000-") + String(100000000000 + self._requests)
        )
        resp.headers[String("content-length")] = String(body.byte_length())
        var bytes = List[UInt8]()
        bytes.extend(Span(body.as_bytes()))
        resp.body = bytes^
        return resp^

    def _answer(
        mut self,
        req: HttpRequest,
        operation: String,
        target: String,
        parsed: Bool,
        body: JsonValue,
    ) raises -> _Answer:
        var method_ok = req.method == HttpMethod.post()
        var verdict = verify_sigv4(
            req.method.name(),
            req.path,
            req.query_string,
            req.headers,
            Span(req.body),
            self.credentials,
            self.store.region,
            String(SECRETSMANAGER_SIGNING_NAME),
        )
        if not verdict.ok:
            return _error(400, verdict.code, verdict.message)
        if not method_ok or req.path != "/" or not target.startswith(_TARGET_PREFIX):
            return _error(400, String("UnknownOperationException"), String(""))
        var ct = req.headers.get(String("content-type")).or_else(String(""))
        if ct != AWS_JSON_11:
            return _error(
                400, String("SerializationException"), String("Expected the awsJson 1.1 content type.")
            )
        if not parsed:
            return _error(
                400, String("SerializationException"), String("The body is not a JSON object.")
            )
        var fault_mode = 0
        for i in range(len(self.faults)):
            if not self.faults[i].fired and self.faults[i].operation == operation:
                self.faults[i].fired = True
                fault_mode = self.faults[i].mode
                break
        if fault_mode == FAULT_500_BEFORE_APPLY:
            return _error(
                500, String("InternalServiceError"), String("An error occurred on the server side.")
            )
        var answer = self._operation(operation, body)
        if fault_mode == FAULT_500_AFTER_APPLY:
            return _error(
                500, String("InternalServiceError"), String("An error occurred on the server side.")
            )
        return answer^

    def _operation(mut self, operation: String, body: JsonValue) raises -> _Answer:
        try:
            if operation == "CreateSecret":
                return self._create_secret(body)
            if operation == "PutSecretValue":
                return self._put_secret_value(body)
            if operation == "GetSecretValue":
                return self._get_secret_value(body)
            if operation == "DescribeSecret":
                return self._describe_secret(body)
            if operation == "DeleteSecret":
                return self._delete_secret(body)
            if operation == "RestoreSecret":
                return self._restore_secret(body)
        except:
            # A member of the wrong JSON type; the message names the
            # komira_json accessor, never a value.
            return _error(400, String("SerializationException"), String("A member has the wrong type."))
        return _error(400, String("UnknownOperationException"), String(""))

    def _token(self, body: JsonValue) raises -> Optional[String]:
        var token = _opt_string(body, String("ClientRequestToken"))
        if token:
            var n = token.value().byte_length()
            if n < 32 or n > 64:
                return Optional[String]()
        return token^

    def _create_secret(mut self, body: JsonValue) raises -> _Answer:
        var name = _opt_string(body, String("Name"))
        if not name or name.value().byte_length() == 0:
            return _error(400, String("InvalidParameterException"), String("Name is required."))
        var token = self._token(body)
        if not token:
            return _error(
                400,
                String("InvalidParameterException"),
                String("ClientRequestToken must be 32 to 64 characters."),
            )
        var value = _opt_string(body, String("SecretString"))
        var at = self.store.find(name.value())
        if at >= 0:
            if self.store.secrets[at].is_scheduled_for_deletion():
                return _error(400, String("InvalidRequestException"), String(_HELD_NAME_MESSAGE))
            var v = self.store.secrets[at].version_index(token.value())
            if v >= 0:
                if not value or self.store.secrets[at].versions[v].value != value.value():
                    return _error(
                        400,
                        String("ResourceExistsException"),
                        String("You can't modify an existing version, you can only create a new version."),
                    )
                self.replayed_writes += 1
                return _create_answer(
                    self.store.secrets[at].arn,
                    self.store.secrets[at].name,
                    Optional[String](token.value()),
                )
            if (
                not value
                and len(self.store.secrets[at].versions) == 0
                and self.store.secrets[at].create_token == token.value()
            ):
                # A replay of a create that carried no value.
                self.replayed_writes += 1
                return _create_answer(
                    self.store.secrets[at].arn,
                    self.store.secrets[at].name,
                    Optional[String](),
                )
            return _error(
                400,
                String("ResourceExistsException"),
                String("The operation failed because the secret ") + name.value() + " already exists.",
            )
        var now = self.store.now()
        var arn = self.store.new_arn(name.value())
        var secret = FakeSecret(name.value(), arn.copy(), now, token.value())
        secret.description = _opt_string(body, String("Description")).or_else(String(""))
        var made = Optional[String]()
        if value:
            var stages = List[String]()
            stages.append(String(STAGE_CURRENT))
            secret.add_version(SecretVersion(token.value(), value.value(), now), stages)
            made = Optional[String](token.value())
        self.store.secrets.append(secret^)
        self.applied_writes += 1
        return _create_answer(arn, name.value(), made)

    def _live(mut self, body: JsonValue, mut index: Int) raises -> Optional[_Answer]:
        """The secret `SecretId` names, in `index`; or the refusal when there
        is none or it is scheduled for deletion."""
        var id = _opt_string(body, String("SecretId"))
        index = self.store.find(id.or_else(String("")))
        if index < 0:
            return Optional[_Answer](
                _error(400, String("ResourceNotFoundException"), String(_NOT_FOUND_MESSAGE))
            )
        if self.store.secrets[index].is_scheduled_for_deletion():
            return Optional[_Answer](
                _error(400, String("InvalidRequestException"), String(_MARKED_MESSAGE))
            )
        return Optional[_Answer]()

    def _put_secret_value(mut self, body: JsonValue) raises -> _Answer:
        var at = -1
        var refused = self._live(body, at)
        if refused:
            return refused.take()
        var token = self._token(body)
        if not token:
            return _error(
                400,
                String("InvalidParameterException"),
                String("ClientRequestToken must be 32 to 64 characters."),
            )
        var value = _opt_string(body, String("SecretString"))
        if not value:
            return _error(
                400, String("InvalidParameterException"), String("SecretString is required.")
            )
        var stages = List[String]()
        if body.has(String("VersionStages")):
            var a = body.get(String("VersionStages"))
            for i in range(a.array_len()):
                stages.append(a.element_at(i).as_string())
        else:
            stages.append(String(STAGE_CURRENT))
        var v = self.store.secrets[at].version_index(token.value())
        if v >= 0:
            if self.store.secrets[at].versions[v].value != value.value():
                return _error(
                    400,
                    String("ResourceExistsException"),
                    String("You can't modify an existing version, you can only create a new version."),
                )
            self.replayed_writes += 1
            return _put_answer(self.store.secrets[at], v)
        var now = self.store.now()
        self.store.secrets[at].add_version(
            SecretVersion(token.value(), value.value(), now), stages
        )
        self.applied_writes += 1
        return _put_answer(self.store.secrets[at], len(self.store.secrets[at].versions) - 1)

    def _get_secret_value(mut self, body: JsonValue) raises -> _Answer:
        var at = -1
        var refused = self._live(body, at)
        if refused:
            return refused.take()
        ref s = self.store.secrets[at]
        var version_id = _opt_string(body, String("VersionId"))
        var stage = _opt_string(body, String("VersionStage"))
        var v = -1
        if version_id:
            v = s.version_index(version_id.value())
            if v >= 0 and stage and not s.versions[v].has_stage(stage.value()):
                v = -1
        else:
            v = s.staged_index(stage.or_else(String(STAGE_CURRENT)))
        if v < 0:
            return _error(
                400,
                String("ResourceNotFoundException"),
                String("Secrets Manager can't find the specified secret value for the version or staging label."),
            )
        ref ver = s.versions[v]
        var o = JsonValue.empty_object()
        _member(o, String("ARN"), s.arn.copy())
        _member(o, String("Name"), s.name.copy())
        _member(o, String("VersionId"), ver.version_id.copy())
        _member(o, String("SecretString"), ver.value.copy())
        o.set_member(String("VersionStages"), _stages_json(ver.stages))
        o.set_member(String("CreatedDate"), JsonValue.from_f64(ver.created))
        return _ok(o)

    def _describe_secret(mut self, body: JsonValue) raises -> _Answer:
        var at = self.store.find(_opt_string(body, String("SecretId")).or_else(String("")))
        if at < 0:
            return _error(400, String("ResourceNotFoundException"), String(_NOT_FOUND_MESSAGE))
        ref s = self.store.secrets[at]
        var o = JsonValue.empty_object()
        _member(o, String("ARN"), s.arn.copy())
        _member(o, String("Name"), s.name.copy())
        if s.description.byte_length() > 0:
            _member(o, String("Description"), s.description.copy())
        o.set_member(String("CreatedDate"), JsonValue.from_f64(s.created))
        o.set_member(String("LastChangedDate"), JsonValue.from_f64(s.last_changed))
        if s.deletion_date:
            o.set_member(String("DeletedDate"), JsonValue.from_f64(s.deletion_date.value()))
        # Only labelled versions are listed, as the service lists them.
        var map = JsonValue.empty_object()
        for i in range(len(s.versions)):
            if len(s.versions[i].stages) > 0:
                map.set_member(s.versions[i].version_id.copy(), _stages_json(s.versions[i].stages))
        o.set_member(String("VersionIdsToStages"), map^)
        return _ok(o)

    def _delete_secret(mut self, body: JsonValue) raises -> _Answer:
        var at = self.store.find(_opt_string(body, String("SecretId")).or_else(String("")))
        if at < 0:
            return _error(400, String("ResourceNotFoundException"), String(_NOT_FOUND_MESSAGE))
        var force = False
        if body.has(String("ForceDeleteWithoutRecovery")):
            force = body.get(String("ForceDeleteWithoutRecovery")).as_bool()
        var has_window = body.has(String("RecoveryWindowInDays"))
        var days = Int64(30)
        if has_window:
            days = body.get(String("RecoveryWindowInDays")).as_int64()
        if force and has_window:
            return _error(
                400,
                String("InvalidParameterException"),
                String("You can't use ForceDeleteWithoutRecovery in conjunction with RecoveryWindowInDays."),
            )
        if days < 7 or days > 30:
            return _error(
                400,
                String("InvalidParameterException"),
                String("RecoveryWindowInDays must be between 7 and 30."),
            )
        if self.store.secrets[at].is_scheduled_for_deletion():
            return _error(400, String("InvalidRequestException"), String(_MARKED_MESSAGE))
        var now = self.store.now()
        var arn = self.store.secrets[at].arn.copy()
        var name = self.store.secrets[at].name.copy()
        if force:
            self.store.remove(at)
        else:
            self.store.secrets[at].deletion_date = Optional[Float64](
                now + Float64(Int(days)) * SECONDS_PER_DAY
            )
        self.applied_writes += 1
        var o = JsonValue.empty_object()
        _member(o, String("ARN"), arn^)
        _member(o, String("Name"), name^)
        o.set_member(String("DeletionDate"), JsonValue.from_f64(now if force else now + Float64(Int(days)) * SECONDS_PER_DAY))
        return _ok(o)

    def _restore_secret(mut self, body: JsonValue) raises -> _Answer:
        var at = self.store.find(_opt_string(body, String("SecretId")).or_else(String("")))
        if at < 0:
            return _error(400, String("ResourceNotFoundException"), String(_NOT_FOUND_MESSAGE))
        self.store.secrets[at].deletion_date = Optional[Float64]()
        self.applied_writes += 1
        var o = JsonValue.empty_object()
        _member(o, String("ARN"), self.store.secrets[at].arn.copy())
        _member(o, String("Name"), self.store.secrets[at].name.copy())
        return _ok(o)
