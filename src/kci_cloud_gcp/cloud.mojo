# =============================================================================
# kci_cloud_gcp/cloud.mojo: `GcpCloud`, the GCP `CloudAdapter`.
# =============================================================================
#
# What each trait method answers (docs/design/deploy_step.md, "The GCP
# adapter"):
#   implemented / absences  service_account, container_job and grant (which
#                    `check` refuses on this DERIVED shape, as the gcp fake
#                    does); every other catalog type NOT_YET when PORTABLE,
#                    ABSENT_BY_DESIGN when CLOUD_BOUND, each named once.
#   configure        `project` and `region` are required, any other key is a
#                    finding, and so is a bootstrap registry name
#                    (`<machine>-<cell>-images`) over 63 bytes.
#   check            the shared shape's limits (kci_cloud.shape), the derived
#                    grant stamp's two refusals among them, and the
#                    description an identity's service account will carry:
#                    over 256 bytes is refused at validate, counting the
#                    run-id line of a create (or the mark line of an adopted
#                    account).
#   lower            THE shared shape lowering on the gcp shape.
#   realize          one node per provider kind: an account (node_account),
#                    a job (node_job), a member binding (node_binding).
#   label_rule / identity_of  the standard rule; an account carries it as
#                    description lines, a binding derives it.
#   list_owned       owned.mojo.
#   read_existing    a get by the object's cloud name and the node's kind:
#                    present, stamped, the kind, the name, and the fields of
#                    the shape it can read under the lowering's names.
#   release          one patch: an account's description loses kci's lines
#                    (leaving it empty, the description being kci's whole),
#                    a job's labels lose every kci label; nothing else
#                    changes, and nothing is deleted.
#   whoami           the token's principal (komira_gcp_core's token
#                    information read).
#   trust_check      REFUSES every cell: trust checking is not configured
#                    yet. What it must compare (the workload identity
#                    provider's name and the repository condition it holds,
#                    deploy_step.md question Q14) is an open design
#                    question, and a cell's settings name neither, so no
#                    cell can pass a check that has nothing to compare.
#   image_registry   `<region>-docker.pkg.dev/<project>/<machine>-<cell>-images`,
#                    from the settings, machine and cell alone.
#   registry_login   the access-token user and a fresh access token.
#
# The adapter runs every call as its token source, the one it was built
# with: `Creds` is not read.
# =============================================================================

from std.memory import ArcPointer

from kci_cloud import (
    ABSENT_BY_DESIGN,
    Absence,
    ArtifactNeed,
    BootstrapItem,
    CLOUD_BOUND,
    Catalog,
    CellContext,
    CloudAdapter,
    CloudId,
    ExistingObject,
    FIELD_CONTAINER_JOB,
    FIELD_GRANT,
    FIELD_SERVICE_ACCOUNT,
    FINDING_CELL,
    FINDING_LIMIT,
    Feed,
    Finding,
    Firing,
    GrantEdge,
    LoweredNode,
    NOT_YET,
    OwnedRecord,
    Principal,
    ProviderShape,
    RegistryLogin,
    Setting,
    V1_IMAGE_PLATFORM,
    body_field,
    description_carrier_bytes,
    description_labels,
    holds_own_identity,
    lower_shape,
    released_description,
    shape_limits,
    standard_identity_of,
    standard_label_rule,
)
from kci_cloud.metadata import adopts
from kci_reconciler import CellScope, Creds, ErasedResource, Label, OwnerStamp, RETAIN_DELETE
from kci_resource_proto.resource import Resource
from komira_gcp_core import GcpTokenSource
from komira_http_core.transport.io_stream import Connector
from komira_proto_codec.codec import encode_json

