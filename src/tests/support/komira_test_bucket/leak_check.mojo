# =============================================================================
# komira_test_bucket/leak_check.mojo -- did THIS run leave anything behind?
# =============================================================================
#
# Lists `runs/<run_id>/` and nothing wider:
#   * nothing listed           -> CLEAN
#   * anything listed          -> LEAK, naming each key relative to the prefix
#   * the listing raised       -> CANNOT_TELL ("found nothing to look at" and
#                                 "found nothing" must not be the same answer)
#   * an empty or invalid id   -> CANNOT_TELL, refused before any call: an
#                                 empty id would turn the prefix into the
#                                 whole run area, i.e. every other run
#
# Other runs' objects are never counted: the trailing `/` of the prefix keeps
# run `...-ab` from matching run `...-abc`, and a key a misbehaving client
# returns from outside the prefix is ignored rather than charged to this run.
# "Outside" includes a key that starts with the prefix but holds a `..`
# segment after it (`runs/<id>/../other`): a server that normalises paths
# resolves it to another run's key, so it is neither charged nor deleted
# (`_key_in_run`, shared with the teardown).
#
# A teardown's re-list is this same check (`_leak_check_prefix`).
# =============================================================================

from komira_validation_run.validation_run_tag import is_valid_validation_run_id

from komira_test_verdict import Verdict

from ._redact import _Redactor
from .store import RUN_PREFIX, ObjectStoreClient, StoreTarget


def _run_prefix_for(run_id: String) -> String:
    return String(RUN_PREFIX) + run_id + "/"


def _key_in_run(key: String, prefix: String) -> Bool:
    """True when `key` is under `prefix` and nothing after the prefix can
    climb out of it (no `..` segment). The teardown deletes, and the leak
    check charges, only keys for which this holds."""
    if not key.startswith(prefix):
        return False
    var n = prefix.byte_length()
    for seg in String(key[byte=n:]).split("/"):
        if seg == "..":
            return False
    return True


def _leak_check_prefix[S: ObjectStoreClient](
    prefix: String, mut client: S, redactor: _Redactor
) -> Verdict:
    """The check over an already-bound client."""
    var v = Verdict()
    var keys = List[String]()
    try:
        client.list_keys(prefix, keys)
    except e:
        v.add_cannot_tell("list_keys: " + redactor.scrub(String(e)))
        return v^
    var n = prefix.byte_length()
    for k in keys:
        if not _key_in_run(k, prefix):
            continue
        if k.byte_length() == n:
            # An object named exactly the prefix (a "directory marker").
            v.add_residue(String("(the prefix itself)"))
        else:
            v.add_residue(String(k[byte=n:]))
    return v^


def leak_check[S: ObjectStoreClient](
    run_id: String, target: StoreTarget, mut client: S
) -> Verdict:
    """Bind `client` (unbound; this call binds it) to `target` and list this
    run's prefix. See the module header for the verdicts."""
    var redactor = _Redactor(target.endpoint, target.bucket, target.credentials_file)
    if run_id.byte_length() == 0 or not is_valid_validation_run_id(run_id):
        var v = Verdict()
        v.add_cannot_tell(
            String("leak_check: refused an empty or invalid run id; it would list beyond one run")
        )
        return v^
    try:
        client.bind(target)
    except e:
        var v = Verdict()
        v.add_cannot_tell("bind: " + redactor.scrub(String(e)))
        return v^
    return _leak_check_prefix(_run_prefix_for(run_id), client, redactor)
