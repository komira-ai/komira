# =============================================================================
# kci_cloud_gcp/names.mojo: what GCP calls kci's objects, and the role table.
# =============================================================================
#
# NAMES. The primary object of a resource that writes `physical_name` is
# created under that name. Every other object's name is DERIVED, a pure
# function of the machine, the cell and the node id, so a node's object can
# be found again with nothing but the lowering:
#   * a service account (an identity node): the account id
#     `kci-<10 base32 characters of sha256(<machine>/<cell>/<node id>)>`,
#     14 bytes, inside IAM's rule (6 to 30 of [a-z0-9-], a letter first);
#     its email is `<id>@<project>.iam.gserviceaccount.com`;
#   * a Cloud Run job (a container job's run node): the job id, the same
#     derivation, inside Run's rule (at most 63 of [a-z0-9-], a letter
#     first, not ending with `-`).
# A derived name holds the machine and the cell, so two cells of one project
# never share an object, and the hash keeps a long resource path inside the
# limits. `display_name_of` is kci's display name for an account: the node
# id. kci owns it like any modelled field, so an account changed in a
# console is updated back.
#
# THE ROLE TABLE. One row per (target, access verb): attribution reads it
# backwards (kci_cloud/derived.mojo), so it is injective, and a test says
# so (`role_table_problems` empty, and every role on exactly one row). G4's
# rows:
#   `uses <account> DESCRIBE`  on the target service account
#                              roles/iam.serviceAccountViewer (slightly
#                              broader than DESCRIBE: it also reads the
#                              account's key metadata)
#   `cell LOGS WRITE`          on the project, roles/logging.logWriter
# =============================================================================

from kci_cloud import (
    ACCESS_DESCRIBE,
    ACCESS_WRITE,
    CELL_LOGS,
    CELL_PATH_PREFIX,
    RoleRow,
    cell_name,
    role_hash,
)


comptime KIND_ACCOUNT = "iam.googleapis.com/ServiceAccount"
"""The provider kind of an identity node on the gcp shape."""
comptime KIND_JOB = "run.googleapis.com/Job"
"""The provider kind of a container job's run node."""
comptime KIND_BINDING = "setIamPolicy"
"""The provider kind of a member binding (the call that writes it)."""
comptime SA_EMAIL_DOMAIN = ".iam.gserviceaccount.com"
comptime MEMBER_SA_PREFIX = "serviceAccount:"
comptime DERIVED_PREFIX = "kci-"
comptime DERIVED_HASH_CHARS = 10
comptime ROLE_ACCOUNT_VIEWER = "roles/iam.serviceAccountViewer"
comptime ROLE_LOG_WRITER = "roles/logging.logWriter"


def derived_name(machine: String, cell: String, node_id: String) -> String:
    """The derived name of node `node_id`'s object in `machine`'s `cell`."""
    return String(DERIVED_PREFIX) + role_hash(machine + String("/") + cell + String("/") + node_id, DERIVED_HASH_CHARS)


def object_name(machine: String, cell: String, node_id: String, physical_name: String) -> String:
    """The name a node's object is created under: its `physical_name`, else
    the derived name."""
    if physical_name.byte_length() > 0:
        return physical_name.copy()
    return derived_name(machine, cell, node_id)


def account_email(account_id: String, project: String) -> String:
    return account_id + String("@") + project + String(SA_EMAIL_DOMAIN)


def account_resource(project: String, email: String) -> String:
    """An account's resource name, as IAM's paths and policies name it."""
    return String("projects/") + project + String("/serviceAccounts/") + email


def account_member(email: String) -> String:
    """An account as a policy member."""
    return String(MEMBER_SA_PREFIX) + email


def project_resource(project: String) -> String:
    return String("projects/") + project


def job_parent(project: String, region: String) -> String:
    return String("projects/") + project + String("/locations/") + region


def job_resource(project: String, region: String, job_id: String) -> String:
    return job_parent(project, region) + String("/jobs/") + job_id


def last_segment(name: String) -> String:
    """What follows the last `/` of a resource name."""
    var at = name.rfind("/")
    if at < 0:
        return name.copy()
    return String(name[byte = at + 1 : name.byte_length()])


def email_of_member(member: String) -> String:
    """The email of a `serviceAccount:` member, or empty for any other."""
    if not member.startswith(MEMBER_SA_PREFIX):
        return String("")
    return String(member[byte = String(MEMBER_SA_PREFIX).byte_length() : member.byte_length()])


def display_name_of(node_id: String) -> String:
    """kci's display name of an account: the node id."""
    return node_id.copy()


def logs_target() -> String:
    """The role table's target for a `cell LOGS` edge: `cell/LOGS`."""
    return String(CELL_PATH_PREFIX) + cell_name(CELL_LOGS)


def gcp_role_table() -> List[RoleRow]:
    """G4's rows of the IAM role table (the file header)."""
    var rows = List[RoleRow]()
    rows.append(RoleRow(String(KIND_ACCOUNT), String(ACCESS_DESCRIBE), String(ROLE_ACCOUNT_VIEWER)))
    rows.append(RoleRow(logs_target(), String(ACCESS_WRITE), String(ROLE_LOG_WRITER)))
    return rows^
