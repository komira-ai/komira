"""`komira_fs_registry` -- the live file systems a plan's descriptors stand
for, as one closed type.

- `fs_handle.mojo`: `FsHandleOver[C]` (a tag and one arm per file system,
  exactly one set) and `FsHandle`, the production handle; the arm types
  `LocalArm` (komira_fs's `LocalFs`) and `S3Arm[C]` (komira_objectstore_s3's
  `S3Fs`); `fs_is_registry_arm[FS]` and
  `fs_handle_from_typed_fs[FS]`, which move a concrete file system whose type
  is exactly an arm's into a handle; `fs_arm_tag_for_scheme`, which maps a
  descriptor's scheme code to the tag that serves it, or names the arm this
  build lacks, and `fs_arm_tag_for_descriptor`, its komira_plan_expr
  `FsDescriptorPod` form.
- `s3_connector.mojo`: `SchemeConnector[P, T]`, a plaintext or a TLS
  connector fixed when it is made, and its stream `SchemeStream`;
  `S3ProdConnector`, the production one; `s3_endpoint_is_plaintext`,
  `s3_connector_factory` and `s3_prod_arm`, which pick the plaintext side only
  for an `http://` endpoint.

A handle's tag is the descriptor's scheme code (`FS_SCHEME_FILE`,
`FS_SCHEME_S3`). The GCS and Azure codes are reserved: this build has no arm
for either. The registry that resolves descriptors to handles and dispatches
a plan over them belongs to the engine, which imports this package; nothing
here executes a plan. Nothing here reads the environment.
"""

from .fs_handle import (
    FsHandle,
    FsHandleOver,
    LocalArm,
    S3Arm,
    fs_arm_tag_for_descriptor,
    fs_arm_tag_for_scheme,
    fs_handle_from_typed_fs,
    fs_is_registry_arm,
)
from .s3_connector import (
    S3ProdConnector,
    SchemeConnector,
    SchemeStream,
    s3_connector_factory,
    s3_endpoint_is_plaintext,
    s3_prod_arm,
    s3_prod_plain_connector,
    s3_prod_tls_connector,
)
