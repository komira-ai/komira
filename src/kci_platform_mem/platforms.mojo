# =============================================================================
# kci_platform_mem/platforms.mojo: the two in-memory reference platforms.
# =============================================================================
#
#   * `MemPlatform` ("mem")           hosts every catalog type. It is the
#     executable specification of a complete platform and the offline test
#     double for everything above the platform seam.
#   * `MemLitePlatform` ("mem-lite")  is a PARTIAL platform: it does not host
#     `job` (NOT_YET) and it has no public ingress, so a `service` with a
#     public URL is a shape it cannot host. It exists to prove, with no cloud,
#     that a graph a platform cannot host is refused, in full, before anything
#     is lowered or created.
#
# Both deploy into a `MemCloud` and lower identically:
#   service -> `<id>/run` (+ `<id>/uses/<target>` per `Uses` line)
#   job     -> `<id>/run` (+ the same grants)
#
# The id each answers to is a constructor argument (default "mem" /
# "mem-lite") so the conformance kit can run them under a random id and
# catch any code that keyed on the spelling.
#
# ⚠ The limits below are the REFERENCE platforms' own, chosen to be
# exercisable; they cite this package, not any real platform.
# =============================================================================

from std.memory import ArcPointer

from kci_iac import ErasedResource, InputRef, ResourceGraph
from kci_platform import (
    Absence,
    ConformanceTarget,
    Finding,
    PlatformId,
    FIELD_JOB,
    FIELD_SERVICE,
    FINDING_LIMIT,
    NOT_YET,
)
from kci_resource_proto.resource import Image, Resource, Size

from kci_platform_mem.mem_cloud import MemCloud
from kci_platform_mem.nodes import MemGrantNode, MemRunNode


comptime MEM_CITATION = "kci_platform_mem: reference limits"
comptime JOB_TIMEOUT_MAX_SECONDS: Int = 86400
comptime REQUEST_TIMEOUT_MAX_SECONDS: Int = 3600


def _image(img: Optional[Image]) -> String:
    if Bool(img) and img.value()._oneof0_case == 2:
        return img.value().digest.value().copy()
    return String("")


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
        var keys = List[String]()
        for entry in svc.env.items():
            keys.append(entry.key.copy())
        var sorted = _sorted(keys^)
        for i in range(len(sorted)):
            ref v = svc.env[sorted[i]]
            var field = String("service.env.") + sorted[i]
            if v._oneof0_case == 3:
                ref rf = v.ref_.value()
                refs.append(
                    InputRef(rf.resource + String("/run"), rf.standard.value().json_name(), field)
                )
            else:
                s += String("|") + field + String("=") + v.literal.value()
        s += String("|size=") + _size(svc.size)
        if svc.scale:
            s += String("|scale=") + String(Int(svc.scale.value().min)) + String("..")
            s += String(Int(svc.scale.value().max))
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
    s += String("|size=") + _size(job.size)
    s += String("|retries=") + String(Int(job.max_retries))
    if job.timeout:
        s += String("|timeout=") + String(Int(job.timeout.value().seconds))
        s += String("s") + String(Int(job.timeout.value().nanos)) + String("n")
    if job._oneof0_case == 2:
        ref sch = job.schedule.value()
        s += String("|cron=") + sch.cron + String("|tz=") + sch.timezone
    else:
        s += String("|on-demand")
    return s^


def _lower(cloud: ArcPointer[MemCloud], r: Resource, mut graph: ResourceGraph) raises:
    var refs = List[InputRef]()
    var static = _static_of(r, refs)
    graph.add(ErasedResource.erase(MemRunNode(cloud, r.id, static, r._oneof0_case == 1, refs^)))
    for u in range(len(r.uses)):
        ref use = r.uses[u]
        graph.add(
            ErasedResource.erase(
                MemGrantNode(cloud, r.id, use.target.value().resource, use.access.json_name())
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
                    String("above this platform's request limit of ")
                    + String(REQUEST_TIMEOUT_MAX_SECONDS)
                    + String("s"),
                    String(MEM_CITATION),
                )
            )
        if Bool(svc.scale) and svc.scale.value().max < svc.scale.value().min:
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
                    String("above this platform's job limit of ")
                    + String(JOB_TIMEOUT_MAX_SECONDS)
                    + String("s"),
                    String(MEM_CITATION),
                )
            )


struct MemPlatform(ConformanceTarget, Movable):
    """The complete in-memory platform."""

    var _id: String
    var cloud: ArcPointer[MemCloud]

    def __init__(out self, id: String = String("mem")):
        self._id = id
        self.cloud = ArcPointer[MemCloud](MemCloud())

    def platform_id(self) -> PlatformId:
        return PlatformId(self._id)

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
        _lower(self.cloud, r, graph)

    def live_count(self) -> Int:
        return len(self.cloud[].ids)

    def mutations(self) -> Int:
        return len(self.cloud[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.cloud[].tamper(logical_id)


struct MemLitePlatform(ConformanceTarget, Movable):
    """The partial in-memory platform: no `job`, no public ingress."""

    var _id: String
    var cloud: ArcPointer[MemCloud]

    def __init__(out self, id: String = String("mem-lite")):
        self._id = id
        self.cloud = ArcPointer[MemCloud](MemCloud())

    def platform_id(self) -> PlatformId:
        return PlatformId(self._id)

    def complete(self) -> Bool:
        return False

    def implemented(self) -> List[Int]:
        var l = List[Int]()
        l.append(FIELD_SERVICE)
        return l^

    def absences(self) -> List[Absence]:
        var l = List[Absence]()
        l.append(Absence(FIELD_JOB, NOT_YET, String("mem-lite has no run-to-completion runner")))
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
        _lower(self.cloud, r, graph)

    def live_count(self) -> Int:
        return len(self.cloud[].ids)

    def mutations(self) -> Int:
        return len(self.cloud[].calls)

    def tamper(mut self, logical_id: String) raises:
        self.cloud[].tamper(logical_id)
