# =============================================================================
# kci_cloud_fake/clouds.mojo: the two fake clouds (working, in memory; not mocks).
# =============================================================================
#
#   * `FakeCloud` ("fake")                  hosts every catalog type. It is the
#     executable specification of a complete cloud and the offline test
#     double for everything above the cloud module.
#   * `FakeLimitedCloud` ("fake-limited")   is DELIBERATELY PARTIAL: it does
#     not host `job` (NOT_YET by default; ABSENT_BY_DESIGN when built for a
#     catalog that marks `job` CLOUD_BOUND), `table`, `bucket`,
#     `service_account`, `grant`, `queue`, `topic` nor `subscription`
#     (NOT_YET), and it has no public ingress,
#     so a
#     `service` with a public URL is a shape it cannot host. It exists to
#     prove, with no real cloud, that a graph a cloud cannot host is refused,
#     in full, before anything is lowered or created.
#
# Both deploy into a `FakeStore` and lower, to DATA, with the COMPLETE fixed
# set of roles of each type (the closed world). On the generic shape:
#   service -> `<id>/identity` (wanted iff no `run_as`), `<id>/run`,
#              `<id>/public` (wanted iff `public {}`), and one grant per edge
#   job     -> `<id>/identity`, `<id>/run`, `<id>/schedule` (wanted iff
#              scheduled), and the same grants
#   table   -> `<id>/table` (data.mojo; it holds no identity, so no grants)
#   bucket  -> `<id>/bucket` (it holds no identity, so no grants)
#   queue, topic, subscription -> `<id>/queue`, `<id>/topic`, `<id>/sub`
#              (messaging.mojo, from kci's feeds; no identity, no grants)
#   service account -> `<id>/identity` (it exposes NAME), and its grants
#   grant   -> `<id>/grant`
# The grants are kci's EDGES (`kci_cloud.grants`), handed to `lower` with
# each target's type: a `uses` line, the implicit `cell LOGS WRITE` of an
# identity the resource holds itself, or a grant resource. An edge lowers to
# `<id>/<role>` (`u-<h>` or `grant`), depends on its principal's identity
# node and on its target, and has the desired fields principal, target (or
# cell) and access. A dependency or a value on another resource is written
# as that resource's id alone: kci resolves it to the resource's primary
# node (`run`, `bucket`, `identity`), so this lowering never reads another
# resource. A service or a job with `run_as` turns its private identity off,
# its run depends on the account, and its run has the field `run_as`.
# `FakeCloud` built with a provider shape (`shapes.mojo`: `aws`, `gcp`,
# `azure`, `onprem`) lowers to THAT shape's fixed roles and provider kinds
# instead: on the azure shape a public ingress and a schedule folded into the
# run node; on the onprem shape a `<id>/vault` beside each identity, a
# service's `<id>/endpoint` (always wanted; the public role depends on it), a
# schedule folded into the run node, a grant's helper `r-<h>` (the
# Kubernetes Role a RoleBinding binds) where its row names one, and a cell
# edge folded into the identity as the field `cell.<NAME>`; on the gcp shape
# a table's indexes and TTL policy as nodes of their own, and a queue as a
# pull subscription (its private topic, its subscription turned off); on the
# aws shape a queue's policy. A shape's NOT_YET types (onprem: `table`,
# `queue`, `topic`, `subscription`) are the cloud's absences, and such a
# cloud is not complete. `list_owned` reports a table object's stored key
# (`OwnedRecord.key`) and the validation run that created the object (its
# `kci-run-id` label, `OwnedRecord.validation_run_id`), both read back from
# the object.
# A run node's desired fields are EVERY field the catalog models, with the
# catalog's default filled in where the author wrote none (kci owns every
# modelled field: writing a default out is not a change, a console edit of
# one is drift). `env` and `secret_env` of a job included; a bucket's expiry
# (`never` when unset), versioning and tier (`STANDARD` when unset); a
# table's key, indexes and TTL (`none` when unset).
# Provenance is never a field, and neither is retention: kci sets it on the
# lowered node, and the node carries it as the `kci-retention` mark.
#
# THE CELL'S SETTINGS (`configure`): `public_mechanism` (`invoker` or
# `gateway`, default `invoker`; `none` chooses none, and validate then
# refuses a public service) and `principal` (the only deploy identity
# `trust_check` accepts; unset accepts any). fake-limited takes `principal` only.
#
# The id each answers to is a constructor argument (default "fake" /
# "fake-limited") so the conformance kit can run them under a random id and
# catch any code that keyed on the spelling. `fail_at_call`, `read_lag` and
# `foreign` build the faulty variant (see `FakeStore`).
#
# ⚠ The limits below are the FAKE clouds' own, chosen to be
# exercisable; they cite this package, not any real cloud.
# =============================================================================