from kci_cloud_gcp.job_model import ModelField, job_labels, live_model, parse_job
from kci_cloud_gcp.names import (
    KIND_ACCOUNT,
    KIND_BINDING,
    KIND_JOB,
    account_email,
    job_resource,
    last_segment,
    object_name,
)
from kci_cloud_gcp.node_account import GcpAccountNode
from kci_cloud_gcp.node_binding import GcpBindingNode
from kci_cloud_gcp.node_job import GcpJobNode, labels_dict, without_kci
from kci_cloud_gcp.owned import owned_records
from kci_cloud_gcp.session import GcpConnectors, GcpEndpoints, GcpSession


comptime GCP_CLOUD_ID = "gcp"
comptime ACCOUNT_DESCRIPTION_MAX = 256
"""IAM's bound on a service account's description, in bytes."""
comptime DESCRIPTION_CITATION = "IAM ServiceAccount.description: at most 256 bytes"
comptime REGISTRY_NAME_MAX = 63
comptime REGISTRY_USER = "oauth2accesstoken"
"""The user a registry client presents with an access token as its
password."""
comptime SETTING_PROJECT = "project"
comptime SETTING_REGION = "region"


def registry_name(machine: String, cell: String) -> String:
    """The cell's bootstrap image registry: `<machine>-<cell>-images`."""
    return machine + String("-") + cell + String("-images")


def _setting_finding(key: String, why: String) -> Finding:
    return Finding(FINDING_CELL, String("(cell)"), String("settings.") + key, why)


