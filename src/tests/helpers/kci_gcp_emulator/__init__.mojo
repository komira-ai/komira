"""`kci_gcp_emulator`: a stateful, in-memory GCP REST emulator, test-only.

It answers what the GCP adapter (kci_cloud_gcp) sends, behind
komira_http_core's `Connector` (`EmulatorConnector`): no socket, no
resolver, no credential. One project in one region, with IAM service
accounts and their policies, the project's policy (Cloud Resource Manager
v3), Cloud Run jobs, and the token-information endpoint; real error
envelopes (google.rpc.Status: NOT_FOUND, ALREADY_EXISTS, ABORTED on a stale
policy etag, INVALID_ARGUMENT, UNAUTHENTICATED, DEADLINE_EXCEEDED).
Its state is open to a test, which plants objects and members out of band
and arms the race and fail-after hooks of a create (emu_state.mojo). It
proves a client against the emulator, not that GCP behaves like the
emulator.

Modules: emu_state (what the cloud holds, the hooks' keys, the counters),
emu_http (HTTP/1.1 server side, the error envelope), emu_iam, emu_policy,
emu_run (the routes), emu_serve (dispatch by host and the bearer check),
emu_stream (the connector and stream).
"""

from kci_gcp_emulator.emu_state import (
    CRM_HOST,
    EMU_DEPLOYER,
    EMU_TOKEN,
    IAM_HOST,
    OWNER_MEMBER,
    RUN_HOST,
    TOKENINFO_HOST,
    EmuAccount,
    EmuBinding,
    EmuJob,
    EmuPolicy,
    GcpEmulator,
)
from kci_gcp_emulator.emu_stream import EmulatorConnector, EmulatorStream
