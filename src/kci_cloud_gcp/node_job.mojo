# =============================================================================
# kci_cloud_gcp/node_job.mojo: a container job's run node, a Cloud Run job.
# =============================================================================
#
# A job takes labels, so it carries kci's stamp as labels (the standard
# rule), beside the author's.
#   * create (`create_owned`): ONE CreateJob carrying the whole job
#     (job_model.mojo) and every label a create writes (the identity, the
#     run id under a validation run, the retention mark) plus the author's:
#     the job is born stamped.
#   * update: ONE UpdateJob of the whole job; its labels are the job's own
#     (every label kci was not handed is kept, the adoption mark and a run id
#     included) with the retention mark rewritten and the author's set.
#   * adopt (`adopt_owned`): ONE UpdateJob of the job as it stands, with
#     kci's labels replaced by the identity, the retention mark and, on a
#     node kci marked adopted, the adoption mark. Never a run id.
#   * delete: DeleteJob; a job already gone is a no-op.
# A label kci did not write and the file does not name is an unmanaged
# difference: reported, never changed.
# =============================================================================

from std.memory import ArcPointer

from kci_cloud import (
    LoweredNode,
    adoption_labels,
    create_labels,
    is_kci_label_key,
    retain_labels,
    retention_label_key,
    standard_identity_of,
    standard_label_rule,
)
from kci_reconciler import (
    CONVERGE_IN_PLACE,
    ChangeAction,
    Creds,
    InputRef,
    Label,
    OwnerStamp,
    Resource as EngineResource,
    ResolvedInputs,
    ResourceStatus,
    unbound_error,
)
from komira_gcp_core import GcpTokenSource
from komira_retry import Sleeper
from komira_gcp_run.job import Job
from komira_http_core.transport.io_stream import Connector
from komira_proto_codec import decode_json
from komira_proto_codec.codec import encode_json

from kci_cloud_gcp.job_model import (
    LABEL_FIELD,
    ModelField,
    author_labels,
    desired_model,
    job_json,
    job_labels,
    live_model,
    model_digest,
    parse_job,
)
from kci_cloud_gcp.names import account_email, derived_name, last_segment
from kci_cloud_gcp.node_account import plan_verb
from kci_cloud_gcp.session import GcpSession


def merged_labels(have: List[Label], retention: Int, authors: List[Label]) raises -> List[Label]:
    """`have` with the retention mark set to `retention`'s and each author
    label set; every other label kept, in its order."""
    var mark = retention_label_key()
    var out = List[Label]()
    for i in range(len(have)):
        if have[i].key == mark:
            continue
        var authored = False
        for k in range(len(authors)):
            if authors[k].key == have[i].key:
                authored = True
        if not authored:
            out.append(have[i].copy())
    out.extend(retain_labels(retention))
    out.extend(authors.copy())
    return out^


def unmanaged_labels(have: List[Label], authors: List[Label]) -> String:
    """Every label of `have` that is neither kci's nor the author's."""
    var out = String("")
    for i in range(len(have)):
        if is_kci_label_key(have[i].key):
            continue
        var authored = False
        for k in range(len(authors)):
            if authors[k].key == have[i].key:
                authored = True
        if authored:
            continue
        if out.byte_length() > 0:
            out += String("; ")
        out += String("label ") + have[i].key + String("=") + have[i].value + String(" (not modelled; left as it is)")
    return out^


def labels_dict(labels: List[Label]) -> Dict[String, String]:
    var d = Dict[String, String]()
    for i in range(len(labels)):
        d[labels[i].key] = labels[i].value.copy()
    return d^


def without_kci(job: Job) -> List[Label]:
    """A typed job's labels that are not kci's."""
    var out = List[Label]()
    for entry in job.labels.items():
        if not is_kci_label_key(entry.key):
            out.append(Label(entry.key.copy(), entry.value.copy()))
    return out^


