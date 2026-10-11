# =============================================================================
# kci_cloud_fake/workloads.mojo: how the fake clouds lower and limit the
# WORKLOADS (service, container job, worker).
# =============================================================================
#
# A workload lowers to its identity (clouds.mojo: `<id>/identity`, and the
# onprem `<id>/vault` beside it), the nodes below (`lower_run`), and its
# grant edges (clouds.mojo). The nodes, by the shape's rows:
#   service       `<id>/run`, then `<id>/endpoint` where the shape has one
#                 (onprem: the in-cluster Service, always wanted), then
#                 `<id>/public` (wanted iff `public {}`), which fronts the
#                 endpoint or the run; a shape with no public row FOLDS the
#                 exposure into the run's field `ingress`.
#   container job `<id>/run`: the run-to-completion DEFINITION. A run of it
#                 is an execution, never a node. A schedule is a primitive
#                 of its own (triggers.mojo); on a shape that folds it into
#                 the job, the run also carries the schedule's `schedule`,
#                 `cron` and `timezone` (from kci's firing).
#   worker        `<id>/run`, always on, with its `replicas`. Where the shape
#                 has a `task` row (aws), the container is `<id>/task` and the
#                 run (the service that keeps `replicas` copies of it)
#                 depends on it.
# The run (or the task) depends on the identity it runs as: its own, or the
# `run_as` account by its resource id (kci resolves it to the account's
# identity node), and then carries the field `run_as`.
#
# A run's desired fields are EVERY field the catalog models, the catalog's
# versioned default written out where the author wrote none (kci owns every
# modelled field: writing a default out is not a change, a console edit of
# one is drift): `img` (digest@platform), `port` (a service), one `cmd` per
# command entry and one `arg` per argument (in order), `<arm>.env.<KEY>` and
# `<arm>.secret_env.<KEY>` in key order (a reference is an input, bound at
# apply time; so is a service's `network`, on its subnet's NAME), `size` (`<cpu>m/<memory>MB`, with `/<n>gpu` when GPUs are
# asked for), then a service's `scale`, `health`, `timeout` and
# `concurrency`, a job's `retries` and `timeout` (and a folded schedule), a
# worker's `replicas`.
#
# THE LIMITS (`workload_limits`), from the shape's data, never its name:
#   * a workload asking for a GPU (`Size.gpus` above 0) on a shape whose
#     `gpu_limit` says why it takes none;
#   * a service whose scale may reach zero (its `min` 0, written or by the
#     default `0..10`) on a shape whose `scale_to_zero_limit` says why a
#     service keeps one instance there (onprem, until Q21 is answered).
# ⚠ They are the FAKE clouds' own, chosen to be exercisable; they cite this
# package, not any real cloud.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud import (
    FIELD_CONTAINER_JOB,
    Firing,
    FIELD_SERVICE,
    FIELD_WORKER,
    FINDING_LIMIT,
    Finding,
    LoweredNode,
    Setting,
    V1_IMAGE_PLATFORM,
    Workload,
    body_field,
    body_is,
    worker_replicas,
    workload_of,
)
from kci_resource_proto.compute import Size
from kci_resource_proto.refs import Image, Value
from kci_resource_proto.resource import Resource

from kci_cloud_fake.limits import FAKE_CITATION
from kci_cloud_fake.network import network_input
from kci_cloud_fake.secrets import secret_env_fields
from kci_cloud_fake.triggers import folded_fields
from kci_cloud_fake.shapes import (
    ProviderShape,
    ROLE_ENDPOINT,
    ROLE_IDENTITY,
    ROLE_PUBLIC,
    ROLE_RUN,
    ROLE_TASK,
)


# The catalog's defaults, rendered (a default written out is not a change).
comptime DEFAULT_PORT = "8080"
comptime DEFAULT_SIZE = "1000m/512MB"
comptime DEFAULT_SCALE = "0..10"
comptime DEFAULT_REQUEST_TIMEOUT = "60s0n"
comptime DEFAULT_JOB_TIMEOUT = "600s0n"
comptime DEFAULT_RETRIES = "0"


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
    """`<cpu>m/<memory>MB`, and `/<n>gpu` when GPUs are asked for (so a size
    written before GPUs existed renders as it did)."""
    if not s:
        return String(DEFAULT_SIZE)
    var out = String(Int(s.value().cpu_millis)) + String("m/") + String(Int(s.value().memory_mb)) + String("MB")
    if s.value().gpus > 0:
        out += String("/") + String(Int(s.value().gpus)) + String("gpu")
    return out^


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


def _duration(seconds: Int, nanos: Int) -> String:
    return String(seconds) + String("s") + String(nanos) + String("n")


def _container(
    w: Workload, port: String, mut fields: List[Setting], mut refs: List[InputRef]
) raises:
    """The container fields every workload has: image, (a service's port),
    command, args, env, secret_env, size."""
    fields.append(Setting(String("img"), _image(w.image)))
    if port.byte_length() > 0:
        fields.append(Setting(String("port"), port))
    for i in range(len(w.command)):
        fields.append(Setting(String("cmd"), w.command[i].copy()))
    for i in range(len(w.args)):
        fields.append(Setting(String("arg"), w.args[i].copy()))
    _env(w.kind, w.env, fields, refs)
    secret_env_fields(w.kind, w.secret_env, fields, refs)
    fields.append(Setting(String("size"), _size(w.size)))


def _service_scale(r: Resource) -> String:
    """A service's scale as `<min>..<max>`, the default `0..10` while unset;
    an unwritten `min` is 0."""
    ref svc = r.service.value()
    if not svc.scale:
        return String(DEFAULT_SCALE)
    var lo = String("0")
    if svc.scale.value().min:
        lo = String(Int(svc.scale.value().min.value()))
    return lo + String("..") + String(Int(svc.scale.value().max))


