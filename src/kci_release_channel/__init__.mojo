# =============================================================================
# kci_release_channel -- release channels.
# =============================================================================
#
# A release channel is a publish destination: a name, a visibility and one
# repository per artifact type, each with its push credential (names only).
# `channel.mojo` holds the types, the lookups and
# `validate_channels`; `channel_credential.mojo` the credential and
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
from kci_release_channel.channel import (
    VISIBILITY_PRIVATE,
    VISIBILITY_PUBLIC,
    Channel,
    ChannelRepository,
    channel_names,
    find_channel,
    is_valid_channel_name,
    push_identity_environment,
    validate_channels,
)
from kci_release_channel.parse import parse_channels_file
