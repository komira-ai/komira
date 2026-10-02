# =============================================================================
# kci_release_channel -- release-channel declarations.
# =============================================================================
#
# A release channel is a publish destination: a name, a visibility and one
# repository per artifact type, each with its push credential (names only).
# `channel_declaration.mojo` holds the types, the lookups and
# `validate_channel_declarations`; `channel_credential.mojo` the credential and
# its rules; `artifact_types.mojo` the closed artifact-type set; `parse.mojo`
# reads a channels file with `parse_channels_file`.
# =============================================================================

from kci_release_channel.artifact_types import (
    ARTIFACT_TYPE_CONDA,
    ARTIFACT_TYPE_NPM,
    ARTIFACT_TYPE_OCI,
    ARTIFACT_TYPE_PYTHON,
    is_known_artifact_type,
)
from kci_release_channel.channel_credential import (
    CREDENTIAL_KIND_API_TOKEN,
    CREDENTIAL_KIND_OIDC_TRUSTED_PUBLISHING,
    ChannelCredential,
    is_known_credential_kind,
    is_valid_secret_name,
    oidc_exchange_implemented,
    validate_channel_credential,
)
from kci_release_channel.channel_declaration import (
    VISIBILITY_PRIVATE,
    VISIBILITY_PUBLIC,
    ChannelDeclaration,
    ChannelRepository,
    channel_names,
    find_channel,
    is_valid_channel_name,
    validate_channel_declarations,
)
from kci_release_channel.parse import parse_channels_file
