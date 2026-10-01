# =============================================================================
# komira_pod_boot — the VM-BOOT CONTRACT between a PLACEMENT CONFORMER and the
#   ON-VM POD LOADER. Cloud-neutral by construction.
# =============================================================================
#
# ONE package, THREE kinds of consumer, TWO clouds:
#
#   a GCE conformer     renders a GCE startup script that EXPORTS these names
#   an EC2 conformer    renders EC2 user-data that EXPORTS the same names
#                       (komira_aws_bridge's Ec2VmPodManager is one)
#   the pod loader      READS them at boot
#
# It holds ONLY what all three must agree on — the environment variable names,
# GCE's metadata-key transport of them, the loader's install path, and the
# pod-spec JSON wire codec. It names NO cloud API and depends on no bridge.
#
# ⛔ WHY IT IS ITS OWN PACKAGE. A cloud bridge is the wrong home: the AWS boot
#   path would import a package named after the other cloud.
#
# A flat sibling package — its own `-I` root, import name `komira_pod_boot`.
# Depends on `komira_placement` (for the `ComposePodSpec` / `ComposeService` /
# `ComposePortMapping` value types it encodes) and `komira_k8s` (for `EnvVar`).
# Nothing depends back.
#
# ENCAPSULATION. Pure value-type code — String in / String out plus the
# value-typed `ComposePodSpec`. ZERO UnsafePointer; no wildcard origin; no
# pointer field, so no stale-pointer hazard across destroy and recreate.
# =============================================================================

from komira_pod_boot.pod_boot_contract import (
    ENV_POD_SPEC_JSON,
    ENV_HEARTBEAT_HOST,
    ENV_JOB_ID,
    ENV_POD_NAME,
    ENV_TASK_TIMEOUT_S,
    GCE_META_POD_SPEC,
    GCE_META_HEARTBEAT_HOST,
    GCE_META_JOB_ID,
    GCE_META_POD_NAME,
    GCE_META_TASK_TIMEOUT_S,
    POD_LOADER_INSTALL_PATH,
    parse_task_timeout_s,
    serialize_pod_spec_json,
    deserialize_pod_spec_json,
)

# WHERE the one artifact a booting VM fetches lives — the same hand-off as the
# names above (a publisher WRITES it, a placement conformer RENDERS a fetch of
# it), so it is declared beside them and both sides import it.
from komira_pod_boot.boot_bundle_location import (
    BOOT_BUNDLE_SCHEME_GS,
    BOOT_BUNDLE_SCHEME_S3,
    BOOT_BUNDLE_KEY_PREFIX,
    BOOT_BUNDLE_BASENAME,
    PUBLISHED_BOOT_BUNDLE_URL_PREFIX,
    boot_bundle_bucket,
    boot_bundle_key,
    boot_bundle_url,
)
