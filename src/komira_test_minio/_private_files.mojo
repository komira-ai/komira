# =============================================================================
# komira_test_minio/_private_files.mojo -- owner-only directories and files,
# removing a tree, and a file's sha256. Package-private helpers.
# =============================================================================
#
# An embedded MinIO's temporary directory holds a throwaway root credential, so it
# is created 0700 and every file in it 0600, with the mode set BEFORE any
# content is written. `_remove_tree` never follows a symbolic link: a link is
# unlinked, never descended into, so a link planted in the tree cannot make
# the cleanup delete something outside it.
#
# ⛔ NO MESSAGE CARRIES A PATH. Every path here is built from a caller's
# value -- the temporary root, the run id, the binary given by
# `--test-minio-binary` -- and a test's output can land in a public log. A
# refusal names the ROLE of the file (`what`, a fixed phrase the caller
# passes) and never where it is.
# =============================================================================

from std.os import listdir, mkdir, remove, rmdir
from std.os.path import isdir, islink, lexists

from ._sys import _chmod
from komira_crypto import hex_lower_array_32, sha256


def _make_private_dir(path: String, what: String) raises:
    """Create `path` with mode 0700. Refuses a path that already exists.
    `what` names the directory's role in a message; `path` never appears."""
    if lexists(path):
        raise Error("refusing to reuse an existing " + what)
    try:
        mkdir(path, 0o700)
    except:
        raise Error("cannot create " + what)
    if not _chmod(path, 0o700):
        raise Error("cannot set mode 0700 on " + what)


def _write_private_file(path: String, content: String, what: String) raises:
    """Create `path` with mode 0600, then write `content`. Refuses a path
    that already exists. `what` names the file's role in a message; neither
    `path` nor the content is ever part of one."""
    if lexists(path):
        raise Error("refusing to overwrite an existing " + what)
    try:
        with open(path, "w") as f:
            f.write("")
    except:
        raise Error("cannot create " + what)
    if not _chmod(path, 0o600):
        raise Error("cannot set mode 0600 on " + what)
    try:
        with open(path, "w") as f:
            f.write(content)
    except:
        raise Error("cannot write " + what)


def _remove_tree(path: String) -> Bool:
    """Remove `path` and everything under it, never following a link.
    Returns True when nothing is left at `path`."""
    try:
        if islink(path):
            remove(path)
        elif isdir(path):
            for name in listdir(path):
                _ = _remove_tree(path + "/" + name)
            rmdir(path)
        elif lexists(path):
            remove(path)
    except:
        pass
    return not lexists(path)


def _sha256_file_hex(path: String, what: String) raises -> String:
    """The lowercase hex sha256 of the file at `path`. A file that cannot be
    read raises `cannot read <what>`; `path` is never part of the message."""
    var bytes: List[UInt8]
    try:
        with open(path, "r") as f:
            bytes = f.read_bytes()
    except:
        raise Error("cannot read " + what)
    return hex_lower_array_32(sha256(Span(bytes)))
