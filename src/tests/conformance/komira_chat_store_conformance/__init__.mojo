"""`komira_chat_store_conformance`: komira_chat_store's behaviour, written
once, generic over the backend, and run against each backend a build action
can run (test-only).

A backend supplies a `ChatTarget` (targets.mojo): a fresh chat database, and
a second connection to it. `run_chat_suite` runs every check against it:
seq allocation under an interleaved second writer and after an abandoned
send, idempotent send, paging, threads, edit and delete with redaction (and
an edit whose event lands after a delete of its message),
users, channels and members, DMs, read state and mentions, files, and
logical erasure.
"""

from .probes import CRASH_TEXT, INTERLEAVED_BODY, CrashProbe, InterleaveProbe
from .suite import run_chat_suite
from .targets import ChatTarget, Rt, T0, new_rt