def _service_min(r: Resource) -> Int:
    """The fewest instances a service may run: its scale's `min`, 0 while
    unset (the default scale starts at 0)."""
    ref svc = r.service.value()
    if Bool(svc.scale) and Bool(svc.scale.value().min):
        return Int(svc.scale.value().min.value())
    return 0


def lower_run(
    r: Resource, own: Bool, mechanism: String, shape: ProviderShape, firings: List[Firing]
) raises -> List[LoweredNode]:
    """The nodes of the workload `r` after its identity (file header), as
    data. `own`: `r` runs as its own identity (else as its `run_as`
    account). `mechanism`: the cell's public mechanism, for a service's
    public role or its folded ingress. `firings`: kci's, for a schedule a
    shape folds into a container job."""
    var found = workload_of(r)
    if not found:
        raise Error(String("fake: resource \"") + r.id + String("\" is not a workload"))
    ref w = found.value()
    var field = body_field(r)
    var out = List[LoweredNode]()
    var run = r.id + String("/") + String(ROLE_RUN)
    var run_deps = List[String]()
    var account = w.account()
    if own:
        run_deps.append(r.id + String("/") + String(ROLE_IDENTITY))
    else:
        # The account by its resource id: kci resolves it to its identity.
        run_deps.append(account.copy())
    var run_kind = shape.kind_of(field, String(ROLE_RUN))
    var fields = List[Setting]()
    var refs = List[InputRef]()
    if field == FIELD_SERVICE:
        ref svc = r.service.value()
        var port = String(Int(svc.port)) if svc.port != 0 else String(DEFAULT_PORT)
        _container(w, port, fields, refs)
        network_input(r, refs)
        fields.append(Setting(String("scale"), _service_scale(r)))
        fields.append(Setting(String("health"), svc.health_path.copy()))
        var timeout = String(DEFAULT_REQUEST_TIMEOUT)
        if svc.request_timeout:
            timeout = _duration(Int(svc.request_timeout.value().seconds), Int(svc.request_timeout.value().nanos))
        fields.append(Setting(String("timeout"), timeout^))
        fields.append(Setting(String("concurrency"), String(Int(svc.max_concurrency))))
        var public = svc._oneof0_case == 1
        var has_public = shape.has(FIELD_SERVICE, String(ROLE_PUBLIC))
        if not has_public:
            # Folded: the ingress is a setting of the run object.
            fields.append(Setting(String("ingress"), mechanism.copy() if public else String("none")))
        if not own:
            fields.append(Setting(String("run_as"), account.copy()))
        fields.append(Setting(String("serves"), String("true")))
        out.append(LoweredNode(run.copy(), r.id, run_kind, run_deps^, refs^, fields^))
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
        return out^
    _container(w, String(""), fields, refs)
    if field == FIELD_CONTAINER_JOB:
        ref job = r.container_job.value()
        var retries = String(DEFAULT_RETRIES)
        if job.max_retries:
            retries = String(Int(job.max_retries.value()))
        fields.append(Setting(String("retries"), retries^))
        var timeout = String(DEFAULT_JOB_TIMEOUT)
        if job.timeout:
            timeout = _duration(Int(job.timeout.value().seconds), Int(job.timeout.value().nanos))
        fields.append(Setting(String("timeout"), timeout^))
        folded_fields(r, firings, shape, fields)
        if not own:
            fields.append(Setting(String("run_as"), account.copy()))
        fields.append(Setting(String("serves"), String("false")))
        out.append(LoweredNode(run, r.id, run_kind, run_deps^, refs^, fields^))
        return out^
    # A worker: always on, `replicas` copies of its container.
    var replicas = Setting(String("replicas"), String(worker_replicas(r)))
    if shape.has(FIELD_WORKER, String(ROLE_TASK)):
        # The container is an object of its own; the run keeps its copies.
        var task = r.id + String("/") + String(ROLE_TASK)
        if not own:
            fields.append(Setting(String("run_as"), account.copy()))
        out.append(
            LoweredNode(task.copy(), r.id, shape.kind_of(FIELD_WORKER, String(ROLE_TASK)), run_deps^, refs^, fields^)
        )
        var keep = List[Setting]()
        keep.append(replicas^)
        keep.append(Setting(String("serves"), String("false")))
        var deps = List[String]()
        deps.append(task^)
        out.append(LoweredNode(run, r.id, run_kind, deps^, List[InputRef](), keep^))
        return out^
    fields.append(replicas^)
    if not own:
        fields.append(Setting(String("run_as"), account.copy()))
    fields.append(Setting(String("serves"), String("false")))
    out.append(LoweredNode(run, r.id, run_kind, run_deps^, refs^, fields^))
    return out^


def workload_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """The shape's compute limits (file header) on the workload `r`; nothing
    for any other type."""
    var found = workload_of(r)
    if not found:
        return
    ref w = found.value()
    if w.gpus() > 0 and shape.gpu_limit.byte_length() > 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                w.kind + String(".size.gpus"),
                String("on cloud \"") + cloud + String("\" a workload cannot ask for a GPU: ") + shape.gpu_limit,
                String(FAKE_CITATION),
            )
        )
    if body_is(r, FIELD_SERVICE) and shape.scale_to_zero_limit.byte_length() > 0 and _service_min(r) == 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("service.scale.min"),
                String("on cloud \"")
                + cloud
                + String("\" a service cannot scale to zero: ")
                + shape.scale_to_zero_limit
                + String("; write scale.min 1 or more"),
                String(FAKE_CITATION),
            )
        )
