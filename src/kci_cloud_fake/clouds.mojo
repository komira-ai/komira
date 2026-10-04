# =============================================================================
# kci_cloud_fake/clouds.mojo: the two fake clouds (working, in memory; not mocks).
# =============================================================================
#
#   * `FakeCloud` ("fake")                  hosts every catalog type. It is the
#     executable specification of a complete cloud and the offline test
#     double for everything above the cloud module.
#   * `FakeLimitedCloud` ("fake-limited")   is DELIBERATELY PARTIAL: it does
#     not host `job` (NOT_YET by default; ABSENT_BY_DESIGN when built for a
#     catalog that marks `job` CLOUD_BOUND) and it has no public ingress, so a
#     `service` with a public URL is a shape it cannot host. It exists to
#     prove, with no real cloud, that a graph a cloud cannot host is refused,
#     in full, before anything is lowered or created.
#
# Both deploy into a `FakeStore` and lower identically, to DATA, with the
# COMPLETE fixed set of roles of each type (the closed world):
#   service -> `<id>/run`, `<id>/public` (wanted iff `public {}`), and
#              `<id>/uses/<target>` per `Uses` line
#   job     -> `<id>/run`, `<id>/schedule` (wanted iff scheduled), and the
#              same grants
# A run node's desired fields are EVERY field the catalog models, with the
# catalog's default filled in where the author wrote none (kci owns every
# modelled field: writing a default out is not a change, a console edit of
# one is drift). `env` and `secret_env` of a job included. Provenance is
# never a field.
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
    FIELD_JOB,
    FIELD_SERVICE,
    FINDING_CELL,
    FINDING_LIMIT,
    NOT_YET,
    V1_IMAGE_PLATFORM,
    decode_label_value,
    standard_identity_of,
    standard_label_rule,
)
from kci_resource_proto.resource import Image, Resource, SecretRef, Size, Value

from kci_cloud_fake.fake_store import FakeStore
from kci_cloud_fake.nodes import FakeNode


comptime FAKE_CITATION = "kci_cloud_fake: reference limits"
comptime JOB_TIMEOUT_MAX_SECONDS: Int = 86400
comptime REQUEST_TIMEOUT_MAX_SECONDS: Int = 3600

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
            refs.append(
                InputRef(rf.resource + String("/run"), rf.standard.value().json_name(), field)
            )
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


def _lower(r: Resource, mechanism: String) raises -> List[LoweredNode]:
    """The complete fixed set of roles of `r`, as data."""
    var out = List[LoweredNode]()
    var run = r.id + String("/run")
    var fields = List[Setting]()
    var refs = List[InputRef]()
    if r._oneof0_case == 1:
        ref svc = r.service.value()
        fields.append(Setting(String("img"), _image(svc.image)))
        var port = String(Int(svc.port)) if svc.port != 0 else String(DEFAULT_PORT)
        fields.append(Setting(String("port"), port^))
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
        fields.append(Setting(String("serves"), String("true")))
        out.append(LoweredNode(run, r.id, String("run"), List[String](), refs^, fields^))
        var pub = List[Setting]()
        pub.append(Setting(String("mechanism"), mechanism.copy()))
        var deps = List[String]()
        deps.append(run.copy())
        out.append(
            LoweredNode(
                r.id + String("/public"),
                r.id,
                String("public"),
                deps^,
                List[InputRef](),
                pub^,
                svc._oneof0_case == 1,
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
        fields.append(Setting(String("serves"), String("false")))
        out.append(LoweredNode(run, r.id, String("run"), List[String](), refs^, fields^))
        var sch = List[Setting]()
        var scheduled = job._oneof0_case == 2
        if scheduled:
            ref s = job.schedule.value()
            sch.append(Setting(String("cron"), s.cron.copy()))
            var tz = s.timezone.copy()
            if tz.byte_length() == 0:
                tz = String(DEFAULT_TIMEZONE)
            sch.append(Setting(String("tz"), tz^))
        var deps = List[String]()
        deps.append(run.copy())
        out.append(
            LoweredNode(
                r.id + String("/schedule"),
                r.id,
                String("schedule"),
                deps^,
                List[InputRef](),
                sch^,
                scheduled,
            )
        )
    for u in range(len(r.uses)):
        ref use = r.uses[u]
        var target = use.target.value().resource.copy()
        var g = List[Setting]()
        g.append(Setting(String("access"), use.access.json_name()))
        var deps = List[String]()
        deps.append(run.copy())
        deps.append(target + String("/run"))
        out.append(
            LoweredNode(
                r.id + String("/uses/") + target,
                r.id,
                String("grant"),
                deps^,
                List[InputRef](),
                g^,
            )
        )
    return out^


def _common_limits(r: Resource, mut out: List[Finding]):
    if r._oneof0_case == 1:
        ref svc = r.service.value()
        if Bool(svc.request_timeout) and Int(svc.request_timeout.value().seconds) > REQUEST_TIMEOUT_MAX_SECONDS:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("service.request_timeout"),
                    String("above this cloud's request limit of ")
                    + String(REQUEST_TIMEOUT_MAX_SECONDS)
                    + String("s"),
                    String(FAKE_CITATION),
                )
            )
        if (
            Bool(svc.scale)
            and Bool(svc.scale.value().min)
            and svc.scale.value().max < svc.scale.value().min.value()
        ):
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("service.scale"),
                    String("max is below min"),
                    String(FAKE_CITATION),
                )
            )
    elif r._oneof0_case == 2:
        ref job = r.job.value()
        if Bool(job.timeout) and Int(job.timeout.value().seconds) > JOB_TIMEOUT_MAX_SECONDS:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("job.timeout"),
                    String("above this cloud's job limit of ")
                    + String(JOB_TIMEOUT_MAX_SECONDS)
                    + String("s"),
                    String(FAKE_CITATION),
                )
            )


def _label(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return decode_label_value(labels[i].value)
    return String("")


def _owned(store: ArcPointer[FakeStore], scope: CellScope) -> List[OwnedRecord]:
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
    """The complete fake cloud."""

    var _id: String
    var _mechanism: String
    var _principal: String
    var store: ArcPointer[FakeStore]

    def __init__(
        out self,
        id: String = String("fake"),
        fail_at_call: Int = 0,
        read_lag: Int = 0,
        foreign: List[String] = List[String](),
    ):
        self._id = id
        self._mechanism = String("invoker")
        self._principal = String("")
        self.store = ArcPointer[FakeStore](FakeStore(fail_at_call, read_lag, foreign))

    def cloud_id(self) -> CloudId:
        return CloudId(self._id)

    def complete(self) -> Bool:
        return True

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        l.append(FIELD_JOB)
        return l^

    def absences(self) -> List[Absence]:
        return List[Absence]()

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

    def check(self, r: Resource) -> List[Finding]:
        var out = List[Finding]()
        _common_limits(r, out)
        return out^

    def required_artifact(self, r: Resource) -> ArtifactNeed:
        return ArtifactNeed(String("oci-image"), String(V1_IMAGE_PLATFORM))

    def lower(self, r: Resource) raises -> List[LoweredNode]:
        return _lower(r, self._mechanism)

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
    """The deliberately partial fake cloud: no `job`, no public ingress.

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

    def check(self, r: Resource) -> List[Finding]:
        var out = List[Finding]()
        _common_limits(r, out)
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

    def lower(self, r: Resource) raises -> List[LoweredNode]:
        return _lower(r, String(""))

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
