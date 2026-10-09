"""`kci_cloud_gcp`: the GCP cloud adapter's foundations (row G4 of
docs/design/deploy_step.md; the `CloudAdapter` and its nodes build on them).

Modules:
  * names.mojo         — the objects' names (derived from machine, cell and
                         node id unless the author named the object) and
                         the role table, `gcp_role_table`.
  * session.mojo       — `GcpSession` (the generated IAM, Cloud Resource
                         Manager and Cloud Run clients on connectors of the
                         caller's type, one shared token source, what a verb
                         learned), `GcpConnectors`, `GcpEndpoints`,
                         `SharedTokenSource`; the hand-written
                         PatchServiceAccount and token-information read.
  * job_model.mojo     — a container job's run node as a Cloud Run job, and
                         back.
  * credentials.mojo   — the reader a deploy's GOOGLE_APPLICATION_CREDENTIALS
                         goes to (`deploy_credentials_type`,
                         `service_account_token_source`).

No public function takes or returns a pointer.
"""

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
