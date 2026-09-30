# =============================================================================
# komira_core/traits/credential_provider.mojo — abstract CredentialProvider
# =============================================================================
#
# The abstract `CredentialProvider` trait lives in `komira_core/traits/`,
# not in an object-store package. Two reasons:
#
#   1. A credential provider is orthogonal to the storage abstraction (in the
#      Rust ecosystem, `aws-credential-types` lives BELOW and INDEPENDENT of
#      `object_store`). A non-storage cloud client (a control-plane queue,
#      say) wants the credential trait without the storage substrate.
#
#   2. The trait is a pure *value contract*. Refresh is out-of-band
#      (refreshable provider impls own their own timer); the runtime NEVER
#      appears in the trait signature. With no runtime / HTTP / async
#      dependency, `komira_core` (the lowest layer) is the right home.
#
# Scope:
#   * The abstract trait surface — a `comptime Cred` associated type + a
#     `credential(self) -> Self.Cred` value method.
#   * No concrete conformers. Per-cloud credential types (`AwsCredential`,
#     `BearerToken`, `AzureSharedKey`, `AzureSas`) live in their cloud's
#     package next to the providers that yield them.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any method signature.
#   * ZERO wildcard origins.
#   * Conformers should be `Movable, Deinitable`. The
#     concrete credential type a provider yields holds secret material;
#     conformer impls must be careful about Copyable (copying secret
#     material risks leaks via stray copies).
# =============================================================================


trait CredentialProvider(Movable, Deinitable):
    """The abstract credential-provider contract.

    Conformers (in their cloud's package):
      * AWS:   StaticAwsProvider, EnvAwsProvider, Imdsv2Provider,
               EcsContainerProvider, ProfileProvider, SsoProvider,
               WebIdentityProvider, AwsCredentialChain
      * GCP:   GcpAdcProvider, GcpMetadataProvider,
               GcsServiceAccountProvider, GcpCredentialChain
      * Azure: AzureEnvProvider, AzureImdsProvider,
               ServicePrincipalProvider, AzureCredentialChain
      * Azure Storage-scoped: SasProvider

    Associated type:
      comptime Cred: Movable & Deinitable
          — the concrete credential type the provider yields.
            AWS:   `AwsCredential` (access_key + secret_key + optional session_token)
            GCP:   `BearerToken` (bearer_token + expiry_unix_ms)
            Azure: `BearerToken` (Entra OAuth2) or `AzureSharedKey` (Storage)
            Azure: `AzureSas` (Storage-scoped, query-string)

    Pointer discipline: zero UnsafePointer in the trait surface. The
    credential type the conformer yields is a plain value (Movable),
    moved out of the provider into the caller — typically into the
    signing layer that consumes it immediately.

    Runtime-free: `credential()` is synchronous and runtime-free —
    there is NO `[RT: Runtime]` parameter and NO async
    body. Refreshable providers (those that fetch tokens out-of-band)
    own their own refresh timer internally; their `credential()` returns
    the cached current credential. This decoupling is what allows the
    trait to live in `komira_core` (which has no runtime dependency).
    """

    # The concrete credential type the conformer yields.
    comptime Cred: Movable & Deinitable

    def credential(self) raises -> Self.Cred:
        """Return the currently-valid credential.

        Implementations that maintain a refresh timer return the cached
        current credential; static providers return a clone of the
        configured credential. Raises on a fatal provider failure (e.g.
        env var missing, profile file not found) — never on a refresh
        miss (the cached-credential semantics handle that out-of-band).
        """
        ...