from std.memory import ArcPointer

from kci_reconciler import (
    CellScope,
    Creds,
    ErasedResource,
    InputRef,
    Label,
    OwnerStamp,
    LABEL_CELL,
    LABEL_MACHINE,
    LABEL_RESOURCE,
    LABEL_ROLE,
)
from kci_cloud import (
    ABSENT_BY_DESIGN,
    Absence,
    ArtifactNeed,
    BootstrapItem,
    CellContext,
    ConformanceTarget,
    Finding,
    CloudId,
    LoweredNode,
    OwnedRecord,
    Principal,
    RUN_UNKNOWN,
    Setting,
    FIELD_BUCKET,
    FIELD_GRANT,
    FIELD_JOB,
    FIELD_QUEUE,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    FINDING_CELL,
    FINDING_LIMIT,
    NOT_YET,
    V1_IMAGE_PLATFORM,
    Feed,
    GrantEdge,
    body_field,
    holds_own_identity,
    run_as_of,
    decode_label_value,
    retained_by,
    standard_identity_of,
    standard_label_rule,
    validation_run_of,
)
from kci_resource_proto.resource import Image, Resource, SecretRef, Size, Value

from kci_cloud_fake.data import lower_bucket, lower_table
from kci_cloud_fake.fake_store import FakeStore
from kci_cloud_fake.messaging import lower_queue, lower_subscription, lower_topic, messaging_limits
from kci_cloud_fake.limits import (
    FAKE_CITATION,
    common_limits,
    fold_limits,
    index_limits,
)
from kci_cloud_fake.nodes import FakeNode, live_key
from kci_cloud_fake.shapes import (
    ProviderShape,
    ROLE_BUCKET,
    ROLE_ENDPOINT,
    ROLE_IDENTITY,
    ROLE_PUBLIC,
    ROLE_RUN,
    ROLE_SCHEDULE,
    ROLE_VAULT,
    helper_role,
)



# The catalog's defaults, rendered (a default written out is not a change).
comptime DEFAULT_PORT = "8080"
comptime DEFAULT_SIZE = "1000m/512MB"
comptime DEFAULT_SCALE = "0..10"
comptime DEFAULT_REQUEST_TIMEOUT = "60s0n"
comptime DEFAULT_JOB_TIMEOUT = "600s0n"
comptime DEFAULT_RETRIES = "0"
comptime DEFAULT_TIMEZONE = "UTC"


def _image(img: Optional[Image]) -> String:
    """The digest and the platform (OS + CPU; empty is the default, so it
    renders as that default and writing it out is not a change)."""
    if not img:
        return String("")
    var d = String("")
    if img.value()._oneof0_case == 2:
        d = img.value().digest.value().copy()
    var p = img.value().platform.copy()
    if p.byte_length() == 0:
        p = String(V1_IMAGE_PLATFORM)
    return d + String("@") + p


def _size(s: Optional[Size]) -> String:
    if not s:
        return String(DEFAULT_SIZE)
    return String(Int(s.value().cpu_millis)) + String("m/") + String(Int(s.value().memory_mb)) + String("MB")


def _sorted(var keys: List[String]) -> List[String]:
    for i in range(1, len(keys)):
        var k = i
        while k > 0 and keys[k] < keys[k - 1]:
            var t = keys[k].copy()
            keys[k] = keys[k - 1].copy()
            keys[k - 1] = t^
            k -= 1
    return keys^


