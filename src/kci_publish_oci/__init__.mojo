# =============================================================================
# kci_publish_oci -- the OCI image arm of a PUBLISH step: one verified OCI
#   layout pushed to one registry repository, tagged with the revision.
# =============================================================================
#
#   arm.mojo  `publish_layout` over komira_oci's LayoutPusher: kci's checks
#             (full revision, released platform, the layout's manifest
#             digest is the release set's, the layout's own os/arch is the
#             step's), `--plan`, and the push's end state as a kci_api
#             outcome and error id; `record_image_publish`
#
# `kci run` calls it for a PUBLISH step into a cell (kci_cli
# cell_publish.mojo).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_publish_oci.arm import ARTIFACT_TYPE_OCI, ImagePublish, publish_layout, record_image_publish
