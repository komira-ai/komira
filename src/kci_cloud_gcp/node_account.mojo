# =============================================================================
# kci_cloud_gcp/node_account.mojo: an identity node, an IAM service account.
# =============================================================================
#
# A service account takes no labels: it is a DESCRIPTION CARRIER
# (kci_cloud/labels.mojo). Its description holds kci's lines and nothing
# else: the identity, the retention mark, and the run-id label of a create
# under a validation run (or the adoption mark of an adopted account).
#   * create (`create_owned`): ONE CreateServiceAccount carrying the display
#     name and the whole description, so the account is born stamped: a
#     create whose answer is lost leaves an account that is already kci's.
#   * update: ONE PatchServiceAccount of the display name and the
#     description; the description keeps every line the account holds (the
#     identity, a run id, the adoption mark) and rewrites the retention mark
#     to the node's.
#   * adopt (`adopt_owned`): ONE PatchServiceAccount of the description to
#     the identity, the retention mark and, on a node kci marked adopted,
#     the adoption mark. Never a run id: the run did not create the account.
#     It overwrites whatever description the account held (the description
#     is kci's whole).
#   * delete: DeleteServiceAccount; an account already gone is a no-op.
# The modelled state (the digest) is the display name, which kci owns (the
# node id, names.mojo), and the retention mark. The output NAME is the
# account's email, what a workload's environment reads.
# =============================================================================

from std.memory import ArcPointer

from kci_cloud import (
    LoweredNode,
    adoption_labels,
    create_labels,
    description_labels,
    description_lines,
    retain_labels,
    retention_label_key,
    retention_label_value,
    standard_identity_of,
    standard_label_rule,
)
from kci_reconciler import (
    CONVERGE_IN_PLACE,
    ChangeAction,
    Creds,
    Label,
    ModelledDigest,
    OwnerStamp,
    Outputs,
    Resource as EngineResource,
    ResourceStatus,
    VERB_CREATE,
    VERB_NOOP,
    VERB_UPDATE,
)
from komira_gcp_core import GcpTokenSource
from komira_http_core.transport.io_stream import Connector

from kci_cloud_gcp.names import display_name_of, last_segment
from kci_cloud_gcp.session import GcpSession


def plan_verb(id: String, live: ResourceStatus, retention: Int) -> ChangeAction:
    """The verb of a live status: absent creates, matched is a no-op, and
    anything else updates."""
    if live.is_absent():
        return ChangeAction(id, VERB_CREATE, String("absent -> create"), retention)
    if live.is_matched():
        return ChangeAction(id, VERB_NOOP, String("matched"), retention)
    return ChangeAction(id, VERB_UPDATE, String("drifted -> update"), retention)


def _mark(labels: List[Label]) raises -> String:
    var key = retention_label_key()
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return String("(none)")


def with_retention(labels: List[Label], retention: Int) raises -> List[Label]:
    """`labels` with the retention mark set to `retention`'s, every other
    label kept as it was."""
    var key = retention_label_key()
    var out = List[Label]()
    for i in range(len(labels)):
        if labels[i].key != key:
            out.append(labels[i].copy())
    out.extend(retain_labels(retention))
    return out^


struct GcpAccountNode[C: Connector, TS: GcpTokenSource](EngineResource, Movable, Deinitable):
    """An identity node (the file header)."""

    var _s: ArcPointer[GcpSession[Self.C, Self.TS]]
    var _id: String
    var _owner: String
    var _kind: String
    var _deps: List[String]
    var _wanted: Bool
    var _adopted: Bool
    var _retention: Int
    var _email: String

    def __init__(out self, s: ArcPointer[GcpSession[Self.C, Self.TS]], node: LoweredNode, email: String):
        self._s = s.copy()
        self._id = node.id.copy()
        self._owner = node.owner.copy()
        self._kind = node.kind.copy()
        self._deps = node.depends_on.copy()
        self._wanted = node.wanted
        self._adopted = node.adopted
        self._retention = node.retention
        self._email = email

    def _desired(self) raises -> String:
        var d = ModelledDigest(self._kind)
        d.field(String("display"), display_name_of(self._id))
        d.field(String("retention"), retention_label_value(self._retention))
        return d.text()

    def logical_id(mut self) -> String:
        return self._id.copy()

    def depends_on(mut self) -> List[String]:
        return self._deps.copy()

    def retention(mut self) -> Int:
        return self._retention

    def owner(mut self) -> String:
        return self._owner.copy()

    def wanted(mut self) -> Bool:
        return self._wanted

    def stamps_ownership(mut self) -> Bool:
        return True

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        var found = self._s[].get_account(self._email)
        if not found:
            return ResourceStatus.absent()
        ref sa = found.value()
        var labels = description_labels(sa.description)
        var stamp = standard_identity_of(labels)
        var d = ModelledDigest(self._kind)
        d.field(String("display"), sa.display_name)
        d.field(String("retention"), _mark(labels))
        var live = d.text()
        if live == self._desired():
            return ResourceStatus.matched(sa.name, live, String(""), String(""), stamp, String(""))
        return ResourceStatus.drifted(sa.name, live, String(""), String(""), stamp, String(""))

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        var found = self._s[].get_account(self._email)
        if not found:
            return ResourceStatus.absent()
        return ResourceStatus.drifted(
            found.value().name, String(""), String(""), String(""), standard_identity_of(description_labels(found.value().description))
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return plan_verb(self._id, live, self._retention)

    def create(mut self, creds: Creds) raises -> String:
        raise Error(String("kci_cloud_gcp: ") + self._id + String(": an account is created only in an owned scope, with its stamp"))

    def create_owned(mut self, stamp: OwnerStamp, creds: Creds) raises -> String:
        # The identity, the retention mark and the run id: the whole
        # description, in the one create call.
        var description = description_lines(create_labels(stamp, self._retention))
        var account_id = String(self._email[byte = 0 : self._email.find("@")])
        var sa = self._s[].create_account(account_id, display_name_of(self._id), description)
        return sa.name.copy()

    def update(mut self, creds: Creds) raises:
        var found = self._s[].get_account(self._email)
        if not found:
            raise Error(String("kci_cloud_gcp: ") + self._id + String(": the account to update is gone"))
        var labels = description_labels(found.value().description)
        if len(labels) == 0:
            raise Error(String("kci_cloud_gcp: ") + self._id + String(": the account carries no kci stamp to keep"))
        var description = description_lines(with_retention(labels, self._retention))
        self._s[].patch_account(self._email, display_name_of(self._id), description)

    def adopt_owned(mut self, stamp: OwnerStamp, physical_id: String, creds: Creds) raises:
        # No run id: this run did not create the account.
        var labels = standard_label_rule(stamp)
        labels.extend(retain_labels(self._retention))
        labels.extend(adoption_labels(self._adopted))
        self._s[].patch_account(last_segment(physical_id), None, description_lines(labels))

    def delete(mut self, physical_id: String, creds: Creds) raises:
        self._s[].delete_account(last_segment(physical_id))

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def outputs(mut self, physical_id: String, creds: Creds) raises -> Outputs:
        var o = Outputs()
        o.set(String("NAME"), self._email.copy())
        return o^