def _env(
    kind: String,
    env: Dict[String, Value],
    mut fields: List[Setting],
    mut refs: List[InputRef],
) raises:
    """`env` in key order: literals as fields, references appended to `refs`
    (their values are bound at apply time, never rendered here)."""
    var keys = List[String]()
    for entry in env.items():
        keys.append(entry.key.copy())
    var sorted = _sorted(keys^)
    for i in range(len(sorted)):
        ref v = env[sorted[i]]
        var field = kind + String(".env.") + sorted[i]
        if v._oneof0_case == 3:
            ref rf = v.ref_.value()
            # The producer by its resource id: kci resolves its primary node.
            refs.append(InputRef(rf.resource.copy(), rf.standard.value().json_name(), field))
        else:
            fields.append(Setting(field, v.literal.value()))


def _secret_env(kind: String, secrets: Dict[String, SecretRef], mut fields: List[Setting]):
    """`secret_env` in key order, as REFERENCES (store, name, version); a
    secret value is never in kci's memory, so it is never in a digest."""
    var keys = List[String]()
    for entry in secrets.items():
        keys.append(entry.key.copy())
    var sorted = _sorted(keys^)
    for i in range(len(sorted)):
        try:
            ref ref_ = secrets[sorted[i]]
            var s = String("")
            if ref_.store:
                s += ref_.store.value() + String("/")
            s += ref_.name
            if ref_.version:
                s += String("@") + ref_.version.value()
            fields.append(Setting(kind + String(".secret_env.") + sorted[i], s^))
        except:
            pass


def _duration(seconds: Int, nanos: Int) -> String:
    return String(seconds) + String("s") + String(nanos) + String("n")


def _identity(r: Resource, field: Int, shape: ProviderShape, own: Bool) raises -> List[LoweredNode]:
    """`<id>/identity` (wanted iff the resource holds its own identity) and,
    where the shape has one, its `<id>/vault` helper. A service account's
    identity exposes NAME (`account`, how the node behaves, not state)."""
    var out = List[LoweredNode]()
    var ident = r.id + String("/") + String(ROLE_IDENTITY)
    var fields = List[Setting]()
    if field == FIELD_SERVICE_ACCOUNT:
        fields.append(Setting(String("account"), String("true")))
    out.append(
        LoweredNode(
            ident.copy(),
            r.id,
            shape.kind_of(field, String(ROLE_IDENTITY)),
            List[String](),
            List[InputRef](),
            fields^,
            own,
        )
    )
    if shape.has(field, String(ROLE_VAULT)):
        var deps = List[String]()
        deps.append(ident^)
        out.append(
            LoweredNode(
                r.id + String("/") + String(ROLE_VAULT),
                r.id,
                shape.kind_of(field, String(ROLE_VAULT)),
                deps^,
                List[InputRef](),
                List[Setting](),
                own,
            )
        )
    return out^


def _edge_fields(e: GrantEdge, with_principal: Bool) -> List[Setting]:
    var g = List[Setting]()
    if with_principal:
        g.append(Setting(String("principal"), e.principal.copy()))
    if e.on_cell():
        g.append(Setting(String("cell"), e.cell.copy()))
    else:
        g.append(Setting(String("target"), e.target.copy()))
    g.append(Setting(String("access"), e.access.copy()))
    return g^


