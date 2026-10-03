# =============================================================================
# kci_cloud_mem/clouds.mojo: the two in-memory reference clouds.
# =============================================================================
#
#   * `MemCloud` ("mem")           hosts every catalog type. It is the
#     executable specification of a complete cloud and the offline test
#     double for everything above the cloud module.
#   * `MemLiteCloud` ("mem-lite")  is a PARTIAL cloud: it does not host
#     `job` (NOT_YET by default; ABSENT_BY_DESIGN when built for a catalog
#     that marks `job` CLOUD_BOUND) and it has no public ingress, so a
#     `service` with a public URL is a shape it cannot host. It exists to
#     prove, with no real cloud, that a graph a cloud cannot host is refused,
#     in full, before anything is lowered or created.
#
# Both deploy into a `MemStore` and lower identically:
#   service -> `<id>/run` (+ `<id>/uses/<target>` per `Uses` line)
#   job     -> `<id>/run` (+ the same grants)
# A run node's desired digest renders EVERY field the catalog models (kci
# owns every modelled field): a change to any of them, `env` and
# `secret_env` of a job included, is an update.
#
# The id each answers to is a constructor argument (default "mem" /
# "mem-lite") so the conformance kit can run them under a random id and
# catch any code that keyed on the spelling. `fail_at_call` builds the
# faulty variant (see `MemStore`).
#
# ⚠ The limits below are the REFERENCE clouds' own, chosen to be
# exercisable; they cite this package, not any real cloud.
# =============================================================================

from std.memory import ArcPointer

from kci_reconciler import ErasedResource, InputRef, ResourceGraph
from kci_cloud import (
    ABSENT_BY_DESIGN,
    Absence,
    ConformanceTarget,
    Finding,
    CloudId,
    FIELD_JOB,
    FIELD_SERVICE,
    FINDING_LIMIT,
    NOT_YET,
)
from kci_resource_proto.resource import Image, Resource, SecretRef, Size, Value

from kci_cloud_mem.mem_store import MemStore
from kci_cloud_mem.nodes import MemGrantNode, MemRunNode


comptime MEM_CITATION = "kci_cloud_mem: reference limits"
comptime JOB_TIMEOUT_MAX_SECONDS: Int = 86400
comptime REQUEST_TIMEOUT_MAX_SECONDS: Int = 3600


def _image(img: Optional[Image]) -> String:
    """The digest and the platform (OS + CPU; empty is the v1 default, so it
    renders as that default and writing it out is not a change)."""
    if not img:
        return String("")
    var d = String("")
    if img.value()._oneof0_case == 2:
        d = img.value().digest.value().copy()
    var p = img.value().platform.copy()
    if p.byte_length() == 0:
        p = String("linux/amd64")
    return d + String("@") + p


def _size(s: Optional[Size]) -> String:
    if not s:
        return String("-")
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
    kind: String, env: Dict[String, Value], mut refs: List[InputRef]
) raises -> String:
    """`env` in key order: literals rendered, references appended to `refs`
    (their values are bound at apply time, never rendered here)."""
    var s = String("")
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
            s += String("|") + field + String("=") + v.literal.value()
    return s^


def _secret_env(kind: String, secrets: Dict[String, SecretRef]) -> String:
    """`secret_env` in key order, as REFERENCES (store, name, version); a
    secret value is never in kci's memory, so it is never in a digest."""
    var s = String("")
    var keys = List[String]()
    for entry in secrets.items():
        keys.append(entry.key.copy())
    var sorted = _sorted(keys^)
    for i in range(len(sorted)):
        try:
            ref ref_ = secrets[sorted[i]]
            s += String("|") + kind + String(".secret_env.") + sorted[i] + String("=")
            if ref_.store:
                s += ref_.store.value() + String("/")
            s += ref_.name
            if ref_.version:
                s += String("@") + ref_.version.value()
        except:
            pass
    return s^


