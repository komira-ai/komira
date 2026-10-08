# =============================================================================
# kci_publish_oci -- the OCI image arm of a PUBLISH step: one verified OCI
#   layout pushed to one registry repository, tagged with the revision.
# =============================================================================
#
#   arm.mojo  `publish_layout` over komira_oci's LayoutPusher: kci's checks
#             (full revision, released platform, the layout's own os/arch is
#             the step's), `--plan`, and the push's end state as a
#             kci_api outcome and error id; `record_image_publish`
#
# Not wired into `kci run` yet: an image step needs a cell, which is the
# deploy side (arm.mojo's header).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_publish_oci.arm import ARTIFACT_TYPE_OCI, ImagePublish, publish_layout, record_image_publish
