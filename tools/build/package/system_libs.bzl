"""The system libraries a komira Mojo package may open at run time, by soname,
and the conda-forge requirement of the package that ships each.

Each requirement is the conda-forge package that installs `lib/<soname>`,
bounded below by a release that ships that soname and above by the next major
version, where a soname change would come.

A library's requirement on a package outside the release set is accepted
only when it is byte-equal to a requirement here.

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
still says `xz` until its library (compression) declares it.
"""

SYSTEM_LIBS = {
    "libbz2.so.1.0": "bzip2 >=1.0.8,<2",
    "liblz4.so.1": "lz4-c >=1.9.3,<2",
    "liblzma.so.5": "xz >=5.2.5,<6",
    "libz.so.1": "libzlib >=1.2.13,<2",
    "libzstd.so.1": "zstd >=1.5.2,<2",
}

# The sonames of SYSTEM_LIBS a host of each platform row provides, for a
# package that carries libkomira's native directory (the Python wheel, the npm
# platform packages) and so has no conda requirement to install them: a soname
# libkomira's closure opens at run time that its platform's row lacks is a
# refusal of the directory (tools/build/package/libkomira/opens.bzl). The
# sonames are the Linux spellings `dlopen` declares; the code opens the same
# library under the platform's own name (`libzstd.dylib` on macOS).
#
# linux-x86_64: every row, as the wheel's audit
# (docs/design/wheel_licence_audit.md) takes every library it opens from the
# host; a soname the closure no longer opens is judged nowhere.
#
# darwin-arm64: libz, libbz2 and liblzma, the macOS system libraries under
# /usr/lib (libz.1.dylib, libbz2.1.0.dylib, liblzma.5.dylib, in the dyld shared
# cache). No test here loads libbz2 or liblzma on a Mac, so for those two the
# row records what macOS is known to ship, not something measured. macOS ships
# no libzstd and no liblz4: dyld's refusal of `libzstd.dylib` in the macOS
# wheel's install test says "not in dyld cache" for /usr/lib/libzstd.dylib.
HOST_LIBS = {
    "darwin-arm64": [
        "libbz2.so.1.0",
        "liblzma.so.5",
        "libz.so.1",
    ],
    "linux-x86_64": sorted(SYSTEM_LIBS.keys()),
}
