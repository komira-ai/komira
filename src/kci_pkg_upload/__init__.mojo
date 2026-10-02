"""`kci_pkg_upload` — native package-registry clients: upload a package file,
ask whether it is there, read back what the registry holds, and fetch it.

WHY THIS EXISTS. A release publishes package files to a registry, and the
publisher has to answer questions an upload tool does not: "is this exact file
already there?", "what does the registry say it holds now?". Shelling out to
`twine` / `uv publish` would make every release depend on a tool the release
does not ship or test, and neither answers those questions. So the protocols
are implemented here, over the HTTP client we already ship.

THE CONTRACT, IN THREE SENTENCES. Every server answer is DATA — a kind with an
explicit ABSENT, never a raise and never an empty value that compares equal by
vacuity (`outcome.mojo`, `identity.mojo`). `raises` means a LOCAL fault found
before any request was sent; a transport fault is UNKNOWN. The legacy upload is
the request `uv publish` sends, byte for byte (measured against a loopback
recorder and pinned by a golden test).

WHAT IS IN HERE:
  * `ContentIdentity` + `identity_matches` (identity.mojo) — compared FIELD BY
    FIELD; no common field is a refusal.
  * `PackageCoordinate` / `PackageFile` + the substrate ordinals
    (coordinate.mojo).
  * `Presence` / `ReadBack` / `Fetched` / `UploadOutcome` (outcome.mojo).
  * `PkgTransport` + `ScriptedPkgTransport` + `HttpPkgTransport[C]`
    (transport.mojo) — a one-method seam; the double records the exact wire.
  * `RegistryCredential`, keyed by SURFACE, + `ScriptedCredential`
    (credential.mojo).
  * the legacy upload form and its classification (core_metadata.mojo,
    legacy_upload.mojo).
  * `PypiLegacyRegistry` (pypi.org, TestPyPI) — the protocol struct.
  * `RegistrySet[T, C]` (registry_set.mojo) — THE substrate ladder.
  * `ApprovedNames` (approved_names.mojo) — the exact names an upload may
    claim, supplied by the caller; `RegistrySet.upload` asks it before
    anything else, so a name nobody approved is never claimed.

This package names no channel, account or organisation: every location, name
list and credential arrives from the caller.

Depends on komira_http, komira_async, komira_crypto, komira_encoding and
komira_json.

Encapsulation: owned values and seam conformers only. No UnsafePointer
crosses a module boundary; no wildcard origin; no unsafe_from_address.
"""

from .identity import (
    IDENTITY_MATCH,
    IDENTITY_MISMATCH,
    IDENTITY_NO_COMMON_FIELD,
    ContentIdentity,
    content_identity_of,
    identity_match_name,
    identity_matches,
)

from .coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
    normalize_distribution_name,
)

from .outcome import (
    PRESENCE_ABSENT,
    PRESENCE_AUTH_REFUSED,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_RATE_LIMITED,
    PRESENCE_UNKNOWN,
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    UPLOAD_AUTH_REFUSED,
    UPLOAD_BURNED,
    UPLOAD_CONFLICT,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    UPLOAD_WINDOW_CLOSED,
    Fetched,
    Presence,
    ReadBack,
    UploadOutcome,
    presence_kind_name,
    read_kind_name,
    upload_kind_name,
)

from .transport import (
    HttpPkgTransport,
    PkgRequest,
    PkgResponse,
    PkgTransport,
    ScriptedPkgTransport,
)

from .credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    RegistryCredential,
    ScriptedCredential,
    bearer_authorization,
    pypi_upload_authorization,
)

from .approved_names import ApprovedNames
from .pypi_registry import PypiLegacyRegistry
from .registry_set import RegistrySet
