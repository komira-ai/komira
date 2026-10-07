# =============================================================================
# komira_azure_blob/azure_client_spec.mojo — what an AzureClient is built from
# =============================================================================
#
# `AzureCredential` is how a request to the blob service is authorized: an
# account's Shared Key (komira_azure_core's `AzureSharedKey`, signed per
# request by `SharedKeySigningLayer`), a SAS token (komira_azure_core's
# `AzureSas`, appended to every request's query by `SasQueryLayer`), or
# nothing (anonymous reads of a public container). The caller resolves it
# from its own flags or secret store; nothing here reads the environment.
#
# `AzureClientSpec[C]` is everything an `AzureClient[C]` is built from, as a
# copyable value: the endpoint (`AzureConfig`), the credential, and a
# connector factory (a thin function, called once per connector the client
# holds). `AzureFs` keeps one and builds each clone's client from it, so a
# clone carries the same endpoint, account and credential as the file
# system it was cloned from, whatever they were at run time.
#
# A Shared Key signs for one account, so a spec whose key names a different
# account than its endpoint is refused.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from komira_azure_core import AzureSas, AzureSharedKey
from komira_http_core.transport.io_stream import Connector

from .azure import AzureConfig
from .azure_client import AzureClient
from .azure_sas_query import azure_sas_query_normalize


comptime AZURE_CREDENTIAL_ANONYMOUS: UInt8 = 0
comptime AZURE_CREDENTIAL_SHARED_KEY: UInt8 = 1
comptime AZURE_CREDENTIAL_SAS: UInt8 = 2


struct AzureCredential(Copyable, Movable, Deinitable):
    """A Shared Key, a SAS token, or anonymous (module header). Built by
    `shared_key`, `sas` or `anonymous`; `kind()` says which."""

    var _kind: UInt8
    var _key: AzureSharedKey
    var _sas: AzureSas

    def __init__(out self, kind: UInt8, var key: AzureSharedKey, var sas: AzureSas):
        self._kind = kind
        self._key = key^
        self._sas = sas^

    @staticmethod
    def shared_key(key: AzureSharedKey) raises -> AzureCredential:
        """The account `key.account`'s Shared Key. Raises `azure_credential:
        a shared key needs an account name and a key` when either is
        empty."""
        if key.account.byte_length() == 0 or key.key_b64.byte_length() == 0:
            raise Error(
                "azure_credential: a shared key needs an account name and a key"
            )
        return AzureCredential(
            AZURE_CREDENTIAL_SHARED_KEY, key.copy(), AzureSas(String(""))
        )

    @staticmethod
    def sas(token: AzureSas) raises -> AzureCredential:
        """A SAS token, checked and with any leading `?` dropped
        (`azure_sas_query_normalize`)."""
        var q = azure_sas_query_normalize(token.query_string)
        return AzureCredential(
            AZURE_CREDENTIAL_SAS,
            AzureSharedKey(String(""), String("")),
            AzureSas(q^),
        )

    @staticmethod
    def anonymous() -> AzureCredential:
        """No credential: requests go unsigned (a public container)."""
        return AzureCredential(
            AZURE_CREDENTIAL_ANONYMOUS,
            AzureSharedKey(String(""), String("")),
            AzureSas(String("")),
        )

    @always_inline
    def kind(self) -> UInt8:
        """`AZURE_CREDENTIAL_ANONYMOUS`, `_SHARED_KEY` or `_SAS`."""
        return self._kind

    def shared_key_account(self) -> String:
        """The Shared Key's account; "" unless `kind()` is
        `AZURE_CREDENTIAL_SHARED_KEY`."""
        return self._key.account


struct AzureClientSpec[C: Connector](Copyable, Movable, Deinitable):
    """The endpoint, credential and connector factory an `AzureClient[C]`
    is built from (module header). `build()` makes a client; nothing is
    dialed until it sends a request."""

    var _config: AzureConfig
    var _credential: AzureCredential
    # A code pointer (the FFI-POD carve-out of the pointer rules): no heap,
    # no origin. Called once per connector a built client holds.
    var _mk_connector: def () raises thin -> Self.C

    def __init__(
        out self,
        config: AzureConfig,
        credential: AzureCredential,
        mk_connector: def () raises thin -> Self.C,
    ) raises:
        """The spec for `config`'s endpoint and account. Raises
        `azure_client_spec: the shared key is for account '<a>' and the
        endpoint is account '<b>'` when the credential is a Shared Key for
        another account."""
        if (
            credential.kind() == AZURE_CREDENTIAL_SHARED_KEY
            and credential.shared_key_account() != config.account
        ):
            raise Error(
                "azure_client_spec: the shared key is for account '"
                + credential.shared_key_account()
                + "' and the endpoint is account '"
                + config.account
                + "'"
            )
        self._config = config
        self._credential = credential.copy()
        self._mk_connector = mk_connector

    @always_inline
    def config(self) -> AzureConfig:
        """The endpoint configuration."""
        return self._config

    @always_inline
    def credential_kind(self) -> UInt8:
        """The credential's `kind()`."""
        return self._credential.kind()

    def new_connector(self) raises -> Self.C:
        """A connector from the spec's factory; nothing is dialed."""
        return self._mk_connector()

    def build(self) raises -> AzureClient[Self.C]:
        """A configured `AzureClient[C]` for this spec: two connectors from
        the factory, the credential's Shared Key (or none) for the signing
        layer and its SAS token (or none) for the SAS layer."""
        return AzureClient[Self.C](
            account=self._credential._key.account,
            key_b64=self._credential._key.key_b64,
            connector=self._mk_connector(),
            call_connector=self._mk_connector(),
            config=self._config,
            sas_query=self._credential._sas.query_string,
        )
