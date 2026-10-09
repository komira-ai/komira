# =============================================================================
# kci_cloud_gcp/session.mojo: the one GCP session an adapter and its nodes
# share.
# =============================================================================
#
# `GcpSession` holds the generated clients (IAM, Cloud Resource Manager,
# Cloud Run jobs and Run's long-running operations), each over its own
# connector of the caller's type, the sleeper an operation's poll waits
# through (komira_retry's `Sleeper`: the system's, or a test's), one
# token source shared by all of them (`SharedTokenSource`: the adapter
# holds one caching source, and an apply that outlives one access token
# keeps working), the cell (project, region, machine, cell), and what the
# adapter learned during a verb: the object name of every realized node, and
# the physical id `list_owned` reported for every owned node (a node
# realized only to be removed carries no fields; this is how it finds its
# object). Each call runs the generated async client on a blocking runtime
# of its own.
#
# Every method here is one call or one read-modify-write, named for what it
# does to the cloud. Two are hand-written, because no generated client has
# them:
#   * `patch_account` sends IAM's PatchServiceAccount
#     (`PATCH /v1/{service_account.name=projects/*/serviceAccounts/*}`,
#     body `{"serviceAccount":{...},"updateMask":"..."}`): the generator
#     refuses a whole-request body whose path variable is a nested field, so
#     it is sent through komira_http_client as the generated methods are,
#     and refused through komira_gcp_core's `gcp_status_error`;
#   * `whoami` asks komira_gcp_core's token-information read who the token
#     is.
#
# A POLICY CHANGE is a read-modify-write with the etag it read (`edit_*`):
# it adds and removes exactly the memberships it is handed, keeps every
# other binding, conditional ones and audit configs included, writes
# nothing when nothing changes, and requests policy version 3 so a
# conditional binding is read whole. A write refused ABORTED (another writer
# changed the policy since the read) raises: the apply stops and the next
# one reads again.
#
# NOT FOUND is read from the status code of the client's error
# (`gcp_status_error_code`), never from a bare HTTP status or the message
# text: a 403 must not read as an absent object.
# =============================================================================

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import (
    CODE_NOT_FOUND,
    GcpConnectorTransport,
    GcpTokenSource,
    TOKEN_INFO_HOST,
    TokenInfo,
    fetch_token_info,
    gcp_status_error,
    gcp_status_error_code,
)
from komira_gcp_cloudresourcemanager.iam_policy import (
    GetIamPolicyRequest as CrmGetPolicyRequest,
    SetIamPolicyRequest as CrmSetPolicyRequest,
)
from komira_gcp_cloudresourcemanager.options import GetPolicyOptions as CrmPolicyOptions
from komira_gcp_cloudresourcemanager.policy import Binding as CrmBinding, Policy as CrmPolicy
from komira_gcp_cloudresourcemanager.projects import ProjectsClient
from komira_gcp_iam.iam import (
    CreateServiceAccountRequest,
    DeleteServiceAccountRequest,
    GetServiceAccountRequest,
    IAMClient,
    ListServiceAccountsRequest,
    ServiceAccount,
)
from komira_gcp_iam.iam_policy import (
    GetIamPolicyRequest as IamGetPolicyRequest,
    SetIamPolicyRequest as IamSetPolicyRequest,
)
from komira_gcp_iam.options import GetPolicyOptions as IamPolicyOptions
from komira_gcp_iam.policy import Binding as IamBinding, Policy as IamPolicy
from komira_gcp_run.operations import GetOperationRequest, Operation, OperationsClient
from komira_gcp_run.job import (
    CreateJobRequest,
    DeleteJobRequest,
    GetJobRequest,
    Job,
    JobsClient,
    ListJobsRequest,
    UpdateJobRequest,
)
from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, HttpClientConfig, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_json import JsonValue
from komira_proto_codec import decode_json
from komira_retry import Sleeper

from kci_cloud_gcp.names import account_resource, job_parent, project_resource


