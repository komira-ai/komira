"""`komira_oci` — a native OCI distribution client for image copies.

It performs a registry-to-registry, DIGEST-PRESERVING image copy over HTTPS.

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
  * Chunked/resumable blob upload. A monolithic PUT closes the session; layers
    that need chunking are a possible follow-on, not a silent gap.
  * Tag pushes, deletes, and garbage collection. `stage` copies by digest.

A self-contained, flat package (import name `komira_oci`). Depends on
komira_http (the transport, and the shared redirect policy), komira_crypto
(sha256), komira_json (the JSON DOM, used only to DISCOVER descriptors, never
to re-serialize a manifest) and komira_async (BlockingRuntime).

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

from .oci_transport import (
    OCI_REGISTRY_PORT,
    HttpOciTransport,
    OciRequest,
    OciResponse,
    OciTransport,
    ScriptedOciTransport,
)

from .oci_copy import OciCopier

from .oci_layout import layout_image_digest
