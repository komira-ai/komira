"""`kci_cloud_gcp`: the GCP cloud adapter, the first real `CloudAdapter`.

`GcpCloud[C, TS]` deploys a cell's resources into one GCP project and
region, over komira's generated REST clients (IAM, Cloud Resource Manager,
Cloud Run), each on a connector of type `C` (`GcpConnectors`), all asking
one token source of type `TS`. It lowers through kci_cloud's shared shape
lowering on the gcp shape, so it lowers as the gcp fake does, and it hosts
(docs/design/deploy_step.md, row G4):

  * `service_account`: an IAM service account, a DESCRIPTION CARRIER (its
    description holds kci's lines, kci_cloud/labels.mojo), born stamped;
  * `container_job`: a Cloud Run job, stamped with labels, born stamped;
  * the member bindings of its grant edges on a service account and on the
    project, whose stamp is DERIVED (kci_cloud/derived.mojo) through G4's
    rows of the IAM role table.

Modules:
  * cloud.mojo         — `GcpCloud`, what each trait method answers.
  * names.mojo         — the objects' names (derived from machine, cell and
                         node id unless the author named the object) and
                         the role table, `gcp_role_table`.
  * session.mojo       — `GcpSession` (the clients, the token source, what
                         a verb learned), `GcpConnectors`, `GcpEndpoints`,
                         `SharedTokenSource`; the hand-written
                         PatchServiceAccount and token-information read.
  * node_account.mojo, node_job.mojo, node_binding.mojo — the engine node
                         of each provider kind.
  * job_model.mojo     — a run node as a Cloud Run job, and back.
  * owned.mojo         — `list_owned`.
  * credentials.mojo   — the reader a deploy's GOOGLE_APPLICATION_CREDENTIALS
                         goes to (`deploy_credentials_type`,
                         `service_account_token_source`).

No public function takes or returns a pointer; the session is shared between
the adapter and its nodes through an `ArcPointer` inside the package.
"""

from kci_cloud_gcp.cloud import (
    ACCOUNT_DESCRIPTION_MAX,
    GCP_CLOUD_ID,
    REGISTRY_USER,
    GcpCloud,
    registry_name,
)
from kci_cloud_gcp.credentials import (
    CLOUD_PLATFORM_SCOPE,
    CREDENTIALS_EXTERNAL_ACCOUNT,
    CREDENTIALS_SERVICE_ACCOUNT,
    deploy_credentials_type,
    service_account_token_source,
)
from kci_cloud_gcp.job_model import (
    ModelField,
    desired_model,
    job_json,
    live_model,
    model_value,
    timeout_duration,
    lowered_timeout,
    size_limits,
    lowered_size,
)
from kci_cloud_gcp.names import (
    KIND_ACCOUNT,
    KIND_BINDING,
    KIND_JOB,
    ROLE_ACCOUNT_VIEWER,
    ROLE_LOG_WRITER,
    account_email,
    account_member,
    account_resource,
    derived_name,
    display_name_of,
    gcp_role_table,
    job_resource,
    object_name,
    project_resource,
)
from kci_cloud_gcp.session import GcpConnectors, GcpEndpoint, GcpEndpoints, SharedTokenSource
