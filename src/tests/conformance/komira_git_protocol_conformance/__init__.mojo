"""`komira_git_protocol_conformance` -- test-only: komira_git's protocol
state machines against the pinned git's transcripts (capture.sh; the BUCK
file says how they are made).

`Scenario` loads one scenario; `TranscriptGraph` is its server repository as
a `CommitGraph`; `expect_bytes` compares komira_git's bytes with git's and
shows where they differ. `check_pack` is the protocol tests' check of a pack
received in a transcript.
"""

from .checks import GitPack, PushVerdicts, check_pack, push_verdicts, read_git_packfile
from .graph import TranscriptGraph
from .transcript import Connection, Scenario, expect_bytes, ids, minus, show
