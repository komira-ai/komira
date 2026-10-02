"""`komira_k8s` — narrow native Kubernetes pod client (in-cluster).

Authenticate to the apiserver with in-cluster config (or explicit
out-of-cluster values) and do pod create / get / delete / list / logs.

Public surface:
  * load_in_cluster_config / InClusterConfig — SA token + CA + apiserver host.
    The apiserver host and port are parameters supplied by the caller; the
    library reads no environment variables.
  * K8sPodClient — create_pod / get_pod_status / get_pod_liveness / delete_pod
    / list_pods / get_pod_logs.
  * PodCreateSpec / EnvVar / KeyValue — the typed manifest input.
  * PodPhase (+ POD_* tags) — the status enum a reconciler matches on.
  * PodLiveness / PodDeletionAck — the DELETION-EVIDENCE pair: "does this
    object still exist" and "was a deletion accepted, with what deadline".
    ⭐ NOT expressible in `PodPhase`: `derive_pod_phase` reads `status.*` and
    never `metadata`, so a pod that is Terminating with its containers still up
    derives `Running`, identical to one nobody deleted.
  * K8sError — the Status-envelope -> typed-error mapping.

Scope: the apiserver is addressed by IP (no DNS), namespaced Pods only, NO
watch (a caller POLLS get_pod_status on a tick).

Substrate: komira_http (HttpClient over s2n TLS), komira_proto_codec (JSON),
komira_async (the blocking runtime and reactor).
"""

from .k8s_types import (
    PodCreateSpec,
    PodDeletionAck,
    PodLiveness,
    PodSummary,
    EnvVar,
    KeyValue,
    PodPhase,
    K8sError,
    POD_PENDING,
    POD_RUNNING,
    POD_SUCCEEDED,
    POD_FAILED,
    POD_NOTFOUND,
    POD_UNKNOWN,
    K8S_ERR_FORBIDDEN,
    K8S_ERR_INVALID,
    K8S_ERR_UNAUTHORIZED,
    K8S_ERR_TRANSPORT,
    K8S_ERR_PROTOCOL,
)
from .k8s_config import (
    InClusterConfig,
    K8sTokenSource,
    load_in_cluster_config,
    load_in_cluster_config_from,
    SA_DIR,
)
from .k8s_json import (
    build_pod_manifest,
    derive_pod_phase,
    parse_pod_deletion_ack,
    parse_pod_list,
    parse_pod_liveness,
    pod_deletion_grace_seconds,
    pod_deletion_timestamp,
)
from .k8s_tls import (
    HttpResponse,
    k8s_build_tls_connector,
    k8s_https_request_authed,
    k8s_https_request_authed_blocking,
)
from .k8s_client import (
    K8sPodClient,
    liveness_outcome_for_status,
    LIVENESS_PRESENT,
    LIVENESS_ABSENT,
    LIVENESS_ERROR,
    pods_collection_path,
    pod_resource_path,
    pod_log_subpath,
    APISERVER_SNI,
)