comptime _RT = BlockingRuntime[NoopSink]
comptime _IAM_DEFAULT_HOST = "iam.googleapis.com"
comptime OP_POLLS_MAX = 12
"""How many times a long-running operation not yet done is read again
before the verb gives up."""
comptime OP_FIRST_DELAY_MS: Int64 = 500
comptime OP_MAX_DELAY_MS: Int64 = 8000
comptime POLICY_VERSION = 3
"""The policy version every read asks for and every write sends: a
conditional binding is read and written whole."""


def _rt() raises -> _RT:
    return _RT.new(NoopSink(_placeholder=UInt8(0)))


def json_text(s: String) -> String:
    """`s` as a JSON string literal."""
    return JsonValue.from_string(s.copy()).serialize()


def operation_poll_delays() -> List[Int64]:
    """The wait before each read of a long-running operation not yet done:
    500 ms, doubling, at most 8 s each, `OP_POLLS_MAX` of them (about 75 s
    in all). A verb whose operation is not done after the last raises."""
    var out = List[Int64]()
    var d = OP_FIRST_DELAY_MS
    for _ in range(OP_POLLS_MAX):
        out.append(d)
        d = d * 2
        if d > OP_MAX_DELAY_MS:
            d = OP_MAX_DELAY_MS
    return out^


def _is_not_found(e: String, verb: String, rpc: String) -> Bool:
    return gcp_status_error_code(verb, rpc, e) == CODE_NOT_FOUND


@fieldwise_init
struct GcpEndpoint(Copyable, Movable):
    """Where one service is reached: an empty `host` is the service's
    public endpoint; a test points a service at an emulator (`plaintext`
    `http` to an IP literal, `port` 0 for the scheme's own)."""

    var host: String
    var port: UInt16
    var plaintext: Bool

    @staticmethod
    def public() -> GcpEndpoint:
        return GcpEndpoint(String(""), UInt16(0), False)


struct GcpEndpoints(Copyable, Movable):
    """The endpoint of each service the adapter calls."""

    var iam: GcpEndpoint
    var crm: GcpEndpoint
    var run: GcpEndpoint
    var token_info: GcpEndpoint

    def __init__(
        out self,
        iam: GcpEndpoint = GcpEndpoint.public(),
        crm: GcpEndpoint = GcpEndpoint.public(),
        run: GcpEndpoint = GcpEndpoint.public(),
        token_info: GcpEndpoint = GcpEndpoint.public(),
    ):
        self.iam = iam.copy()
        self.crm = crm.copy()
        self.run = run.copy()
        self.token_info = token_info.copy()

    def __init__(out self, *, copy: Self):
        self.iam = copy.iam.copy()
        self.crm = copy.crm.copy()
        self.run = copy.run.copy()
        self.token_info = copy.token_info.copy()


struct GcpConnectors[C: Connector](Movable):
    """One connector per client the session builds (a connector belongs to
    the one HTTP client it is given)."""

    var iam: Optional[Self.C]
    var crm: Optional[Self.C]
    var run: Optional[Self.C]
    var operations: Optional[Self.C]
    var patch: Optional[Self.C]
    var token_info: Optional[Self.C]

    def __init__(
        out self,
        var iam: Self.C,
        var crm: Self.C,
        var run: Self.C,
        var operations: Self.C,
        var patch: Self.C,
        var token_info: Self.C,
    ):
        self.iam = Optional[Self.C](iam^)
        self.crm = Optional[Self.C](crm^)
        self.run = Optional[Self.C](run^)
        self.operations = Optional[Self.C](operations^)
        self.patch = Optional[Self.C](patch^)
        self.token_info = Optional[Self.C](token_info^)


struct SharedTokenSource[TS: GcpTokenSource](GcpTokenSource, Movable, Deinitable):
    """One token source, handed to every client: each asks the same source,
    so one cached token serves them all."""

    var _ts: ArcPointer[Self.TS]

    def __init__(out self, ts: ArcPointer[Self.TS]):
        self._ts = ts.copy()

    def access_token(mut self) raises -> String:
        return self._ts[].access_token()