def _lower_edges(
    r: Resource, edges: List[GrantEdge], shape: ProviderShape, mut out: List[LoweredNode]
) raises:
    """One grant per edge, by the shape's row for the target's type: the
    binding (and its helper, where the row names one), or FOLDED into the
    identity it is for when the shape has no row."""
    for i in range(len(edges)):
        ref e = edges[i]
        var row = shape.grant_row(e.target_field)
        if not row:
            var ident = r.id + String("/") + String(ROLE_IDENTITY)
            var at = -1
            for k in range(len(out)):
                if out[k].id == ident:
                    at = k
            if not e.on_cell() or e.principal != r.id or at < 0:
                raise Error(
                    String("fake: shape \"")
                    + shape.name
                    + String("\" folds this edge of \"")
                    + r.id
                    + String("\" into an identity it does not hold; validate refuses it")
                )
            out[at].desired.append(Setting(String("cell.") + e.cell, e.access.copy()))
            continue
        var deps = List[String]()
        deps.append(e.principal_node())
        if not e.on_cell():
            # The target by its resource id: kci resolves its primary node.
            deps.append(e.target.copy())
        if row.value().helper.byte_length() > 0:
            var hid = r.id + String("/") + helper_role(e.role)
            var hdeps = List[String]()
            if not e.on_cell():
                hdeps.append(e.target.copy())
            out.append(
                LoweredNode(
                    hid.copy(), r.id, row.value().helper.copy(), hdeps^, List[InputRef](), _edge_fields(e, False)
                )
            )
            deps.append(hid^)
        out.append(
            LoweredNode(
                r.id + String("/") + e.role,
                r.id,
                row.value().kind.copy(),
                deps^,
                List[InputRef](),
                _edge_fields(e, True),
            )
        )


