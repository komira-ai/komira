# =============================================================================
# kci_cloud_fake/limits.mojo: the limits the fake clouds refuse (`check`).
# =============================================================================
#
# ⚠ These are the FAKE clouds' own limits, chosen to be exercisable; they cite
# this package, not any real cloud.
#   * a request timeout above 3600 s, a container job's timeout above
#     86400 s, and a service whose scale max is below its min (every fake
#     cloud);
#   * on a shape that folds a cell edge into the identity it is for, a cell
#     edge of another resource's identity (`fold_limits`);
#   * on a shape whose table indexes are objects named `ix-<h>`, two index
#     names whose roles collide (`index_limits`).
# The shape's compute limits (a GPU, a service scaling to zero) are
# workloads.mojo's.
# =============================================================================

from kci_cloud import (
    EDGE_TARGET_CELL,
    FIELD_CONTAINER_JOB,
    FIELD_SERVICE,
    FIELD_TABLE,
    FINDING_LIMIT,
    Finding,
    GrantEdge,
    body_is,
    edges_of,
    index_role,
    index_role_collisions,
)
from kci_resource_proto.resource import Resource

from kci_cloud_fake.shapes import ProviderShape, ROLE_INDEX


comptime FAKE_CITATION = "kci_cloud_fake: reference limits"
comptime JOB_TIMEOUT_MAX_SECONDS: Int = 86400
comptime REQUEST_TIMEOUT_MAX_SECONDS: Int = 3600


def fold_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """On a shape that folds a cell edge into the identity it is for, a cell
    edge whose identity is another resource's cannot be lowered."""
    if shape.grant_row(EDGE_TARGET_CELL):
        return
    var edges: List[GrantEdge]
    try:
        edges = edges_of(r)
    except:
        return  # a graph finding
    for i in range(len(edges)):
        ref e = edges[i]
        if not e.on_cell() or e.principal == r.id:
            continue
        var path = String("grant") if e.role == "grant" else String("uses[") + String(i) + String("]")
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                path,
                String("on cloud \"")
                + cloud
                + String("\" a grant to the cell's ")
                + e.cell
                + String(" is a setting of the identity it is for; write it on \"")
                + e.principal
                + String("\" itself"),
                String(FAKE_CITATION),
            )
        )


def index_limits(r: Resource, shape: ProviderShape, cloud: String, mut out: List[Finding]):
    """On a shape whose indexes are objects of their own, two index names
    whose `ix-<h>` roles collide cannot both be lowered."""
    if not shape.has(FIELD_TABLE, String(ROLE_INDEX)):
        return
    var clash = index_role_collisions(r)
    for i in range(len(clash)):
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("table.indexes"),
                String("on cloud \"")
                + cloud
                + String("\" each index is an object named by its role, and index \"")
                + clash[i]
                + String("\" has the role ")
                + index_role(clash[i])
                + String(" of an earlier index; rename one of them"),
                String(FAKE_CITATION),
            )
        )


def common_limits(r: Resource, mut out: List[Finding]):
    if body_is(r, FIELD_SERVICE):
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
    elif body_is(r, FIELD_CONTAINER_JOB):
        ref job = r.container_job.value()
        if Bool(job.timeout) and Int(job.timeout.value().seconds) > JOB_TIMEOUT_MAX_SECONDS:
            out.append(
                Finding(
                    FINDING_LIMIT,
                    r.id,
                    String("container_job.timeout"),
                    String("above this cloud's job limit of ")
                    + String(JOB_TIMEOUT_MAX_SECONDS)
                    + String("s"),
                    String(FAKE_CITATION),
                )
            )
