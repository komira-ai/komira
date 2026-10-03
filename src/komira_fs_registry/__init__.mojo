"""`komira_fs_registry` -- the live file systems a plan's descriptors stand
for, as one closed type.

- `fs_handle.mojo`: `FsHandleOver[C]` (a tag and one arm per file system,
  exactly one set) and `FsHandle`, the production handle; the arm types
  `LocalArm` (komira_fs's `LocalFs`) and `S3Arm[C]` (komira_objectstore_s3's
  `S3Fs`), and `S3ProdConnector`; `fs_is_registry_arm[FS]` and
  `fs_handle_from_typed_fs[FS]`, which wrap a concrete file system whose type
  is exactly an arm's; `fs_arm_tag_for_descriptor`, which maps a
  komira_plan_expr `FsDescriptorPod` to the tag that serves it, or names the
  arm this build lacks.

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
    S3ProdConnector,
    fs_arm_tag_for_descriptor,
    fs_handle_from_typed_fs,
    fs_is_registry_arm,
)