def _lower(
    r: Resource, edges: List[GrantEdge], feeds: List[Feed], mechanism: String, shape: ProviderShape
) raises -> List[LoweredNode]:
    """The complete fixed set of roles of `r` on `shape`, as data."""
    var field = body_field(r)
    if field == FIELD_BUCKET:
        return lower_bucket(r, shape)
    if field == FIELD_TABLE:
        return lower_table(r, shape)
    if field == FIELD_QUEUE:
        return lower_queue(r, feeds, shape)
    if field == FIELD_TOPIC:
        return lower_topic(r, shape)
    if field == FIELD_SUBSCRIPTION:
        return lower_subscription(r, shape)
    var out = List[LoweredNode]()
    if field == FIELD_GRANT:
        _lower_edges(r, edges, shape, out)
        return out^
    var own = holds_own_identity(r)
    out.extend(_identity(r, field, shape, own))
    if field == FIELD_SERVICE_ACCOUNT:
        _lower_edges(r, edges, shape, out)
        return out^
    var run = r.id + String("/run")
    var run_deps = List[String]()
    var account = run_as_of(r)
    if own:
        run_deps.append(r.id + String("/") + String(ROLE_IDENTITY))
    else:
        # The account by its resource id: kci resolves it to its identity.
        run_deps.append(account.copy())
    var run_kind = shape.kind_of(field, String(ROLE_RUN))
    var fields = List[Setting]()
    var refs = List[InputRef]()
    if r._oneof0_case == 1:
        ref svc = r.service.value()
        fields.append(Setting(String("img"), _image(svc.image)))
        var port = String(Int(svc.port)) if svc.port != 0 else String(DEFAULT_PORT)
        fields.append(Setting(String("port"), port.copy()))
        for i in range(len(svc.args)):
            fields.append(Setting(String("arg"), svc.args[i].copy()))
        _env(String("service"), svc.env, fields, refs)
        _secret_env(String("service"), svc.secret_env, fields)
        fields.append(Setting(String("size"), _size(svc.size)))
        var scale = String(DEFAULT_SCALE)
        if svc.scale:
            var lo = String("0")
            if svc.scale.value().min:
                lo = String(Int(svc.scale.value().min.value()))
            scale = lo + String("..") + String(Int(svc.scale.value().max))
        fields.append(Setting(String("scale"), scale^))
        fields.append(Setting(String("health"), svc.health_path.copy()))
        var timeout = String(DEFAULT_REQUEST_TIMEOUT)
        if svc.request_timeout:
            timeout = _duration(
                Int(svc.request_timeout.value().seconds), Int(svc.request_timeout.value().nanos)
            )
        fields.append(Setting(String("timeout"), timeout^))
        fields.append(Setting(String("concurrency"), String(Int(svc.max_concurrency))))
        var public = svc._oneof0_case == 1
        var has_public = shape.has(FIELD_SERVICE, String(ROLE_PUBLIC))
        if not has_public:
            # Folded: the ingress is a setting of the run object.
            fields.append(
                Setting(String("ingress"), mechanism.copy() if public else String("none"))
            )
        if not own:
            fields.append(Setting(String("run_as"), account.copy()))
        fields.append(Setting(String("serves"), String("true")))
        out.append(LoweredNode(run, r.id, run_kind, run_deps^, refs^, fields^))
        # What the public role fronts: the run, or the endpoint in front of it.
        var front = run.copy()
        if shape.has(FIELD_SERVICE, String(ROLE_ENDPOINT)):
            var ep = List[Setting]()
            ep.append(Setting(String("port"), port.copy()))
            var ep_deps = List[String]()
            ep_deps.append(run.copy())
            front = r.id + String("/") + String(ROLE_ENDPOINT)
            out.append(
                LoweredNode(
                    front.copy(),
                    r.id,
                    shape.kind_of(FIELD_SERVICE, String(ROLE_ENDPOINT)),
                    ep_deps^,
                    List[InputRef](),
                    ep^,
                )
            )
        if has_public:
            var pub = List[Setting]()
            pub.append(Setting(String("mechanism"), mechanism.copy()))
            var deps = List[String]()
            deps.append(front.copy())
            out.append(
                LoweredNode(
                    r.id + String("/") + String(ROLE_PUBLIC),
                    r.id,
                    shape.kind_of(FIELD_SERVICE, String(ROLE_PUBLIC)),
                    deps^,
                    List[InputRef](),
                    pub^,
                    public,
                )
            )
    else:
        ref job = r.job.value()
        fields.append(Setting(String("img"), _image(job.image)))
        for i in range(len(job.args)):
            fields.append(Setting(String("arg"), job.args[i].copy()))
        _env(String("job"), job.env, fields, refs)
        _secret_env(String("job"), job.secret_env, fields)
        fields.append(Setting(String("size"), _size(job.size)))
        var retries = String(DEFAULT_RETRIES)
        if job.max_retries:
            retries = String(Int(job.max_retries.value()))
        fields.append(Setting(String("retries"), retries^))
        var timeout = String(DEFAULT_JOB_TIMEOUT)
        if job.timeout:
            timeout = _duration(Int(job.timeout.value().seconds), Int(job.timeout.value().nanos))
        fields.append(Setting(String("timeout"), timeout^))
        var sch = List[Setting]()
        var scheduled = job._oneof0_case == 2
        if scheduled:
            ref s = job.schedule.value()
            sch.append(Setting(String("cron"), s.cron.copy()))
            var tz = s.timezone.copy()
            if tz.byte_length() == 0:
                tz = String(DEFAULT_TIMEZONE)
            sch.append(Setting(String("tz"), tz^))
        var has_schedule = shape.has(FIELD_JOB, String(ROLE_SCHEDULE))
        if not has_schedule:
            # Folded: the schedule is the run object's own trigger.
            fields.append(
                Setting(String("trigger"), String("schedule") if scheduled else String("on-demand"))
            )
            for i in range(len(sch)):
                fields.append(Setting(String("trigger.") + sch[i].key, sch[i].value.copy()))
        if not own:
            fields.append(Setting(String("run_as"), account.copy()))
        fields.append(Setting(String("serves"), String("false")))
        out.append(LoweredNode(run, r.id, run_kind, run_deps^, refs^, fields^))
        if has_schedule:
            var deps = List[String]()
            deps.append(run.copy())
            out.append(
                LoweredNode(
                    r.id + String("/") + String(ROLE_SCHEDULE),
                    r.id,
                    shape.kind_of(FIELD_JOB, String(ROLE_SCHEDULE)),
                    deps^,
                    List[InputRef](),
                    sch^,
                    scheduled,
                )
            )
    _lower_edges(r, edges, shape, out)
    return out^


