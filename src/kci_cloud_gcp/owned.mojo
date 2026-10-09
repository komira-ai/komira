# =============================================================================
# kci_cloud_gcp/owned.mojo: `list_owned`, what the cell's project says is
# this cell's.
# =============================================================================
#
#   * every service account whose description reads as a stamp of this
#     machine and cell (kci_cloud/labels.mojo, a description carrier);
#   * every Cloud Run job of the cell's region whose labels carry such a
#     stamp;
#   * every member binding on the policy of an account just found, and on
#     the project's policy, that kci_cloud's attribution gives to this
#     machine and cell (derived.mojo; G4's role table): its node is the
#     derived one, its retention and run id its member's. A binding nobody
#     attributes is not listed (an unmanaged difference, never removed).
# Each record's `name` is the object's name when the author chose it (it is
# not the derived name of its node, names.mojo), else empty. The session
# keeps every record's physical id by node, so a node realized only to be
# removed finds its object.
# =============================================================================

from kci_cloud import (
    BindingEnd,
    OwnedRecord,
    RUN_UNKNOWN,
    adopted_by,
    attribute,
    decode_label_value,
    description_labels,
    retained_by,
    standard_identity_of,
    validation_run_of,
)
from kci_reconciler import CellScope, LABEL_CELL, LABEL_MACHINE, LABEL_RESOURCE, LABEL_ROLE, Label
from komira_gcp_core import GcpTokenSource
from komira_http_core.transport.io_stream import Connector
from komira_proto_codec.codec import encode_json

from kci_cloud_gcp.job_model import job_labels, parse_job
from kci_cloud_gcp.names import (
    KIND_ACCOUNT,
    KIND_BINDING,
    KIND_JOB,
    derived_name,
    email_of_member,
    gcp_role_table,
    last_segment,
    project_resource,
)
from kci_cloud_gcp.node_binding import AccountLabels, binding_key
from kci_cloud_gcp.session import GcpSession, PolicyEntry


def _label(labels: List[Label], key: String) -> String:
    for i in range(len(labels)):
        if labels[i].key == key:
            return decode_label_value(labels[i].value)
    return String("")


def stamped_node(labels: List[Label], scope: CellScope) -> String:
    """The node a stamp of `scope`'s machine and cell names, or empty for
    labels carrying no stamp or another cell's."""
    if standard_identity_of(labels).byte_length() == 0:
        return String("")
    if _label(labels, String(LABEL_MACHINE)) != scope.machine or _label(labels, String(LABEL_CELL)) != scope.cell:
        return String("")
    var role = _label(labels, String(LABEL_ROLE))
    var resource = _label(labels, String(LABEL_RESOURCE))
    if role.byte_length() == 0:
        return resource^
    return resource + String("/") + role


def _bindings(
    mut out: List[OwnedRecord],
    mut nodes: List[String],
    mut ids: List[String],
    labels: AccountLabels,
    entries: List[PolicyEntry],
    resource: String,
    on_project: Bool,
    target_labels: List[Label],
    scope: CellScope,
) raises:
    var rows = gcp_role_table()
    for i in range(len(entries)):
        ref e = entries[i]
        if e.conditional:
            continue
        var email = email_of_member(e.member)
        if email.byte_length() == 0:
            continue
        var d = attribute(
            on_project,
            BindingEnd(String(KIND_ACCOUNT), target_labels.copy()),
            False,
            BindingEnd(String(KIND_ACCOUNT), labels.of(email)),
            e.role,
            rows,
        )
        if not d:
            continue
        ref ds = d.value()
        if ds.machine != scope.machine or ds.cell != scope.cell:
            continue
        var key = binding_key(resource, e.member, e.role)
        out.append(
            OwnedRecord(
                String(KIND_BINDING),
                key.copy(),
                String("global"),
                String("none"),
                String(""),
                String(RUN_UNKNOWN),
                True,
                ds.node.copy(),
                retained_by(ds.labels),
                String(""),
                validation_run_of(ds.labels),
                String(""),
                False,
            )
        )
        nodes.append(ds.node.copy())
        ids.append(key^)


def owned_records[
    C: Connector, TS: GcpTokenSource
](mut s: GcpSession[C, TS], scope: CellScope) raises -> List[OwnedRecord]:
    """`list_owned` (the file header)."""
    var out = List[OwnedRecord]()
    var nodes = List[String]()
    var ids = List[String]()
    var labels = AccountLabels()
    var accounts = s.list_accounts()
    for i in range(len(accounts)):
        labels.emails.append(accounts[i].email.copy())
        labels.labels.append(description_labels(accounts[i].description))
    var mine = List[Int]()
    for i in range(len(accounts)):
        ref lab = labels.labels[i]
        var node = stamped_node(lab, scope)
        if node.byte_length() == 0:
            continue
        mine.append(i)
        var account_id = String(accounts[i].email[byte = 0 : accounts[i].email.find("@")])
        var name = String("") if account_id == derived_name(scope.machine, scope.cell, node) else account_id.copy()
        out.append(
            OwnedRecord(
                String(KIND_ACCOUNT),
                accounts[i].name.copy(),
                String("global"),
                String("none"),
                String(""),
                String(RUN_UNKNOWN),
                True,
                node.copy(),
                retained_by(lab),
                String(""),
                validation_run_of(lab),
                name^,
                adopted_by(lab),
            )
        )
        nodes.append(node^)
        ids.append(accounts[i].name.copy())
    var jobs = s.list_jobs()
    for i in range(len(jobs)):
        var lab = job_labels(parse_job(encode_json(jobs[i])))
        var node = stamped_node(lab, scope)
        if node.byte_length() == 0:
            continue
        var job_id = last_segment(jobs[i].name)
        var name = String("") if job_id == derived_name(scope.machine, scope.cell, node) else job_id.copy()
        out.append(
            OwnedRecord(
                String(KIND_JOB),
                jobs[i].name.copy(),
                s.region.copy(),
                String("none"),
                String(""),
                String(RUN_UNKNOWN),
                True,
                node.copy(),
                retained_by(lab),
                String(""),
                validation_run_of(lab),
                name^,
                adopted_by(lab),
            )
        )
        nodes.append(node^)
        ids.append(jobs[i].name.copy())
    for k in range(len(mine)):
        var i = mine[k]
        var entries = s.account_policy(accounts[i].email)
        if not entries:
            continue
        _bindings(out, nodes, ids, labels, entries.value(), accounts[i].name, False, labels.labels[i], scope)
    var project = s.project_policy()
    _bindings(out, nodes, ids, labels, project, project_resource(s.project), True, List[Label](), scope)
    s.remember_owned(nodes^, ids^)
    return out^
