# =============================================================================
# iceberg_version.mojo — which metadata version is the table's current one.
# =============================================================================
#
# The file-based layout (the one Iceberg's own Hadoop-style tables use) names
# each metadata file `v<N>.metadata.json` and keeps a `version-hint.text` file
# holding the number of the latest one. The hint is a convenience: the object
# that COMMITS version N is `v<N>.metadata.json`, created with create-if-absent,
# so exactly one writer ever owns each N. A writer that stops after creating
# that file and before moving the hint has still committed: every metadata file
# it points at was written first.
#
# So the current version is the hint's number, then every higher version whose
# file exists. A reader and a writer that read it this way agree on the table's
# state even while the hint lags.
#
# Encapsulation: the store is taken by `ref`. ZERO UnsafePointer in any
# signature; ZERO wildcard origins.
# =============================================================================

from komira_objectstore.cas_manifest import is_not_found
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .iceberg_json_scan import parse_ascii_int


@always_inline
def metadata_dir(location: String) -> String:
    return location + "/metadata"


@always_inline
def pointer_key(location: String) -> String:
    return metadata_dir(location) + "/version-hint.text"


@always_inline
def metadata_json_key(location: String, version: Int) -> String:
    return metadata_dir(location) + "/v" + String(version) + ".metadata.json"


def read_hint_version[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](ref [o] store: Store, location: String) raises -> Int:
    """The number in `version-hint.text`, or 0 when the hint does not exist.

    Only a proven absence is 0: any other failure (permission, transport, a
    body that is not a number) raises, so a failure to read is never mistaken
    for a table that was never committed."""
    try:
        return parse_ascii_int(store.get(Path.parse(pointer_key(location))))
    except e:
        if is_not_found(String(e)):
            return 0
        raise e^


def version_exists[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](ref [o] store: Store, location: String, version: Int) raises -> Bool:
    """True iff `v<version>.metadata.json` exists (a proven absence is False)."""
    try:
        _ = store.head(Path.parse(metadata_json_key(location, version)))
        return True
    except e:
        if is_not_found(String(e)):
            return False
        raise e^


def current_version[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](ref [o] store: Store, location: String) raises -> Int:
    """The table's current metadata version: the hint's number, advanced past
    every higher version whose metadata file exists. 0 when nothing was ever
    committed."""
    var v = read_hint_version(store, location)
    while version_exists(store, location, v + 1):
        v += 1
    return v