def _label(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return decode_label_value(labels[i].value)
    return String("")


def _owned(store: ArcPointer[FakeStore], scope: CellScope) raises -> List[OwnedRecord]:
    """Every object whose stamp names this machine and cell (true state: a
    list, not a lagging read)."""
    var out = List[OwnedRecord]()
    ref s = store[]
    for i in range(len(s.ids)):
        ref labels = s.labels[i]
        if standard_identity_of(labels).byte_length() == 0:
            continue
        if _label(labels, String(LABEL_MACHINE)) != scope.machine:
            continue
        if _label(labels, String(LABEL_CELL)) != scope.cell:
            continue
        var run = String(RUN_UNKNOWN)
        var note = s.annotations[i].copy()
        var at = note.find("@")
        if at > 0:
            run = String(note[byte=0:at])
        var node = _label(labels, String(LABEL_RESOURCE)) + String("/") + _label(labels, String(LABEL_ROLE))
        out.append(
            OwnedRecord(
                s.kinds[i].copy(),
                s.ids[i].copy(),
                String("fake"),
                String("none"),
                String(s.created[i]),
                run^,
                True,
                node^,
                retained_by(labels),
                live_key(s.digests[i]),
                validation_run_of(labels),
            )
        )
    return out^


def _bootstrap(machine: String, cell: String) -> List[BootstrapItem]:
    var l = List[BootstrapItem]()
    l.append(
        BootstrapItem(
            String("state-store"),
            machine + String("-") + cell + String("-ledger"),
            String("the cell's ledger; created first, so the rest is recorded in it"),
        )
    )
    l.append(
        BootstrapItem(
            String("registry"),
            machine + String("-") + cell + String("-images"),
            String("where the cell pulls images by digest"),
        )
    )
    return l^


def _trust_findings(principal: String, creds: Creds) -> List[Finding]:
    var out = List[Finding]()
    if principal.byte_length() > 0 and creds.token != principal:
        out.append(
            Finding(
                FINDING_CELL,
                String("(cell)"),
                String("trust"),
                String("the deploy identity is \"")
                + creds.token
                + String("\", not the cell's principal \"")
                + principal
                + String("\""),
            )
        )
    return out^


def _setting_finding(key: String, why: String) -> Finding:
    return Finding(FINDING_CELL, String("(cell)"), String("settings.") + key, why)


struct FakeCloud(ConformanceTarget, Movable):
    """The complete fake cloud. `shape` is the provider shape it lowers to
    (`ProviderShape.generic()` by default: the fake's own roles); the shaped
    fakes are this cloud built with `aws`, `gcp`, `azure` or `onprem`."""

    var _id: String
    var _mechanism: String
    var _principal: String
    var _shape: ProviderShape
    var store: ArcPointer[FakeStore]

    def __init__(
        out self,
        id: String = String("fake"),
        fail_at_call: Int = 0,
        read_lag: Int = 0,
        foreign: List[String] = List[String](),
        shape: ProviderShape = ProviderShape.generic(),
    ):
        self._id = id
        self._shape = shape.copy()
        self._mechanism = String("invoker")
        self._principal = String("")
        self.store = ArcPointer[FakeStore](FakeStore(fail_at_call, read_lag, foreign))

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return len(self._shape.not_yet) == 0

    def implemented(self) -> List[Int]:
        var all = List[Int]()
        all.append(FIELD_SERVICE)
        all.append(FIELD_JOB)
        all.append(FIELD_TABLE)
        all.append(FIELD_BUCKET)
        all.append(FIELD_SERVICE_ACCOUNT)
        all.append(FIELD_GRANT)
        all.append(FIELD_QUEUE)
        all.append(FIELD_TOPIC)
        all.append(FIELD_SUBSCRIPTION)
        var l = List[Int]()
        for i in range(len(all)):
            if self._shape.hosts(all[i]):
                l.append(all[i])
        return l^

    def absences(self) -> List[Absence]:
        return self._shape.not_yet.copy()

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        var out = List[Finding]()
        self._mechanism = String("invoker")
        self._principal = String("")
        for i in range(len(ctx.settings)):
            ref st = ctx.settings[i]
            if st.key == "public_mechanism":
                if st.value == "invoker" or st.value == "gateway":
                    self._mechanism = st.value.copy()
                elif st.value == "none":
                    self._mechanism = String("")
                else:
                    out.append(
                        _setting_finding(
                            st.key,
                            String("\"") + st.value + String("\" is not invoker, gateway or none"),
                        )
                    )
            elif st.key == "principal":
                self._principal = st.value.copy()
            else:
                out.append(_setting_finding(st.key, String("not a setting of this cloud")))
        return out^

    def public_mechanism(self) -> String:
        return self._mechanism.copy()

    def check(self, r: Resource, feeds: List[Feed]) -> List[Finding]:
        var out = List[Finding]()
        common_limits(r, out)
        fold_limits(r, self._shape, self._id, out)
        index_limits(r, self._shape, self._id, out)
        messaging_limits(r, feeds, self._shape, self._id, out)
        return out^

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String(V1_IMAGE_PLATFORM))

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed]) raises -> List[LoweredNode]:
        return _lower(r, edges, feeds, self._mechanism, self._shape)

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        return ErasedResource.erase(FakeNode(self.store, node))

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return _bootstrap(machine, cell)

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return _owned(self.store, scope)

    def whoami(mut self, creds: Creds) raises -> Principal:
        var who = creds.token.copy()
        if who.byte_length() == 0:
            who = String("fake-anonymous")
        return Principal(who^, String("fake:") + self._id)

    def trust_render(self, scope: CellScope) -> String:
        var who = self._principal.copy()
        if who.byte_length() == 0:
            who = String("any caller")
        return (
            String("cloud \"")
            + self._id
            + String("\": cell ")
            + scope.cell
            + String(" of ")
            + scope.machine
            + String(" is deployed by ")
            + who
        )

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return _trust_findings(self._principal, creds)

    def live_count(self) -> Int:
        return len(self.store[].ids)

    def mutations(self) -> Int:
        return len(self.store[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.store[].tamper(logical_id)

    def tamper_unmodelled(mut self, logical_id: String) raises:
        self.store[].tamper_unmodelled(logical_id)

    def unmodelled(self, logical_id: String) -> String:
        var i = self.store[].find(logical_id)
        if i < 0:
            return String("")
        return self.store[].extras[i].copy()

    def fail(mut self, logical_id: String) raises:
        self.store[].fail(logical_id)

    def live_labels(self, logical_id: String) -> List[Label]:
        var i = self.store[].find(logical_id)
        if i < 0:
            return List[Label]()
        return self.store[].labels[i].copy()

    def plant_foreign(mut self, logical_id: String) raises:
        self.store[].plant(logical_id, String("foreign"))

    def race_next_create(mut self):
        self.store[].race_next()

    def raced(self) -> String:
        return self.store[].raced_id.copy()

    def creates_of(self, logical_id: String) -> Int:
        return self.store[].creates_of(logical_id)


struct FakeLimitedCloud(ConformanceTarget, Movable):
    """The deliberately partial fake cloud: no `job`, no `bucket`, no
    `service_account`, no `grant` (NOT_YET), no public ingress.

    `job_absence` is how it declares the missing `job`: NOT_YET (the default,
    for the v1 catalog, where `job` is PORTABLE) or ABSENT_BY_DESIGN (for a
    catalog that marks `job` CLOUD_BOUND, which is how the early refusal of a
    cloud-bound shape is tested before the catalog has one)."""

    var _id: String
    var _job_absence: Int
    var _principal: String
    var store: ArcPointer[FakeStore]

    def __init__(
        out self,
        id: String = String("fake-limited"),
        job_absence: Int = NOT_YET,
        fail_at_call: Int = 0,
        read_lag: Int = 0,
        foreign: List[String] = List[String](),
    ):
        self._id = id
        self._job_absence = job_absence
        self._principal = String("")
        self.store = ArcPointer[FakeStore](FakeStore(fail_at_call, read_lag, foreign))

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return False

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        return l^

    def absences(self) -> List[Absence]:
        var l = List[Absence]()
        if self._job_absence == ABSENT_BY_DESIGN:
            l.append(
                Absence(FIELD_JOB, ABSENT_BY_DESIGN, String("fake-limited will never run jobs"))
            )
        else:
            l.append(
                Absence(FIELD_JOB, NOT_YET, String("fake-limited has no run-to-completion runner"))
            )
        l.append(Absence(FIELD_TABLE, NOT_YET, String("fake-limited has no tables")))
        l.append(Absence(FIELD_BUCKET, NOT_YET, String("fake-limited has no object store")))
        l.append(
            Absence(FIELD_SERVICE_ACCOUNT, NOT_YET, String("fake-limited has no shared identities"))
        )
        l.append(Absence(FIELD_GRANT, NOT_YET, String("fake-limited has no standalone grants")))
        for f in [FIELD_QUEUE, FIELD_TOPIC, FIELD_SUBSCRIPTION]:
            l.append(Absence(f, NOT_YET, String("fake-limited has no messaging")))
        return l^

    def configure(mut self, ctx: CellContext) -> List[Finding]:
        var out = List[Finding]()
        self._principal = String("")
        for i in range(len(ctx.settings)):
            ref st = ctx.settings[i]
            if st.key == "principal":
                self._principal = st.value.copy()
            elif st.key == "public_mechanism":
                out.append(
                    _setting_finding(st.key, String("fake-limited has no public ingress to choose"))
                )
            else:
                out.append(_setting_finding(st.key, String("not a setting of this cloud")))
        return out^

    def public_mechanism(self) -> String:
        return String("")

    def check(self, r: Resource, feeds: List[Feed]) -> List[Finding]:
        var out = List[Finding]()
        common_limits(r, out)
        if r._oneof0_case == 1 and r.service.value()._oneof0_case == 1:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("service.public"),
                    String("fake-limited has no public ingress; it hosts internal services only"),
                    String(FAKE_CITATION),
                )
            )
        return out^

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String(V1_IMAGE_PLATFORM))

    def lower(self, r: Resource, edges: List[GrantEdge], feeds: List[Feed]) raises -> List[LoweredNode]:
        return _lower(r, edges, feeds, String(""), ProviderShape.generic())

    def realize(mut self, node: LoweredNode) raises -> ErasedResource:
        return ErasedResource.erase(FakeNode(self.store, node))

    def bootstrap_resources(self, machine: String, cell: String) -> List[BootstrapItem]:
        return _bootstrap(machine, cell)

    def label_rule(self, stamp: OwnerStamp) raises -> List[Label]:
        return standard_label_rule(stamp)

    def identity_of(self, labels: List[Label]) -> String:
        return standard_identity_of(labels)

    def list_owned(mut self, creds: Creds, scope: CellScope) raises -> List[OwnedRecord]:
        return _owned(self.store, scope)

    def whoami(mut self, creds: Creds) raises -> Principal:
        var who = creds.token.copy()
        if who.byte_length() == 0:
            who = String("fake-anonymous")
        return Principal(who^, String("fake:") + self._id)

    def trust_render(self, scope: CellScope) -> String:
        var who = self._principal.copy()
        if who.byte_length() == 0:
            who = String("any caller")
        return (
            String("cloud \"")
            + self._id
            + String("\": cell ")
            + scope.cell
            + String(" of ")
            + scope.machine
            + String(" is deployed by ")
            + who
        )

    def trust_check(mut self, creds: Creds, scope: CellScope) raises -> List[Finding]:
        return _trust_findings(self._principal, creds)

    def live_count(self) -> Int:
        return len(self.store[].ids)

    def mutations(self) -> Int:
        return len(self.store[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.store[].tamper(logical_id)

    def tamper_unmodelled(mut self, logical_id: String) raises:
        self.store[].tamper_unmodelled(logical_id)

    def unmodelled(self, logical_id: String) -> String:
        var i = self.store[].find(logical_id)
        if i < 0:
            return String("")
        return self.store[].extras[i].copy()

    def fail(mut self, logical_id: String) raises:
        self.store[].fail(logical_id)

    def live_labels(self, logical_id: String) -> List[Label]:
        var i = self.store[].find(logical_id)
        if i < 0:
            return List[Label]()
        return self.store[].labels[i].copy()

    def plant_foreign(mut self, logical_id: String) raises:
        self.store[].plant(logical_id, String("foreign"))

    def race_next_create(mut self):
        self.store[].race_next()

    def raced(self) -> String:
        return self.store[].raced_id.copy()

    def creates_of(self, logical_id: String) -> Int:
        return self.store[].creates_of(logical_id)
