"""`kci_gcp_emulator`: a stateful, in-memory GCP REST emulator, test-only.

It answers what the GCP adapter (kci_cloud_gcp) sends, behind
komira_http_core's `Connector` (`EmulatorConnector`): no socket, no
resolver, no credential. One project in one region, with IAM service
accounts and their policies, the project's policy (Cloud Resource Manager
v3), Cloud Run jobs, and the token-information endpoint; real error
envelopes (google.rpc.Status: NOT_FOUND, ALREADY_EXISTS, ABORTED on a stale
policy etag, INVALID_ARGUMENT, UNAUTHENTICATED, DEADLINE_EXCEEDED).
`EmulatedGcpCloud` is the adapter over it with the conformance kit's hooks
(target.mojo), so the kit's every step runs the adapter's real wire code,
the steps that plant, race, fail and tamper included. It proves the
adapter against the emulator, not that GCP behaves like the emulator.

Modules: emu_state (what the cloud holds, the hooks' keys, the counters),
emu_http (HTTP/1.1 server side, the error envelope), emu_iam, emu_policy,
emu_run (the routes), emu_serve (dispatch by host and the bearer check),
emu_stream (the connector and stream), target (the kit target).
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
from kci_gcp_emulator.target import EmulatedAdapter, EmulatedGcpCloud, SharedSleeper, emulated_adapter, emulator_endpoints
