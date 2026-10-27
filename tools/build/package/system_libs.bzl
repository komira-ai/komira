"""The system libraries a komira Mojo package may open at run time, by soname,
and the conda-forge requirement of the package that ships each.

Each requirement is the conda-forge package that installs `lib/<soname>`,
bounded below by a release that ships that soname and above by the next major
version, where a soname change would come.

kci's closure checks (BUILD's `undeclared_requirements` and PUBLISH's
`require_closure`) accept a library's requirement on a package outside the
release set only when it is byte-equal to a requirement here. kci compiles its
own copy (src/kci_release_set/system_libs.mojo); its welded test reads this
table through `//tools/build/package:system_libs` (system_libs_record.bzl) and
fails while the two differ, so a row changed here is changed there in the same
commit.

A library declares the sonames it opens (`mojo_library(dlopen = [...])`,
tools/build/mojo/dlopen.bzl); a declaration this table lacks refuses its conda
package. `komira_pack conda` writes each declared soname's requirement into the
package's `depends`, byte-equal to its row here, and refuses a library whose
sources open a soname it does not declare (packaging/conda/README.md).

Each name was checked against conda-forge's channel (linux-64, read on
2026-10-10): the latest build and the lower bound of each row ship
`lib/<soname>`. `libzlib` is library-only. conda-forge publishes no
library-only package for lz4 (`liblz4`), zstd (`libzstd`) or bzip2
(`libbzip2`), so those rows keep `lz4-c`, `zstd` and `bzip2`, which also
install command-line tools. For `liblzma.so.5` it publishes the library-only
`liblzma` (from 5.6.3 on linux-64), which `xz` itself now requires; the row
still says `xz` until its library (komira_compression) declares it. `snappy`
ships the library and the C header (`lib/libsnappy.so.1`, linux-64, from 1.1.9
through the latest build); komira_compression opens it at run time.
"""

SYSTEM_LIBS = {
    "libbz2.so.1.0": "bzip2 >=1.0.8,<2",
    "liblz4.so.1": "lz4-c >=1.9.3,<2",
    "liblzma.so.5": "xz >=5.2.5,<6",
    "libsnappy.so.1": "snappy >=1.1.9,<2",
    "libz.so.1": "libzlib >=1.2.13,<2",
    "libzstd.so.1": "zstd >=1.5.2,<2",
}