@fieldwise_init
struct PolicyEntry(Copyable, Movable):
    """One membership of a policy: `member` holds `role`; `conditional` when
    its binding has a condition (never kci's: attribution skips it)."""

    var role: String
    var member: String
    var conditional: Bool


def _entries_iam(p: IamPolicy) -> List[PolicyEntry]:
    var out = List[PolicyEntry]()
    for i in range(len(p.bindings)):
        var cond = Bool(p.bindings[i].condition)
        for k in range(len(p.bindings[i].members)):
            out.append(PolicyEntry(p.bindings[i].role.copy(), p.bindings[i].members[k].copy(), cond))
    return out^


def _entries_crm(p: CrmPolicy) -> List[PolicyEntry]:
    var out = List[PolicyEntry]()
    for i in range(len(p.bindings)):
        var cond = Bool(p.bindings[i].condition)
        for k in range(len(p.bindings[i].members)):
            out.append(PolicyEntry(p.bindings[i].role.copy(), p.bindings[i].members[k].copy(), cond))
    return out^


def _holds(entries: List[PolicyEntry], role: String, member: String) -> Bool:
    for i in range(len(entries)):
        if not entries[i].conditional and entries[i].role == role and entries[i].member == member:
            return True
    return False


def _members_without(members: List[String], member: String) -> List[String]:
    var out = List[String]()
    for i in range(len(members)):
        if members[i] != member:
            out.append(members[i].copy())
    return out^


def _edit_iam(var p: IamPolicy, adds: List[PolicyEntry], removes: List[PolicyEntry]) -> IamPolicy:
    """`p` with each unconditional membership of `removes` dropped and each
    of `adds` added; every other binding kept as it was."""
    for r in range(len(removes)):
        for i in range(len(p.bindings)):
            if not p.bindings[i].condition and p.bindings[i].role == removes[r].role:
                p.bindings[i].members = _members_without(p.bindings[i].members, removes[r].member)
    for a in range(len(adds)):
        var placed = False
        for i in range(len(p.bindings)):
            if not p.bindings[i].condition and p.bindings[i].role == adds[a].role:
                var have = False
                for k in range(len(p.bindings[i].members)):
                    if p.bindings[i].members[k] == adds[a].member:
                        have = True
                if not have:
                    p.bindings[i].members.append(adds[a].member.copy())
                placed = True
                break
        if not placed:
            var members = List[String]()
            members.append(adds[a].member.copy())
            p.bindings.append(IamBinding(adds[a].role.copy(), members^, None))
    var kept = List[IamBinding]()
    for i in range(len(p.bindings)):
        if len(p.bindings[i].members) > 0:
            kept.append(p.bindings[i].copy())
    p.bindings = kept^
    p.version = Int32(POLICY_VERSION)
    return p^


def _edit_crm(var p: CrmPolicy, adds: List[PolicyEntry], removes: List[PolicyEntry]) -> CrmPolicy:
    """`_edit_iam` for a project's policy (the same proto, its own
    generated type)."""
    for r in range(len(removes)):
        for i in range(len(p.bindings)):
            if not p.bindings[i].condition and p.bindings[i].role == removes[r].role:
                p.bindings[i].members = _members_without(p.bindings[i].members, removes[r].member)
    for a in range(len(adds)):
        var placed = False
        for i in range(len(p.bindings)):
            if not p.bindings[i].condition and p.bindings[i].role == adds[a].role:
                var have = False
                for k in range(len(p.bindings[i].members)):
                    if p.bindings[i].members[k] == adds[a].member:
                        have = True
                if not have:
                    p.bindings[i].members.append(adds[a].member.copy())
                placed = True
                break
        if not placed:
            var members = List[String]()
            members.append(adds[a].member.copy())
            p.bindings.append(CrmBinding(adds[a].role.copy(), members^, None))
    var kept = List[CrmBinding]()
    for i in range(len(p.bindings)):
        if len(p.bindings[i].members) > 0:
            kept.append(p.bindings[i].copy())
    p.bindings = kept^
    p.version = Int32(POLICY_VERSION)
    return p^