struct GcpJobNode[C: Connector, TS: GcpTokenSource, S: Sleeper](EngineResource, Movable, Deinitable):
    """A container job's run node (the file header)."""

    var _s: ArcPointer[GcpSession[Self.C, Self.TS, Self.S]]
    var _node: LoweredNode
    var _name: String
    var _bound: List[String]
    var _is_bound: Bool

    def __init__(out self, s: ArcPointer[GcpSession[Self.C, Self.TS, Self.S]], node: LoweredNode, name: String):
        self._s = s.copy()
        self._node = node.copy()
        self._name = name
        self._bound = List[String]()
        self._is_bound = len(node.inputs) == 0

    def _sa_email(self) -> String:
        """The identity the job runs as: the account node it depends on
        first (its own identity, or its run_as account's)."""
        var identity = self._node.depends_on[0].copy() if len(self._node.depends_on) > 0 else String("")
        var account = self._s[].name_of_node(identity)
        if account.byte_length() == 0:
            account = derived_name(self._s[].machine, self._s[].cell, identity)
        return account_email(account, self._s[].project)

    def _model(self) raises -> List[ModelField]:
        if not self._is_bound:
            raise unbound_error(self._node.id, self._node.inputs[0])
        return desired_model(self._node, self._bound, self._sa_email(), self._node.retention)

    def logical_id(mut self) -> String:
        return self._node.id.copy()

    def depends_on(mut self) -> List[String]:
        return self._node.depends_on.copy()

    def retention(mut self) -> Int:
        return self._node.retention

    def owner(mut self) -> String:
        return self._node.owner.copy()

    def wanted(mut self) -> Bool:
        return self._node.wanted

    def stamps_ownership(mut self) -> Bool:
        return True

    def input_refs(mut self) -> List[InputRef]:
        return self._node.inputs.copy()

    def bind_inputs(mut self, resolved: ResolvedInputs) raises:
        var vals = List[String]()
        for i in range(len(self._node.inputs)):
            vals.append(resolved.value_of(self._node.id, self._node.inputs[i].producer, self._node.inputs[i].output))
        self._bound = vals^
        self._is_bound = True

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var found = self._s[].get_job(self._name)
        if not found:
            return ResourceStatus.absent()
        var doc = parse_job(encode_json(found.value()))
        var labels = job_labels(doc)
        var stamp = standard_identity_of(labels)
        var pid = found.value().name.copy()
        if not self._is_bound:
            # A presence read: with no bound inputs there is no desired
            # state to compare.
            return ResourceStatus.drifted(pid, String(""), String(""), String(""), stamp, String(""))
        var want = self._model()
        var live = live_model(doc, want)
        var extra = unmanaged_labels(labels, author_labels(want))
        var live_digest = model_digest(self._node.kind, live)
        if live_digest == model_digest(self._node.kind, want):
            return ResourceStatus.matched(pid, live_digest, String(""), String(""), stamp, extra)
        return ResourceStatus.drifted(pid, live_digest, String(""), String(""), stamp, extra)

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        var found = self._s[].get_job(self._name)
        if not found:
            return ResourceStatus.absent()
        var labels = job_labels(parse_job(encode_json(found.value())))
        return ResourceStatus.drifted(found.value().name, String(""), String(""), String(""), standard_identity_of(labels))

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return plan_verb(self._node.id, live, self._node.retention)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": a job is created only in an owned scope, with its stamp"))

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        var model = self._model()
        var labels = create_labels(stamp, self._node.retention)
        labels.extend(author_labels(model))
        self._s[].create_job(last_segment(self._name), job_json(model, labels))
        return self._name.copy()

    def update(mut self, creds: Creds) raises:
        var found = self._s[].get_job(self._name)
        if not found:
            raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": the job to update is gone"))
        var model = self._model()
        var labels = merged_labels(job_labels(parse_job(encode_json(found.value()))), self._node.retention, author_labels(model))
        self._s[].update_job(decode_json[Job](job_json(model, labels, self._name)))

    def adopt_owned(mut self, stamp: OwnerStamp, physical_id: String, creds: Creds) raises:
        var found = self._s[].get_job(physical_id)
        if not found:
            raise Error(String("kci_cloud_gcp: ") + self._node.id + String(": the job to adopt is gone"))
        var job = found.value().copy()
        # No run id: this run did not create the job.
        var labels = without_kci(job)
        labels.extend(standard_label_rule(stamp))
        labels.extend(retain_labels(self._node.retention))
        labels.extend(adoption_labels(self._node.adopted))
        job.labels = labels_dict(labels)
        self._s[].update_job(job^)

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._s[].delete_job(physical_id)

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE
