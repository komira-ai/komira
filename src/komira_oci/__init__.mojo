"""`komira_oci` — a native OCI distribution client: image copies and layout pushes.

It performs a registry-to-registry, DIGEST-PRESERVING image copy over HTTPS
(`OciCopier`), and it pushes a LOCAL OCI layout directory to a registry and tags
it with a revision id (`read_oci_layout` + `LayoutPusher`).

WHY THIS EXISTS. A release `stage` promotes a built image from the build
project's registry into each target environment's registry. That promote is a
CONTENT-ADDRESSED copy — the same bytes, under the same `sha256:…` digest,
because the digest IS the recorded deployable reference. Doing it with an
external tool (such as `crane`) makes a release machine depend on a binary
installed out of band, and rests the copy's correctness on a tool the release
tool neither ships nor tests. A release tool must be able to run a release with
nothing but its own binaries, independent of any particular build system, so
the copy is implemented here, over the shipped HTTP client.

THE CONTRACT, IN ONE SENTENCE: `OciCopier.copy_by_digest` either reproduces the
source digest at the destination, or it raises. Every artifact it moves is
independently content-address-verified against the descriptor that named it —
manifests and blobs alike — so a corrupt or substituted byte cannot be recorded
as deployable.

WHAT IS IN HERE:
  * `parse_oci_ref` / `OciImageRef` (oci_ref.mojo) — the three-part ref, split
    once and fail-loud, plus the manifest media-type vocabulary (BOTH the OCI
    and the Docker schema families — a client that accepts only one gets 404s
    from half the world).
  * `digest_of_bytes` / `verify_digest` / `validate_digest_format`
    (oci_digest.mojo) — the ONE place bytes become a digest.
  * `OciTransport` + `ScriptedOciTransport` + `HttpOciTransport[C]`
    (oci_transport.mojo) — a ONE-METHOD seam. The protocol lives in the client,
    not the seam, so the test double is ~60 lines and can script any
    conversation.
  * `OciCopier[T]` (oci_copy.mojo) — the copy: discover the manifest tree
    (INDEXES INCLUDED — a multi-arch image is a tree, not a manifest), mount or
    upload every blob, then PUT manifests leaves-first.
  * `read_oci_layout` / `OciLayout` (oci_layout_reader.mojo) — read and VERIFY an
    OCI layout DIRECTORY (`oci-layout`, `index.json`, `blobs/sha256/*`; no Docker
    `manifest.json` needed): exactly one image manifest, every blob's size and
    sha256 checked by STREAMING, no blob above `MAX_MONOLITHIC_BLOB_BYTES`, the
    platform from the config. The one implementation of layout verification.
  * `LayoutPusher[T]` / `PushResult` (oci_push.mojo) — push a verified layout:
    HEAD each blob and skip what is there, open a session and monolithic-PUT
    what is not (the body MOVED into the request), PUT the manifest by digest
    (leaves first), PUT the tag (a caller-supplied revision id, checked against
    the OCI tag grammar), then read both back. A re-run of the same digest is a
    NOOP; a present manifest with a missing tag gets the tag added; and a failed
    tag PUT is classified by READING the tag and comparing digests (same ->
    success, different -> REFUSED, unreadable -> INDETERMINATE), never by the
    status code. Retries are bounded: 5xx and transport faults, and 403 only
    when the caller says the repository was just created.
  * `resolve_upload_location` (oci_location.mojo) — an upload session's
    `Location` may be relative or absolute; a cross-host or plaintext one is
    REFUSED, so the credential never leaves the host it was issued for. Used by
    both the copier and the pusher.
  * `OciAuth` (oci_auth.mojo) — none, bearer, or basic; the secret is never in
    an error message or a result.
  * `FakeOciRegistry`, `write_test_layout` — TEST SUPPORT: a stateful in-process
    registry (per-repository blobs, upload sessions, immutable tags with a
    configurable conflict status, fault injection) and a real layout-directory
    writer. Nothing production calls them.
  * `layout_image_digest` (oci_layout.mojo) — read the expected digest from a
    LOCAL OCI layout's `index.json` rather than asking a registry. Borrowed from
    `rules_oci`'s pusher and strictly better provenance than `crane digest`,
    which reports whatever a registry is currently serving for a name.

OUT OF SCOPE (deliberately, and not accidentally omitted):
  * The `WWW-Authenticate` token-exchange dance. Artifact Registry accepts a
    Google OAuth2 access token as a bearer directly, and the caller resolves
    that token through the credential chain it already uses for the registry —
    inventing a second credential path here would be the more dangerous kind of
    completeness.
  * Chunked/resumable blob upload. A monolithic PUT closes the session, and a
    layer above `MAX_MONOLITHIC_BLOB_BYTES` is REFUSED up front, naming the
    limit and saying chunked upload is not implemented — never a silent gap.
  * Cross-repository mounts on a LAYOUT push (there is no source repository).
    The copier still mounts within one registry.
  * Multi-arch images: a layout whose one entry is itself an image index is
    refused, never half-pushed.
  * Tag deletes and garbage collection. Tags are written only by the pusher
    (`stage` copies by digest, and re-tagging a digest elsewhere is not here).
  * Never run against a real registry in this package: the tests use a scripted
    transport and an in-process fake only. Whether a given registry answers an
    immutable-tag overwrite with 400, 403 or 409 is deliberately NOT relied on.

A self-contained, flat package (import name `komira_oci`). Depends on
komira_http (the transport, and the shared redirect policy), komira_crypto
(sha256, streaming and one-shot), komira_encoding (base64, for Basic auth),
komira_json (the JSON DOM, used only to DISCOVER descriptors, never to
re-serialize a manifest) and komira_async (BlockingRuntime).

Encapsulation: the public API exposes only typed values, owned
`String` / `List[UInt8]`, and the seam conformer structs. No UnsafePointer
crosses the module boundary; no wildcard origins; no unsafe_from_address.
"""

from .oci_ref import (
    MEDIA_TYPE_DOCKER_MANIFEST,
    MEDIA_TYPE_DOCKER_MANIFEST_LIST,
    MEDIA_TYPE_OCI_INDEX,
    MEDIA_TYPE_OCI_MANIFEST,
    OciImageRef,
    manifest_accept_header,
    media_type_is_index,
    parse_oci_ref,
)

from .oci_digest import (
    digest_of_bytes,
    validate_digest_format,
    verify_digest,
)

from .oci_auth import (
    OCI_AUTH_BASIC,
    OCI_AUTH_BEARER,
    OCI_AUTH_NONE,
    OciAuth,
)

from .oci_location import append_query, resolve_upload_location

from .oci_transport import (
    OCI_REGISTRY_PORT,
    HttpOciTransport,
    OciRequest,
    OciResponse,
    OciTransport,
    ScriptedOciTransport,
)

from .oci_copy import OciCopier, image_blob_digests

from .oci_layout_reader import (
    MAX_LAYOUT_DOCUMENT_BYTES,
    MAX_MONOLITHIC_BLOB_BYTES,
    LayoutBlob,
    OciLayout,
    read_oci_layout,
)

from .oci_push import (
    MAX_FORBIDDEN_RETRIES,
    MAX_SEND_ATTEMPTS,
    MAX_UPLOAD_SESSION_ATTEMPTS,
    PUSH_FAILED,
    PUSH_INDETERMINATE,
    PUSH_NOOP,
    PUSH_PARTIAL,
    PUSH_REFUSED,
    PUSH_TAG_ADDED,
    PUSH_UPLOADED,
    LayoutPusher,
    PushResult,
    push_outcome_name,
    validate_oci_tag,
)

# Test support (a stateful in-process registry; a real layout directory writer).
# Nothing production calls these.
from .oci_fake_registry import FakeOciRegistry
from .oci_layout_fixture import write_test_layout

from .oci_layout import layout_image_digest