def _static_of(r: Resource, mut refs: List[InputRef]) raises -> String:
    """The canonical rendering of everything the author set, minus the
    referenced values, which are appended to `refs` in a stable order."""
    var s = String("")
    if r._oneof0_case == 1:
        ref svc = r.service.value()
        s = String("service|img=") + _image(svc.image)
        s += String("|port=") + String(Int(svc.port))
        for i in range(len(svc.args)):
            s += String("|arg=") + svc.args[i]
        s += _env(String("service"), svc.env, refs)
        s += _secret_env(String("service"), svc.secret_env)
        s += String("|size=") + _size(svc.size)
        if svc.scale:
            s += String("|scale=")
            if svc.scale.value().min:
                s += String(Int(svc.scale.value().min.value()))
            s += String("..") + String(Int(svc.scale.value().max))
        s += String("|health=") + svc.health_path
        if svc.request_timeout:
            s += String("|timeout=") + String(Int(svc.request_timeout.value().seconds))
            s += String("s") + String(Int(svc.request_timeout.value().nanos)) + String("n")
        s += String("|concurrency=") + String(Int(svc.max_concurrency))
        s += String("|exposure=") + String(svc._oneof0_case)
        return s^
    ref job = r.job.value()
    s = String("job|img=") + _image(job.image)
    for i in range(len(job.args)):
        s += String("|arg=") + job.args[i]
    s += _env(String("job"), job.env, refs)
    s += _secret_env(String("job"), job.secret_env)
    s += String("|size=") + _size(job.size)
    if job.max_retries:
        s += String("|retries=") + String(Int(job.max_retries.value()))
    if job.timeout:
        s += String("|timeout=") + String(Int(job.timeout.value().seconds))
        s += String("s") + String(Int(job.timeout.value().nanos)) + String("n")
    if job._oneof0_case == 2:
        ref sch = job.schedule.value()
        s += String("|cron=") + sch.cron + String("|tz=") + sch.timezone
    else:
        s += String("|on-demand")
    return s^


def _lower(store: ArcPointer[MemStore], r: Resource, mut graph: ResourceGraph) raises:
    var refs = List[InputRef]()
    var static = _static_of(r, refs)
    graph.add(ErasedResource.erase(MemRunNode(store, r.id, static, r._oneof0_case == 1, refs^)))
    for u in range(len(r.uses)):
        ref use = r.uses[u]
        graph.add(
            ErasedResource.erase(
                MemGrantNode(store, r.id, use.target.value().resource, use.access.json_name())
            )
        )


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
                    String(MEM_CITATION),
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
                    String(MEM_CITATION),
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
                    String(MEM_CITATION),
                )
            )


struct MemCloud(ConformanceTarget, Movable):
    """The complete in-memory cloud."""

    var _id: String
    var store: ArcPointer[MemStore]

    def __init__(out self, id: String = String("mem"), fail_at_call: Int = 0):
        self._id = id
        self.store = ArcPointer[MemStore](MemStore(fail_at_call))

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

    def check(self, r: Resource) -> List[Finding]:
        var out = List[Finding]()
        _common_limits(r, out)
        return out^

    def lower(mut self, r: Resource, mut graph: ResourceGraph) raises:
        _lower(self.store, r, graph)

    def live_count(self) -> Int:
        return len(self.store[].ids)

    def mutations(self) -> Int:
        return len(self.store[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.store[].tamper(logical_id)

    def fail(mut self, logical_id: String) raises:
        self.store[].fail(logical_id)


struct MemLiteCloud(ConformanceTarget, Movable):
    """The partial in-memory cloud: no `job`, no public ingress.

    `job_absence` is how it declares the missing `job`: NOT_YET (the default,
    for the v1 catalog, where `job` is PORTABLE) or ABSENT_BY_DESIGN (for a
    catalog that marks `job` CLOUD_BOUND, which is how the early refusal of a
    cloud-bound shape is tested before the catalog has one)."""

    var _id: String
    var _job_absence: Int
    var store: ArcPointer[MemStore]

    def __init__(
        out self,
        id: String = String("mem-lite"),
        job_absence: Int = NOT_YET,
        fail_at_call: Int = 0,
    ):
        self._id = id
        self._job_absence = job_absence
        self.store = ArcPointer[MemStore](MemStore(fail_at_call))

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
                Absence(FIELD_JOB, ABSENT_BY_DESIGN, String("mem-lite will never run jobs"))
            )
        else:
            l.append(
                Absence(FIELD_JOB, NOT_YET, String("mem-lite has no run-to-completion runner"))
            )
        return l^

    def check(self, r: Resource) -> List[Finding]:
        var out = List[Finding]()
        _common_limits(r, out)
        if r._oneof0_case == 1 and r.service.value()._oneof0_case == 1:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("service.public"),
                    String("mem-lite has no public ingress; it hosts internal services only"),
                    String(MEM_CITATION),
                )
            )
        return out^

    def lower(mut self, r: Resource, mut graph: ResourceGraph) raises:
        _lower(self.store, r, graph)

    def live_count(self) -> Int:
        return len(self.store[].ids)

    def mutations(self) -> Int:
        return len(self.store[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.store[].tamper(logical_id)

    def fail(mut self, logical_id: String) raises:
        self.store[].fail(logical_id)
