# =============================================================================
# komira_secret_env/env_secret_store.mojo: a `SecretStore` whose handle is the
#   NAME of an environment variable.
# =============================================================================
#
# `EnvSecretStore[E].resolve(handle)` checks the handle's grammar, asks its
# `EnvReader` for the variable of that name, and hands back the bytes as a
# zeroizing `SecretValue`. The reader is a seam: `ProcessEnv` reads the
# process environment, `MapEnv` is the hermetic double.
#
# Refusals, each naming the handle and never the value:
#   * the handle is not a variable name (not quoted: see env_name.mojo);
#   * the variable is not set;
#   * the variable is set but empty. Unset and empty are different mistakes
#     (a missing export, an export of an empty expansion), so they get
#     different messages; neither resolves, because an empty credential has
#     no benign use;
#   * the value is longer than `MAX_SECRET_LEN` (the reader's refusal,
#     prefixed with the handle).
#
# The value is never logged, quoted or copied into a `String`.
# =============================================================================

from komira_secret_store import SecretStore, SecretValue

from komira_secret_env.env_name import check_secret_env_name


trait EnvReader(Movable, Deinitable):
    """Looks up one environment variable by name.

    Returns `None` when the variable is unset, and a `SecretValue` (possibly
    empty) when it is set. Raises when the value cannot be held (too long) or
    the name is refused."""

    def lookup(mut self, name: String) raises -> Optional[SecretValue]:
        ...


struct EnvSecretStore[E: EnvReader](SecretStore, Movable):
    """A `SecretStore` that resolves a handle by reading the environment
    variable whose NAME is the handle."""

    var _env: Self.E

    def __init__(out self, var env: Self.E):
        self._env = env^

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """The value of the environment variable named `secret_ref`.

        Raises naming the handle when the handle is not a variable name, the
        variable is unset or empty, or its value is too long."""
        try:
            check_secret_env_name(secret_ref)
        except e:
            raise Error(String("EnvSecretStore: ") + String(e))
        var found: Optional[SecretValue]
        try:
            found = self._env.lookup(secret_ref)
        except e:
            raise Error(
                String("EnvSecretStore: environment variable ")
                + secret_ref
                + ": "
                + String(e)
            )
        if not found:
            raise Error(
                String("EnvSecretStore: environment variable ")
                + secret_ref
                + " is not set"
            )
        var value = found.take()
        if value.is_empty():
            raise Error(
                String("EnvSecretStore: environment variable ")
                + secret_ref
                + " is set but empty"
            )
        return value^
