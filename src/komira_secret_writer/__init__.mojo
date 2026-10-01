# =============================================================================
# komira_secret_writer — the WRITE-ONLY secret seam: the verb a deployer uses to
#   write a managed-app secret value that it is the source of.
# =============================================================================
#
# A deploy's ensure-secret step needs to WRITE a managed operational secret
# value into the customer's secret store so the running app's runtime
# `SecretCapability` resolve finds it. `komira_secret_store` RESOLVES only —
# there is no write path on the `SecretStore` trait (deliberately: the
# resolve-only firewall).
#
# This SIBLING package ships the `SecretWriter` verb as a TYPE-FIREWALLED
# capability DISTINCT from `SecretStore`: only the deploy applier's
# ensure-infra path holds a `SecretWriter`; the runtime-resolve path
# structurally cannot obtain one, so a compromised resolve path can never write.
# This is the strongest guarantee the type system can give — the whole trust
# argument rests on the write capability being unreachable from the resolve
# path.
#
# DELIBERATELY MINIMAL (the security-sensitive scope). This package ships ONLY:
#   * `SecretWriter`        — the write-only trait (the type firewall).
#   * `StaticSecretWriter`  — the in-memory test double (records writes; bridges
#                             to a paired `StaticSecretStore` for the
#                             write-then-resolve round-trip proof).
# Production writers (a cloud secret manager's create-secret-version PUT, a
# Vault KV put) live with their cloud clients, under the SAME type firewall,
# following the resolve conformers' shape.
#
# Dependency direction (cycle-free; a leaf on the secrets foundation):
#   komira_secret_writer -> komira_secret_store  (SecretValue — the zeroizing
#                                                 move-only value;
#                                                 StaticSecretStore — the paired
#                                                 resolve double for the
#                                                 round-trip test)
#   NOT the reverse (the resolve foundation must NOT depend on the writer — the
#   firewall is one-directional: the writer knows about resolve for the test
#   bridge, but resolve never knows about the writer).
#
# A SIBLING package, import name `komira_secret_writer`.
# =============================================================================

from .secret_writer import (
    SecretWriter,
    StaticSecretWriter,
)
