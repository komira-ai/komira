# =============================================================================
# src/kci_publish/channel_state.mojo -- contract step 1's reads: what the
#   channel holds under each of the set's file names, read by DOWNLOAD, and
#   which package names it already holds.
# =============================================================================
#
# BY DOWNLOAD, NOT BY REPODATA. A repodata listing can lag an upload, and it
# can name a file that is not there; so a file's state is decided by fetching
# it and hashing the bytes (`read_file_state`):
#   fetched, our sha256      present-same
#   fetched, another sha256  present-different
#   404                      absent
#   anything else            cannot-tell (a 5xx, an auth refusal, a fault)
#
# NAMES come from the repodata listings (`kci_pkg_upload`'s
# `RegistrySet.package_names`) of every subdir the set publishes to and of
# `noarch`, with every file each one lists. A listing that was not read
# leaves `names_read` False, and the run cannot tell which names are new: it
# is never read as "no names". The listings are NOT the only evidence that a
# name is held: `plan.mojo`'s `is_held` also counts a set file that the
# download found present, since the listing can lag it.
#
# Encapsulation: owned values; the registry set is borrowed `mut` for the
# call. No pointer, no wildcard origin.
# =============================================================================

from kci_pkg_upload import (
    READ_ABSENT,
    READ_PRESENT,
    PkgTransport,
    RegistryCredential,
    RegistrySet,
    content_identity_of,
    read_kind_name,
)

from .plan import (
    STATE_ABSENT,
    STATE_CANNOT_TELL,
    STATE_DIFFERENT,
    STATE_SAME,
    ChannelRead,
    FileState,
    PublishTarget,
    listed_subdirs,
)


def read_file_state[T: PkgTransport, C: RegistryCredential](
    mut registry: RegistrySet[T, C], t: PublishTarget
) -> FileState:
    """One file's state, by download (see the file header). Never raises: a
    local fault is cannot-tell, naming it."""
    try:
        var f = registry.fetch(t.coordinate)
        if f.kind == READ_PRESENT:
            var got = content_identity_of(Span(f.bytes)).sha256_hex
            if got == t.sha256_hex:
                return FileState(STATE_SAME, String(""))
            return FileState(
                STATE_DIFFERENT,
                String("the channel serves sha256 ") + got + String(", ours is ") + t.sha256_hex,
            )
        if f.kind == READ_ABSENT:
            return FileState(STATE_ABSENT, String(""))
        return FileState(
            STATE_CANNOT_TELL,
            read_kind_name(f.kind)
            + String(" (HTTP ")
            + String(f.status)
            + String(") ")
            + f.detail,
        )
    except e:
        return FileState(STATE_CANNOT_TELL, String(e))


def read_channel[T: PkgTransport, C: RegistryCredential](
    mut registry: RegistrySet[T, C], targets: List[PublishTarget]
) -> ChannelRead:
    """Step 1: every file's state, then the names of every listed subdir.
    Never raises."""
    var out = ChannelRead()
    for i in range(len(targets)):
        out.states.append(read_file_state(registry, targets[i]))
    if len(targets) == 0:
        return out^
    ref c = targets[0].coordinate
    var subdirs = listed_subdirs(targets)
    var details = List[String]()
    for s in range(len(subdirs)):
        try:
            var listing = registry.package_names(c.substrate, c.repo, subdirs[s])
            if not listing.was_read():
                details.append(
                    subdirs[s]
                    + String(": ")
                    + read_kind_name(listing.kind)
                    + String(" (HTTP ")
                    + String(listing.status)
                    + String(") ")
                    + listing.detail
                )
                continue
            for k in range(len(listing.names)):
                if not out.holds_name(listing.names[k]):
                    out.names.append(listing.names[k].copy())
            for k in range(len(listing.files)):
                out.listed_files.append(subdirs[s] + String("/") + listing.files[k])
        except e:
            details.append(subdirs[s] + String(": ") + String(e))
    if len(details) > 0:
        out.names_read = False
        out.names = List[String]()
        out.listed_files = List[String]()
        out.names_detail = String("; ").join(details)
    return out^
