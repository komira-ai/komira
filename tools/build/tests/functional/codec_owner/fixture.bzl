"""The planted tree of test 48 (the codec owner lint), as {path in the tree: file}.

The owners are the three directories of the root BUCK's `//:codec_owner`.
snappy_block.mojo declares `"snappy_uncompress"` and
`"snappy_max_compressed_length"`, each on the line after `external_call[`;
codec_libraries.mojo names the libzstd, libbz2 and liblzma sonames (`.so` and
`.dylib`) and imports komira_lz4 and komira_zlib (a parenthesised import, a
plain one and an alias); the layers name the liblz4 and libz sonames. So every
owner check is met, and none of their lines is a finding.

near.mojo, outside the owners, names each form where it is not a site: in
comment lines (indented or not) and a trailing comment, an import of
komira_compression and of packages whose names only start like the layers'
(`komira_zlib_extra`, `komira_lz4x`, alone, first in an `import a, b` list and,
as `komira_zlibx`, in its middle) or end like them (`my_komira_lz4`), an
import list inside a string, a snappy name as an identifier, inside a longer string, after
another character in the string or with `-`, and a codec library name with
no `.so` or `.dylib` after it or not at the start of the string.
functional/codec_owner/BUCK exports the files, so negative/codec_owner plants
its defects in the same tree.
"""

_DIR = "tests//functional/codec_owner:"

CODEC_OWNERS = [
    "src/komira_compression",
    "src/komira_lz4",
    "src/komira_zlib",
]

CODEC_TREE = {
    "src/komira_avro/near.mojo": _DIR + "near.txt",
    "src/komira_compression/codec_libraries.mojo": _DIR + "owner_libraries.txt",
    "src/komira_compression/snappy_block.mojo": _DIR + "owner_snappy.txt",
    "src/komira_lz4/codec.mojo": _DIR + "owner_lz4.txt",
    "src/komira_zlib/zlib_ffi.mojo": _DIR + "owner_zlib.txt",
}