def _changes(entries: List[PolicyEntry], adds: List[PolicyEntry], removes: List[PolicyEntry]) -> Bool:
    for i in range(len(adds)):
        if not _holds(entries, adds[i].role, adds[i].member):
            return True
    for i in range(len(removes)):
        if _holds(entries, removes[i].role, removes[i].member):
            return True
    return False


def _percent_path(s: String) -> String:
    """`@` percent-encoded, as the generated clients write an account's
    email into a path."""
    return s.replace("@", "%40")


struct GcpSession[C: Connector, TS: GcpTokenSource, S: Sleeper](Movable):
    """The adapter's session (the file header)."""

    var iam: IAMClient[Self.C, SharedTokenSource[Self.TS]]
    var crm: ProjectsClient[Self.C, SharedTokenSource[Self.TS]]
    var jobs: JobsClient[Self.C, SharedTokenSource[Self.TS]]
    var ops: OperationsClient[Self.C, SharedTokenSource[Self.TS]]
    var sleeper: Self.S
    var patch_http: HttpClient[Self.C]
    var info: GcpConnectorTransport[Self.C]
    var token: SharedTokenSource[Self.TS]
    var endpoints: GcpEndpoints
    var project: String
    var region: String
    var machine: String
    var cell: String
    var node_ids: List[String]
    var node_kinds: List[String]
    var node_names: List[String]
    var owned_nodes: List[String]
    var owned_ids: List[String]

    def __init__(
        out self,
        var connectors: GcpConnectors[Self.C],
        var token_source: Self.TS,
        var sleeper: Self.S,
        endpoints: GcpEndpoints,
    ) raises:
        var shared = ArcPointer[Self.TS](token_source^)
        self.iam = IAMClient[Self.C, SharedTokenSource[Self.TS]](
            HttpClient[Self.C].with_defaults(connectors.iam.take()), SharedTokenSource[Self.TS](shared)
        )
        self.crm = ProjectsClient[Self.C, SharedTokenSource[Self.TS]](
            HttpClient[Self.C].with_defaults(connectors.crm.take()), SharedTokenSource[Self.TS](shared)
        )
        self.jobs = JobsClient[Self.C, SharedTokenSource[Self.TS]](
            HttpClient[Self.C].with_defaults(connectors.run.take()), SharedTokenSource[Self.TS](shared)
        )
        self.ops = OperationsClient[Self.C, SharedTokenSource[Self.TS]](
            HttpClient[Self.C].with_defaults(connectors.operations.take()), SharedTokenSource[Self.TS](shared)
        )
        self.sleeper = sleeper^
        self.patch_http = HttpClient[Self.C].with_defaults(connectors.patch.take())
        self.info = GcpConnectorTransport[Self.C](HttpClientConfig.defaults(), connectors.token_info.take())
        self.token = SharedTokenSource[Self.TS](shared)
        self.endpoints = endpoints.copy()
        self.project = String("")
        self.region = String("")
        self.machine = String("")
        self.cell = String("")
        self.node_ids = List[String]()
        self.node_kinds = List[String]()
        self.node_names = List[String]()
        self.owned_nodes = List[String]()
        self.owned_ids = List[String]()
        if endpoints.iam.host.byte_length() > 0:
            self.iam.set_rest_endpoint(endpoints.iam.host.copy(), endpoints.iam.port, endpoints.iam.plaintext)
        if endpoints.crm.host.byte_length() > 0:
            self.crm.set_rest_endpoint(endpoints.crm.host.copy(), endpoints.crm.port, endpoints.crm.plaintext)
        if endpoints.run.host.byte_length() > 0:
            self.jobs.set_rest_endpoint(endpoints.run.host.copy(), endpoints.run.port, endpoints.run.plaintext)
            self.ops.set_rest_endpoint(endpoints.run.host.copy(), endpoints.run.port, endpoints.run.plaintext)

    # --- what the adapter learned ------------------------------------------

    def remember_node(mut self, id: String, kind: String, name: String):
        """Record a realized node's kind and object name (replacing an
        earlier record of the same id)."""
        for i in range(len(self.node_ids)):
            if self.node_ids[i] == id:
                self.node_kinds[i] = kind
                self.node_names[i] = name
                return
        self.node_ids.append(id)
        self.node_kinds.append(kind)
        self.node_names.append(name)

    def kind_of_node(self, id: String) -> String:
        for i in range(len(self.node_ids)):
            if self.node_ids[i] == id:
                return self.node_kinds[i].copy()
        return String("")

    def name_of_node(self, id: String) -> String:
        """The object name of a realized node, or empty."""
        for i in range(len(self.node_ids)):
            if self.node_ids[i] == id:
                return self.node_names[i].copy()
        return String("")

    def remember_owned(mut self, var nodes: List[String], var ids: List[String]):
        self.owned_nodes = nodes^
        self.owned_ids = ids^

    def owned_id_of(self, node: String) -> String:
        """The physical id `list_owned` last reported for `node`, or empty."""
        for i in range(len(self.owned_nodes)):
            if self.owned_nodes[i] == node:
                return self.owned_ids[i].copy()
        return String("")

    # --- IAM: service accounts ---------------------------------------------

    def get_account(mut self, email: String) raises -> Optional[ServiceAccount]:
        var rt = _rt()
        ref reactor = rt.reactor()
        try:
            return self.iam.get_service_account[_RT](
                GetServiceAccountRequest(account_resource(self.project, email)), reactor
            )
        except e:
            if _is_not_found(String(e), String("GET"), String("GetServiceAccount")):
                return None
            raise e^

    def list_accounts(mut self) raises -> List[ServiceAccount]:
        """Every account of the project, every page followed."""
        var out = List[ServiceAccount]()
        var token = String("")
        for _ in range(10000):
            var rt = _rt()
            ref reactor = rt.reactor()
            var page = self.iam.list_service_accounts[_RT](
                ListServiceAccountsRequest(project_resource(self.project), Int32(100), token.copy()), reactor
            )
            for i in range(len(page.accounts)):
                out.append(page.accounts[i].copy())
            if page.next_page_token.byte_length() == 0:
                return out^
            token = page.next_page_token.copy()
        raise Error(String("kci_cloud_gcp: the account list did not end"))

    def create_account(mut self, account_id: String, display_name: String, description: String) raises -> ServiceAccount:
        """One CreateServiceAccount carrying the display name and the
        description: an account is born with its stamp."""
        var text = (
            String("{\"name\":") + json_text(project_resource(self.project))
            + String(",\"accountId\":") + json_text(account_id)
            + String(",\"serviceAccount\":{\"displayName\":") + json_text(display_name)
            + String(",\"description\":") + json_text(description) + String("}}")
        )
        var rt = _rt()
        ref reactor = rt.reactor()
        return self.iam.create_service_account[_RT](decode_json[CreateServiceAccountRequest](text), reactor)

    def patch_account(mut self, email: String, display_name: Optional[String], description: Optional[String]) raises:
        """PatchServiceAccount (the file header): writes the fields given,
        and names exactly those in the update mask."""
        var sa = String("{")
        var mask = String("")
        if display_name:
            sa += String("\"displayName\":") + json_text(display_name.value())
            mask = String("displayName")
        if description:
            if mask.byte_length() > 0:
                sa += String(",")
                mask += String(",")
            sa += String("\"description\":") + json_text(description.value())
            mask += String("description")
        sa += String("}")
        if mask.byte_length() == 0:
            return
        var body = String("{\"serviceAccount\":") + sa + String(",\"updateMask\":") + json_text(mask) + String("}")
        var path = String("/v1/") + _percent_path(account_resource(self.project, email))
        var host = String(_IAM_DEFAULT_HOST)
        if self.endpoints.iam.host.byte_length() > 0:
            host = self.endpoints.iam.host.copy()
        var url: Url
        if self.endpoints.iam.plaintext:
            url = Url.http(host^, self.endpoints.iam.port, path^)
        else:
            url = Url.https(host^, self.endpoints.iam.port, path^)
        var headers = HeaderMap()
        headers.append(String("Authorization"), String("Bearer ") + self.token.access_token())
        headers.append(String("Content-Type"), String("application/json"))
        var req = build_request_with_body[BytesBody](HttpMethod.patch(), url^, headers^, BytesBody.from_str(body))
        var rt = _rt()
        ref reactor = rt.reactor()
        var resp = self.patch_http.send_buffered[_RT, BytesBody](req^, reactor)
        var status = Int(resp.status)
        var bytes = resp.body.take_bytes()
        if status < 200 or status >= 300:
            raise gcp_status_error(String("PATCH"), String("PatchServiceAccount"), status, bytes)

    def delete_account(mut self, email: String) raises:
        """DeleteServiceAccount; an account already gone is a no-op."""
        var rt = _rt()
        ref reactor = rt.reactor()
        try:
            _ = self.iam.delete_service_account[_RT](
                DeleteServiceAccountRequest(account_resource(self.project, email)), reactor
            )
        except e:
            if not _is_not_found(String(e), String("DELETE"), String("DeleteServiceAccount")):
                raise e^

    # --- policies ----------------------------------------------------------

    def _iam_policy(mut self, resource: String) raises -> IamPolicy:
        var rt = _rt()
        ref reactor = rt.reactor()
        return self.iam.get_iam_policy[_RT](
            IamGetPolicyRequest(resource, IamPolicyOptions(Int32(POLICY_VERSION))), reactor
        )

    def account_policy(mut self, email: String) raises -> Optional[List[PolicyEntry]]:
        """The memberships of an account's policy; None when the account is
        gone."""
        try:
            return _entries_iam(self._iam_policy(account_resource(self.project, email)))
        except e:
            if _is_not_found(String(e), String("POST"), String("GetIamPolicy")):
                return None
            raise e^

    def edit_account_policy(
        mut self, email: String, adds: List[PolicyEntry], removes: List[PolicyEntry]
    ) raises -> Bool:
        """The read-modify-write of an account's policy (the file header);
        False when nothing changed (and nothing was written)."""
        var resource = account_resource(self.project, email)
        var p = self._iam_policy(resource)
        if not _changes(_entries_iam(p), adds, removes):
            return False
        var edited = _edit_iam(p^, adds, removes)
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = self.iam.set_iam_policy[_RT](IamSetPolicyRequest(resource, edited^, None), reactor)
        return True

    def _crm_policy(mut self) raises -> CrmPolicy:
        var rt = _rt()
        ref reactor = rt.reactor()
        return self.crm.get_iam_policy[_RT](
            CrmGetPolicyRequest(project_resource(self.project), CrmPolicyOptions(Int32(POLICY_VERSION))), reactor
        )

    def project_policy(mut self) raises -> List[PolicyEntry]:
        return _entries_crm(self._crm_policy())

    def edit_project_policy(mut self, adds: List[PolicyEntry], removes: List[PolicyEntry]) raises -> Bool:
        var p = self._crm_policy()
        if not _changes(_entries_crm(p), adds, removes):
            return False
        var edited = _edit_crm(p^, adds, removes)
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = self.crm.set_iam_policy[_RT](CrmSetPolicyRequest(project_resource(self.project), edited^, None), reactor)
        return True

    # --- Cloud Run: jobs ---------------------------------------------------

    def get_job(mut self, name: String) raises -> Optional[Job]:
        var rt = _rt()
        ref reactor = rt.reactor()
        try:
            return self.jobs.get_job[_RT](GetJobRequest(name), reactor)
        except e:
            if _is_not_found(String(e), String("GET"), String("GetJob")):
                return None
            raise e^

    def list_jobs(mut self) raises -> List[Job]:
        """Every job of the cell's region, every page followed."""
        var out = List[Job]()
        var token = String("")
        for _ in range(10000):
            var rt = _rt()
            ref reactor = rt.reactor()
            var page = self.jobs.list_jobs[_RT](
                ListJobsRequest(job_parent(self.project, self.region), Int32(100), token.copy(), False), reactor
            )
            for i in range(len(page.jobs)):
                out.append(page.jobs[i].copy())
            if page.next_page_token.byte_length() == 0:
                return out^
            token = page.next_page_token.copy()
        raise Error(String("kci_cloud_gcp: the job list did not end"))

    def _settle(mut self, var op: Operation, name: String, what: String) raises:
        """Wait for a long-running operation to end: an operation that ended
        in error raises; one not yet done is read again (GetOperation),
        after each of `operation_poll_delays()` in turn, through the
        session's sleeper; one still not done after the last raises. Only
        the operation says the change is done: the job itself is never read
        in its place, so a job that is gone never passes for one that
        settled."""
        var delays = operation_poll_delays()
        for attempt in range(len(delays) + 1):
            if op.error:
                raise Error(
                    String("kci_cloud_gcp: ") + what + String(" of ") + name + String(" failed: ")
                    + op.error.value().message
                )
            if op.done:
                return
            if attempt == len(delays):
                break
            self.sleeper.sleep_ms(delays[attempt])
            var rt = _rt()
            ref reactor = rt.reactor()
            op = self.ops.get_operation[_RT](GetOperationRequest(op.name.copy()), reactor)
        raise Error(
            String("kci_cloud_gcp: ") + what + String(" of ") + name + String(" did not finish after ")
            + String(len(delays)) + String(" reads of its operation")
        )

    def create_job(mut self, job_id: String, job_json: String) raises:
        """One CreateJob carrying the whole job, its labels included: a job
        is born with its stamp."""
        var rt = _rt()
        ref reactor = rt.reactor()
        var op = self.jobs.create_job[_RT](
            CreateJobRequest(job_parent(self.project, self.region), decode_json[Job](job_json), job_id, False), reactor
        )
        self._settle(op^, job_parent(self.project, self.region) + String("/jobs/") + job_id, String("the create"))

    def update_job(mut self, var job: Job) raises:
        """One UpdateJob with the whole job (its name says which)."""
        var name = job.name.copy()
        var rt = _rt()
        ref reactor = rt.reactor()
        var op = self.jobs.update_job[_RT](UpdateJobRequest(job^, False, False), reactor)
        self._settle(op^, name, String("the update"))

    def delete_job(mut self, name: String) raises:
        """DeleteJob; a job already gone is a no-op."""
        var rt = _rt()
        ref reactor = rt.reactor()
        try:
            var op = self.jobs.delete_job[_RT](DeleteJobRequest(name, False, String("")), reactor)
            self._settle(op^, name, String("the delete"))
        except e:
            if not _is_not_found(String(e), String("DELETE"), String("DeleteJob")):
                raise e^

    # --- who -----------------------------------------------------------------

    def whoami(mut self) raises -> TokenInfo:
        var host = String(TOKEN_INFO_HOST)
        var scheme = String("https")
        var port = 443
        if self.endpoints.token_info.host.byte_length() > 0:
            host = self.endpoints.token_info.host.copy()
            if self.endpoints.token_info.plaintext:
                scheme = String("http")
                port = 80
            if self.endpoints.token_info.port != 0:
                port = Int(self.endpoints.token_info.port)
        return fetch_token_info(self.info, self.token.access_token(), scheme, host, port)
