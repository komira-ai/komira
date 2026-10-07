# =============================================================================
# kci_cloud/compute.mojo: the rules of the WORKLOAD types (service, container
# job, worker).
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a
# workload (`workload_findings`), each at a field path under the type's arm
# (`service.image`, `container_job.command[0]`, `worker.replicas`):
#
#   * IMAGE: there is one, and it is a content digest by now (a build
#     output is substituted by the deploy facade before a cloud sees the
#     resource); its platform is written `<os>/<cpu>` (empty means
#     `linux/amd64`). Whether a cloud runs that platform is the cloud's
#     question (`CloudAdapter.required_artifact`, in validate).
#   * RUN_AS names a `service_account` of the list, and no output of it.
#   * ENV: every value is resolved and refers to an output its producer
#     exposes (values.mojo).
#   * COMMAND: when written, its first entry is the program to run, so it is
#     not empty (the entries after it are passed as written, empty ones
#     included). Unset, the image's own entrypoint runs.
#   * REPLICAS (a worker): when written, 1 or more. A worker runs always;
#     unset is the versioned default, 1.
# The `secret_env` rules are secrets.mojo's; the identity and grant rules
# (`uses`, a workload as a grant's principal) are validate's and
# grants.mojo's. GPUs (`Size.gpus`) have no graph rule: whether a cloud
# attaches one is that cloud's limit.
# =============================================================================

from kci_resource_proto.refs import Ref
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import Catalog, FIELD_SERVICE_ACCOUNT, body_field
from kci_cloud.values import check_value
from kci_cloud.workload import Workload, workload_of


comptime V1_IMAGE_PLATFORM = "linux/amd64"
"""What an empty `Image.platform` means (OS + CPU)."""

comptime WORKER_REPLICAS_DEFAULT: Int = 1
"""A worker's `replicas` while unset: the versioned default."""


def _index_of_id(resources: List[Resource], id: String) -> Int:
    for i in range(len(resources)):
        if resources[i].id == id:
            return i
    return -1


def image_platform(r: Resource) -> String:
    """The image platform of a workload, with the empty default filled in;
    empty when the resource is no workload or has no image."""
    var w = workload_of(r)
    if not w or not w.value().image:
        return String("")
    var p = w.value().image.value().platform.copy()
    if p.byte_length() == 0:
        return String(V1_IMAGE_PLATFORM)
    return p^


def worker_replicas(r: Resource) -> Int:
    """A worker's instance count, its versioned default (1) filled in while
    unset; 0 for any other type."""
    if not r.worker:
        return 0
    ref w = r.worker.value()
    if w.replicas:
        return Int(w.replicas.value())
    return WORKER_REPLICAS_DEFAULT


def _check_image(owner: String, w: Workload, mut out: List[Finding]):
    """An image must be a content digest by now, and its platform written
    `<os>/<cpu>`."""
    var path = w.kind + String(".image")
    var arm = 0
    if w.image:
        arm = w.image.value()._oneof0_case
        var platform = w.image.value().platform.copy()
        if platform.byte_length() > 0:
            var parts = platform.split("/")
            if len(parts) != 2 or parts[0].byte_length() == 0 or parts[1].byte_length() == 0:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        owner,
                        path + String(".platform"),
                        String("platform \"")
                        + platform
                        + String("\" is not <os>/<cpu> (for example ")
                        + String(V1_IMAGE_PLATFORM)
                        + String(")"),
                    )
                )
    if arm == 0:
        out.append(Finding(FINDING_GRAPH, owner, path, String("no image")))
    elif arm == 1:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("the image is a build output that was not resolved to a digest before deploy"),
            )
        )


def _check_run_as(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    r: Ref,
    mut out: List[Finding],
):
    """`run_as` names a service account of the list, and no output."""
    var p = _index_of_id(resources, r.resource)
    if p < 0:
        out.append(
            Finding(FINDING_GRAPH, owner, path, String("ref to missing resource \"") + r.resource + String("\""))
        )
        return
    if r._oneof0_case != 0:
        out.append(Finding(FINDING_GRAPH, owner, path, String("run_as names an identity, not one of its outputs")))
        return
    var field: Int
    try:
        field = body_field(resources[p])
    except:
        return  # the account's own missing type is reported on it
    if field != FIELD_SERVICE_ACCOUNT:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("run_as must name a service_account; \"")
                + r.resource
                + String("\" is a ")
                + catalog.name_of(field),
            )
        )


def workload_findings(catalog: Catalog, resources: List[Resource], r: Resource) -> List[Finding]:
    """Every graph finding of the workload `r` (file header), in order:
    image, run_as, env (in key order as written), command, replicas. Empty
    for any other type."""
    var out = List[Finding]()
    var found = workload_of(r)
    if not found:
        return out^
    ref w = found.value()
    _check_image(r.id, w, out)
    if w.run_as:
        _check_run_as(catalog, resources, r.id, w.kind + String(".run_as"), w.run_as.value(), out)
    for entry in w.env.items():
        check_value(catalog, resources, r.id, w.kind + String(".env.") + entry.key, entry.value, out)
    if len(w.command) > 0 and w.command[0].byte_length() == 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                w.kind + String(".command[0]"),
                String("the first entry of a command is the program to run, and it is empty"),
            )
        )
    if Bool(r.worker) and Bool(r.worker.value().replicas) and Int(r.worker.value().replicas.value()) == 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("worker.replicas"),
                String("a worker runs always, on 1 or more instances: 0 is never legal (unset means ")
                + String(WORKER_REPLICAS_DEFAULT)
                + String(")"),
            )
        )
    return out^
