"""The system libraries komira's Mojo packages open at run time, by soname, and
the conda package that ships each (packaging/conda/README.md, "Libraries a
package opens at run time").

A library that opens one (`OwnedDLHandle("libzstd.so.1")`) lists the soname in
its `dlopen`:

    mojo_library(name = "komira_zlib", dlopen = ["libz.so.1"], ...)

and its conda package then requires the package named here. `komira_pack
conda` reads the sources and refuses the package unless the sonames a source
that opens a library names are exactly the ones declared, so the list cannot
drift from the code; a soname not in this table refuses the package when the
library is analysed.

Each requirement is the conda-forge package that installs `lib/<soname>`,
bounded below by a release that ships that soname and above by the next major
version, where a soname change would come.
"""

SYSTEM_LIBS = {
    "libbz2.so.1.0": "bzip2 >=1.0.8,<2",
    "liblz4.so.1": "lz4-c >=1.9.3,<2",
    "liblzma.so.5": "xz >=5.2.5,<6",
    "libz.so.1": "libzlib >=1.2.13,<2",
    "libzstd.so.1": "zstd >=1.5.2,<2",
}
