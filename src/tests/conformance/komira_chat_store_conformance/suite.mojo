# =============================================================================
# komira_chat_store_conformance/suite.mojo -- every check, run against one
#   target, every failure named in one error.
# =============================================================================

from .checks_directory import (
    check_channels_and_members,
    check_dms,
    check_erasure,
    check_erasure_retry,
    check_files,
    check_mention_paging,
    check_read_state_and_mentions,
    check_users,
)
from .checks_timeline import (
    check_abandoned_send_leaves_no_hole,
    check_edit_and_delete,
    check_edit_racing_delete,
    check_idempotent_send,
    check_page_size_refused,
    check_paging,
    check_seq_interleaving,
    check_threads,
)
from .targets import ChatTarget


def run_chat_suite[T: ChatTarget](mut t: T) raises:
    """Run every check against `t`; raises naming each one that failed."""
    var failures = String()
    var ran = 16
    try:
        check_seq_interleaving[T](t)
    except e:
        failures += String("seq_interleaving: ") + String(e) + String("\n")
    try:
        check_abandoned_send_leaves_no_hole[T](t)
    except e:
        failures += String("abandoned_send_leaves_no_hole: ") + String(e) + String("\n")
    try:
        check_idempotent_send[T](t)
    except e:
        failures += String("idempotent_send: ") + String(e) + String("\n")
    try:
        check_paging[T](t)
    except e:
        failures += String("paging: ") + String(e) + String("\n")
    try:
        check_page_size_refused[T](t)
    except e:
        failures += String("page_size_refused: ") + String(e) + String("\n")
    try:
        check_threads[T](t)
    except e:
        failures += String("threads: ") + String(e) + String("\n")
    try:
        check_edit_and_delete[T](t)
    except e:
        failures += String("edit_and_delete: ") + String(e) + String("\n")
    try:
        check_edit_racing_delete[T](t)
    except e:
        failures += String("edit_racing_delete: ") + String(e) + String("\n")
    try:
        check_users[T](t)
    except e:
        failures += String("users: ") + String(e) + String("\n")
    try:
        check_channels_and_members[T](t)
    except e:
        failures += String("channels_and_members: ") + String(e) + String("\n")
    try:
        check_dms[T](t)
    except e:
        failures += String("dms: ") + String(e) + String("\n")
    try:
        check_read_state_and_mentions[T](t)
    except e:
        failures += String("read_state_and_mentions: ") + String(e) + String("\n")
    try:
        check_mention_paging[T](t)
    except e:
        failures += String("mention_paging: ") + String(e) + String("\n")
    try:
        check_files[T](t)
    except e:
        failures += String("files: ") + String(e) + String("\n")
    try:
        check_erasure[T](t)
    except e:
        failures += String("erasure: ") + String(e) + String("\n")
    try:
        check_erasure_retry[T](t)
    except e:
        failures += String("erasure_retry: ") + String(e) + String("\n")
    if failures.byte_length() > 0:
        raise Error(t.name() + String(": checks failed:\n") + failures)
    print(t.name() + String(": ") + String(ran) + String(" checks passed"))
