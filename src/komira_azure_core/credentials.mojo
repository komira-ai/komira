# =============================================================================
# komira_azure_core/credentials.mojo — Azure credential types and providers
# =============================================================================
#
# The Storage account key (Shared Key) and the SAS query string, and a static
# provider for each. Every value is a constructor parameter: nothing here
# reads the environment. A binary that takes an account key or a SAS token
# reads it from where its own flags say (a file, a secret store) and hands it
# in here.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================


# -----------------------------------------------------------------------------
# AzureSharedKey — account key, used by Shared Key signing (komira_azure_blob)
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureSharedKey(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Azure Storage account + base64-encoded key.

    Field layout:
      var account: String   — the storage account name (the URL host's
                              first label, e.g. "mystoraccount" in
                              "mystoraccount.blob.core.windows.net")
      var key_b64: String   — the base64-encoded 64-byte account key
    """

    var account: String
    var key_b64: String


# -----------------------------------------------------------------------------
# AzureSas — SAS query-string credential
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureSas(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Azure SAS (Shared Access Signature) token.

    Field layout:
      var query_string: String   — the literal SAS query string, e.g.
                                    "sv=...&sig=...&sp=r&...",
                                    appended to every request URL.
    """

    var query_string: String


# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------


@fieldwise_init
struct SharedKeyProvider(Copyable, Movable, Deinitable):
    """Static Shared Key provider; `credential()` returns the same
    AzureSharedKey every call."""

    var _cred: AzureSharedKey

    @staticmethod
    def make(account: String, key_b64: String) -> SharedKeyProvider:
        return SharedKeyProvider(AzureSharedKey(account, key_b64))

    @always_inline
    def credential(self) -> AzureSharedKey:
        return self._cred


@fieldwise_init
struct SasProvider(Copyable, Movable, Deinitable):
    """Static SAS provider."""

    var _cred: AzureSas

    @staticmethod
    def make(query_string: String) -> SasProvider:
        return SasProvider(AzureSas(query_string))

    @always_inline
    def credential(self) -> AzureSas:
        return self._cred
