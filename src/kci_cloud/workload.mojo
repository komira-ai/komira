# =============================================================================
# kci_cloud/workload.mojo: the three WORKLOAD types as one view.
# =============================================================================
#
# A workload is a container kci runs: a `service` (answers requests), a
# `container_job` (runs to completion each time it is started) or a
# `worker` (runs always, on a fixed number of instances). The three share
# their container fields (image, command, args, env, secret_env, size) and
# their identity (`run_as`: the account it runs as; unset, a private
# identity of its own). `workload_of` reads those shared fields into one
# value, `Workload`, so a rule or a lowering about them is written once and
# never branches on the type; what is a type's own (a service's port and
# exposure, a job's retries and timeout, a worker's replicas) is read from
# its own message.
#
# This file reads the catalog only: grants.mojo builds on it, and the rules
# of the shared fields are compute.mojo's.
# =============================================================================

from kci_resource_proto.compute import Size
from kci_resource_proto.refs import Image, Ref, SecretRef, Value
from kci_resource_proto.resource import Resource

from kci_cloud.catalog import FIELD_CONTAINER_JOB, FIELD_SERVICE, FIELD_WORKER, body_field


def is_workload(field: Int) -> Bool:
    """True for the body field of a service, a container job or a worker."""
    return field == FIELD_SERVICE or field == FIELD_CONTAINER_JOB or field == FIELD_WORKER


struct Workload(Copyable, Movable, Deinitable):
    """The container fields every workload has, read from its own message.
    `kind` is the type's arm name (`service`, `container_job`, `worker`),
    the first segment of every field path a rule reports."""

    var kind: String
    var image: Optional[Image]
    var command: List[String]
    var args: List[String]
    var env: Dict[String, Value]
    var secret_env: Dict[String, SecretRef]
    var size: Optional[Size]
    var run_as: Optional[Ref]

    def __init__(
        out self,
        kind: String,
        image: Optional[Image],
        command: List[String],
        args: List[String],
        env: Dict[String, Value],
        secret_env: Dict[String, SecretRef],
        size: Optional[Size],
        run_as: Optional[Ref],
    ):
        self.kind = kind
        self.image = image.copy()
        self.command = command.copy()
        self.args = args.copy()
        self.env = env.copy()
        self.secret_env = secret_env.copy()
        self.size = size.copy()
        self.run_as = run_as.copy()

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind.copy()
        self.image = copy.image.copy()
        self.command = copy.command.copy()
        self.args = copy.args.copy()
        self.env = copy.env.copy()
        self.secret_env = copy.secret_env.copy()
        self.size = copy.size.copy()
        self.run_as = copy.run_as.copy()

    def account(self) -> String:
        """The account `run_as` names, or empty for a private identity."""
        if self.run_as:
            return self.run_as.value().resource.copy()
        return String("")

    def gpus(self) -> Int:
        """GPUs per instance (`Size.gpus`); 0 with no size written."""
        if self.size:
            return Int(self.size.value().gpus)
        return 0


def workload_of(r: Resource) -> Optional[Workload]:
    """`r`'s container fields when it is a workload, else None (a resource
    with no type included)."""
    var f: Int
    try:
        f = body_field(r)
    except:
        return None
    if f == FIELD_SERVICE:
        ref s = r.service.value()
        return Workload(String("service"), s.image, s.command, s.args, s.env, s.secret_env, s.size, s.run_as)
    if f == FIELD_CONTAINER_JOB:
        ref j = r.container_job.value()
        return Workload(String("container_job"), j.image, j.command, j.args, j.env, j.secret_env, j.size, j.run_as)
    if f == FIELD_WORKER:
        ref w = r.worker.value()
        return Workload(String("worker"), w.image, w.command, w.args, w.env, w.secret_env, w.size, w.run_as)
    return None
