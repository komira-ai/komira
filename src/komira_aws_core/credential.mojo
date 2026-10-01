# =============================================================================
# komira_aws_core/credential.mojo -- the AWS credential value
# =============================================================================
#
# `AwsCredential` is what every AWS signer and client takes: an access key id,
# its secret, and an optional session token. It is a plain value. Nothing in
# this module finds a credential and nothing here reads the environment. The
# providers that find one (environment keys, the shared config and
# credentials files, web identity through STS, the container and instance
# metadata endpoints) are separate modules of this package. They read only
# the STANDARD AWS SDK variables, in the AWS SDK default credential chain
# order, each citing the AWS SDK reference that defines it; komira adds no
# environment variables of its own, and explicit parameters always win.
#
# The type is not `Writable` on purpose, so a credential cannot be printed or
# logged by accident.
# =============================================================================


@fieldwise_init
struct AwsCredential(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """An AWS credential: access key id, secret access key, session token.

    `session_token` is empty for a long-term credential and set for a
    temporary one (STS, instance or container role, Lambda).
    """

    var access_key_id: String
    var secret_access_key: String
    var session_token: String

    @always_inline
    def has_session_token(self) -> Bool:
        """True for a temporary credential, which carries a session token."""
        return self.session_token.byte_length() > 0