struct GcpCloud[C: Connector, TS: GcpTokenSource](CloudAdapter, Movable):
    """The GCP adapter (the file header). Built over one connector per
    client (`GcpConnectors`), one token source, and where each service is
    (`GcpEndpoints`: the public endpoints by default)."""

    var _id: String
    var _s: ArcPointer[GcpSession[Self.C, Self.TS]]
    var _shape: ProviderShape
    var _run: Optional[String]

    def __init__(
        out self,
        var connectors: GcpConnectors[Self.C],
        var token_source: Self.TS,
        endpoints: GcpEndpoints = GcpEndpoints(),
        id: String = String(GCP_CLOUD_ID),
    ) raises:
        self._id = id
        self._s = ArcPointer[GcpSession[Self.C, Self.TS]](
            GcpSession[Self.C, Self.TS](connectors^, token_source^, endpoints)
        )
        self._shape = ProviderShape.gcp()
        self._run = None

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return False

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE_ACCOUNT)
        l.append(FIELD_CONTAINER_JOB)
        l.append(FIELD_GRANT)
        return l^

    def absences(self) -> List[Absence]:
        var hosted = self.implemented()
        var out = List[Absence]()
        var catalog: Catalog
        try:
            catalog = Catalog.v1()
        except:
            # The catalog is data kci builds; if it cannot, coverage is
            # refused by the empty declaration (`artifact_problems`).
            return out^
        for i in range(len(catalog.types)):
            ref t = catalog.types[i]
            var here = False
            for k in range(len(hosted)):
                if hosted[k] == t.field:
                    here = True
            if here:
                continue
            if t.portability == CLOUD_BOUND:
                out.append(Absence(t.field, ABSENT_BY_DESIGN, String("kci_cloud_gcp does not host ") + t.name + String(" in v1")))
            else:
                out.append(Absence(t.field, NOT_YET, String("kci_cloud_gcp does not host ") + t.name + String(" yet")))
        return out^

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        var out = List[Finding]()
        var project = String("")
        var region = String("")
        for i in range(len(ctx.settings)):
            ref st = ctx.settings[i]
            if st.key == SETTING_PROJECT:
                project = st.value.copy()
            elif st.key == SETTING_REGION:
                region = st.value.copy()
            else:
                out.append(_setting_finding(st.key, String("not a setting of a GCP cell (project and region are)")))
        if project.byte_length() == 0:
            out.append(_setting_finding(String(SETTING_PROJECT), String("a GCP cell names its project")))
        if region.byte_length() == 0:
            out.append(_setting_finding(String(SETTING_REGION), String("a GCP cell names its region")))
        var registry = registry_name(ctx.scope.machine, ctx.scope.cell)
        if registry.byte_length() > REGISTRY_NAME_MAX:
            out.append(
                _setting_finding(
                    String("(registry)"),
                    String("the cell's image registry \"") + registry + String("\" is ")
                    + String(registry.byte_length()) + String(" bytes; GCP allows 63: shorten the machine or cell name"),
                )
            )
        ref s = self._s[]
        s.project = project^
        s.region = region^
        s.machine = ctx.scope.machine.copy()
        s.cell = ctx.scope.cell.copy()
        self._run = ctx.scope.validation_run_id.copy()
        return out^

    def public_mechanism(self) -> String:
        return String("")

    def check(self, r: Resource, feeds: List[Feed], firings: List[Firing]) -> List[Finding]:
        var out = List[Finding]()
        shape_limits(r, feeds, firings, self._shape, self._id, out)
        if not holds_own_identity(r):
            return out^
        var stamp = OwnerStamp(
            self._s[].machine.copy(), self._s[].cell.copy(), r.id.copy(), String("identity"), validation_run_id=self._run
        )
        try:
            # The identity's account carries kci's lines in its description:
            # adopted only when it is the resource's primary node (an account).
            var adopted = adopts(r) and body_field(r) == FIELD_SERVICE_ACCOUNT
            var n = description_carrier_bytes(stamp, RETAIN_DELETE, adopted)
            if n > ACCOUNT_DESCRIPTION_MAX:
                out.append(
                    Finding(
                        FINDING_LIMIT,
                        r.id,
                        String("id"),
                        String("the service account of \"") + r.id + String("\" would carry a ")
                        + String(n) + String("-byte description; GCP allows 256: shorten the machine, cell or resource name"),
                        String(DESCRIPTION_CITATION),
                    )
                )
        except e:
            out.append(Finding(FINDING_LIMIT, r.id, String("id"), String("its identity cannot be stamped: ") + String(e)))
        return out^

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String(V1_IMAGE_PLATFORM))

    def lower(
        self, r: Resource, edges: List[GrantEdge], feeds: List[Feed], firings: List[Firing]
    ) raises -> List[LoweredNode]:
        return lower_shape(r, edges, feeds, firings, String(""), self._shape)

    def _name_of(self, node: LoweredNode) -> String:
        """The cloud name of a node's object: its physical name, else the
        object `list_owned` found for it, else the derived name."""
        ref s = self._s[]
        var physical = node.field(String("physical_name"))
        if physical.byte_length() > 0:
            return physical^
        var owned = s.owned_id_of(node.id)
        if owned.byte_length() > 0:
            var last = last_segment(owned)
            var at = last.find("@")
            if at > 0:
                return String(last[byte=0:at])
            return last^
        return object_name(s.machine, s.cell, node.id, String(""))

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        if node.kind == KIND_ACCOUNT:
            var id = self._name_of(node)
            self._s[].remember_node(node.id, node.kind, id)
            return ErasedResource.erase(
                GcpAccountNode[Self.C, Self.TS](self._s, node, account_email(id, self._s[].project))
            )
        if node.kind == KIND_JOB:
            var id = self._name_of(node)
            self._s[].remember_node(node.id, node.kind, id)
            return ErasedResource.erase(
                GcpJobNode[Self.C, Self.TS](self._s, node, job_resource(self._s[].project, self._s[].region, id))
            )
        if node.kind == KIND_BINDING:
            self._s[].remember_node(node.id, node.kind, String(""))
            return ErasedResource.erase(GcpBindingNode[Self.C, Self.TS](self._s, node))
        raise Error(
            String("kci_cloud_gcp: node ") + node.id + String(" is of kind ") + node.kind
            + String(", which this adapter does not create")
        )

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        var l = List[BootstrapItem]()
        l.append(
            BootstrapItem(
                String("state-store"),
                machine + String("-") + cell + String("-ledger"),
                String("the cell's ledger; created first, so the rest is recorded in it"),
            )
        )
        l.append(BootstrapItem(String("registry"), registry_name(machine, cell), String("where the cell pulls images by digest")))
        return l^

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return owned_records(self._s[], scope)

    def read_existing(mut self, creds: Creds, node: LoweredNode) raises -> ExistingObject:
        var name = self._name_of(node)
        if node.kind == KIND_ACCOUNT:
            var sa = self._s[].get_account(account_email(name, self._s[].project))
            if not sa:
                return ExistingObject()
            var stamped = standard_identity_of(description_labels(sa.value().description)).byte_length() > 0
            return ExistingObject(True, stamped, String(KIND_ACCOUNT), name)
        if node.kind == KIND_JOB:
            var job = self._s[].get_job(job_resource(self._s[].project, self._s[].region, name))
            if not job:
                return ExistingObject()
            var doc = parse_job(encode_json(job.value()))
            var stamped = standard_identity_of(job_labels(doc)).byte_length() > 0
            var live = live_model(doc, List[ModelField]())
            var fields = List[Setting]()
            for i in range(len(live)):
                ref k = live[i].key
                if k == "img" or k == "size" or k == "retries" or k == "timeout":
                    fields.append(Setting(k.copy(), live[i].value.copy()))
            return ExistingObject(True, stamped, String(KIND_JOB), name, fields^)
        raise Error(String("kci_cloud_gcp: ") + node.id + String(" is a ") + node.kind + String(", which cannot be adopted"))

    def release(mut self, creds: Creds, record: OwnedRecord) raises:
        if record.kind == KIND_ACCOUNT:
            var email = last_segment(record.id)
            var sa = self._s[].get_account(email)
            if not sa:
                raise Error(String("kci_cloud_gcp: the account to release is gone: ") + record.owner_node)
            # One patch of the description: kci's lines go, nothing else.
            self._s[].patch_account(email, None, released_description(sa.value().description))
            return
        if record.kind == KIND_JOB:
            var job = self._s[].get_job(record.id)
            if not job:
                raise Error(String("kci_cloud_gcp: the job to release is gone: ") + record.owner_node)
            var j = job.value().copy()
            j.labels = labels_dict(without_kci(j))
            self._s[].update_job(j^)
            return
        raise Error(String("kci_cloud_gcp: ") + record.owner_node + String(" is a ") + record.kind + String(", which is never adopted"))

    def whoami(mut self, creds: Creds) raises -> Principal:
        var info = self._s[].whoami()
        return Principal(info.principal(), String("projects/") + self._s[].project)

    def trust_render(self, scope: CellScope) -> String:
        return (
            String("cloud \"") + self._id + String("\": cell ") + scope.cell + String(" of ") + scope.machine
            + String(" is deployed into project ") + self._s[].project
            + String(" by an identity a workload identity provider admits; trust checking is not configured yet")
        )

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        # OPEN QUESTION (docs/design/deploy_step.md, the trust_check row and
        # question Q14): which workload identity provider a cell trusts, and
        # the repository condition it must hold byte for byte, are not
        # decided, and `configure` takes no setting for them. Until they are,
        # every cell is refused here; no setting is invented.
        var out = List[Finding]()
        out.append(
            Finding(
                FINDING_CELL,
                String("(cell)"),
                String("trust"),
                String("cloud \"") + self._id
                + String("\": trust checking is not configured yet (which workload identity provider a cell trusts,")
                + String(" and the repository it admits, are not decided), so every cell is refused"),
            )
        )
        return out^

    def image_registry(self, ctx: CellContext) -> String:
        var region = ctx.setting(String(SETTING_REGION))
        var project = ctx.setting(String(SETTING_PROJECT))
        var r = region.value().copy() if region else String("")
        var p = project.value().copy() if project else String("")
        return r + String("-docker.pkg.dev/") + p + String("/") + registry_name(ctx.scope.machine, ctx.scope.cell)

    def registry_login(mut self, creds: Creds) raises -> RegistryLogin:
        return RegistryLogin(String(REGISTRY_USER), self._s[].token.access_token())
