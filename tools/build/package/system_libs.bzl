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

Nothing in the build writes these requirements yet: `komira_pack conda` still
refuses a library that opens a shared library by name (packaging/conda/README.md),
so no package carries one until the packer declares them.
"""

SYSTEM_LIBS = {
    "libbz2.so.1.0": "bzip2 >=1.0.8,<2",
    "liblz4.so.1": "lz4-c >=1.9.3,<2",
    "liblzma.so.5": "xz >=5.2.5,<6",
    "libz.so.1": "libzlib >=1.2.13,<2",
    "libzstd.so.1": "zstd >=1.5.2,<2",
}
