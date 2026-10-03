# =============================================================================
# komira_secret_env: a `SecretStore` that reads the environment variable whose
#   NAME is the handle.
# =============================================================================
#
#   * `EnvSecretStore[E]`  the store: handle grammar, unset / empty refusals.
#   * `EnvReader`          the lookup seam it reads through.
#   * `ProcessEnv`         the reader over this process (`getenv(3)`).
#   * `MapEnv`             the hermetic double.
#   * `is_secret_env_name`, `check_secret_env_name`, `MAX_SECRET_NAME_LEN`
#                          the handle grammar.
#
# DEPENDENCIES: komira_secret_store, komira_libc (getenv), komira_crypto.
# =============================================================================

from komira_secret_env.env_name import (
    MAX_SECRET_NAME_LEN,
    check_secret_env_name,
    is_secret_env_name,
)
from komira_secret_env.env_secret_store import EnvReader, EnvSecretStore
from komira_secret_env.process_env import ProcessEnv
from komira_secret_env.map_env import MapEnv
