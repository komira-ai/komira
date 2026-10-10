"""`komira_source_url` -- the source a URL names, which a surface maps
before it builds a plan.

- `source_url.mojo`: `source_scheme_for_url`, a URL's prefix (`file://` or
  a bare path, `s3://`, `gs://`, `az://`, `abfs[s]://`, an Azure Blob
  `https://` host) to komira_plan_expr's `FS_SCHEME_*` code, refusing every
  other prefix; `check_source_scheme` and `check_source_descriptor`, which
  hold a code a plan already carries to the same four.

Surfaces (SQL, the DataFrame APIs) call it; a physical-plan package does
not depend on it. Nothing here reads the environment.
"""

from .source_url import (
    check_source_descriptor,
    check_source_scheme,
    source_scheme_for_url,
)
