"""What every language package that carries libkomira's native directory
(`//src/so:libkomira[dist]`) states about it, in one place: the Python wheel
(python/BUCK) and the npm platform packages (node/BUCK) load it.

    DIST_NATIVE_NEEDS     per platform row, the bounds the directory's
                          libraries are held to (`os_floor`, `max_glibcxx`,
                          `max_cxxabi`), as `wheel_file` and `npm_tarball`
                          take them
    DIST_LICENSE_FILES    {file name: file}: komira's LICENSE and NOTICE, the
                          licences of the third-party code in the native
                          owners, and the Mojo runtime's licence texts
    DIST_MODULAR_LICENSE_FILES, DIST_THIRD_PARTY_LICENSE_FILES
                          the last two groups on their own
    DIST_LICENSE_EXPRESSION
                          the SPDX expression of a package carrying them
"""

# What the Mojo runtime libraries need, per platform, above what komira's own
# files need (the platform row's `os_floor` is the floor of what the
# repository links): libAsyncRTRuntimeGlobals.so needs GLIBC_2.35,
# libKGENCompilerRTShared.so GLIBCXX_3.4.30 and CXXABI_1.3.11 (src/so/README.md,
# the table of libkomira_elf_report), within what manylinux_2_35 lets a wheel
# need from the host. A platform that joins names its own row here; the
# package rules refuse a package whose files need more.
DIST_NATIVE_NEEDS = {
    "linux-x86_64": {
        "max_cxxabi": "1.3.11",
        "max_glibcxx": "3.4.30",
        "os_floor": "glibc-2.35",
    },
    # No bounds of its own: the floor is the row's macOS, 11.0, and the
    # package rules refuse a Mach-O member that needs a newer macOS.
    "darwin-arm64": {},
}

# The licence texts of the pinned Mojo compiler package the runtime libraries
# come from, unmodified (third_party/modular/BUCK).
DIST_MODULAR_LICENSE_FILES = {
    "MODULAR_LICENSE": "komira//third_party/modular:mojo_compiler_licenses[info/licenses/LICENSE]",
    "MODULAR_THIRD_PARTY_NOTICES": "komira//third_party/modular:mojo_compiler_licenses[info/licenses/Third-Party-Notices]",
}

# The licence texts of the third-party code compiled into the native owner
# libraries libkomira links (NOTICE, "Third-party code inside the native
# files"), extracted unmodified from the pinned source archives.
DIST_THIRD_PARTY_LICENSE_FILES = {
    "AWS_LC_LICENSE": "komira//third_party/aws-lc:src[LICENSE]",
    "S2N_TLS_LICENSE": "komira//third_party/s2n-tls:src[LICENSE]",
}

# komira's licence and notice, then the two groups above.
DIST_LICENSE_FILES = {
    "LICENSE": "komira//:LICENSE",
    "NOTICE": "komira//:NOTICE",
} | DIST_THIRD_PARTY_LICENSE_FILES | DIST_MODULAR_LICENSE_FILES

# komira's own files are Apache-2.0; the Mojo runtime libraries are Modular's,
# under the licence their package declares (`LicenseRef-Modular-Proprietary`,
# the Modular Community License Terms in MODULAR_LICENSE).
DIST_LICENSE_EXPRESSION = "Apache-2.0 AND LicenseRef-Modular-Proprietary"
