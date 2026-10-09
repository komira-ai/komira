# =============================================================================
# kci_gcp_emulator/emu_serve.mojo: one request in, one answer out.
# =============================================================================
#
# The service is chosen by the request's Host header, each an IP literal
# (emu_state.mojo), so a client pointed at the wrong service is answered
# 404, never served by the right one by accident:
#   IAM_HOST        the IAM paths (emu_iam.mojo);
#   CRM_HOST        Cloud Resource Manager v3: POST
#                   /v3/projects/<p>:getIamPolicy and :setIamPolicy, the
#                   project's policy (emu_policy.mojo);
#   RUN_HOST        the Cloud Run job paths (emu_run.mojo);
#   TOKENINFO_HOST  POST /tokeninfo: the principal of `EMU_TOKEN`
#                   (`EMU_DEPLOYER`), 400 invalid_token for any other.
# Every API request must carry `Authorization: Bearer <EMU_TOKEN>`; any
# other is 401 UNAUTHENTICATED. A route that raises (a malformed body) is
# 400 INVALID_ARGUMENT.
# =============================================================================

from kci_gcp_emulator.emu_http import EmuRequest, EmuResponse, failure, ok, percent_decode
from kci_gcp_emulator.emu_iam import serve_iam
from kci_gcp_emulator.emu_policy import get_policy, set_policy
from kci_gcp_emulator.emu_run import serve_run
from kci_gcp_emulator.emu_state import (
    CRM_HOST,
    EMU_DEPLOYER,
    EMU_TOKEN,
    IAM_HOST,
    RUN_HOST,
    TOKENINFO_HOST,
    GcpEmulator,
)


def _token_of_form(body: String) -> String:
    var pairs = body.split("&")
    for i in range(len(pairs)):
        var pair = String(pairs[i])
        if pair.startswith("access_token="):
            return percent_decode(String(pair[byte=13 : pair.byte_length()]), True)
    return String("")


def _tokeninfo(req: EmuRequest) -> EmuResponse:
    if req.method != "POST" or req.path != "/tokeninfo":
        return failure(404, String("no token-information path ") + req.path)
    if _token_of_form(req.body) != EMU_TOKEN:
        return EmuResponse(400, String("Bad Request"), String("{\"error\":\"invalid_token\",\"error_description\":\"Invalid Value\"}"))
    return ok(
        String("{\"azp\":\"1122\",\"aud\":\"1122\",\"scope\":\"https://www.googleapis.com/auth/cloud-platform\",")
        + String("\"expires_in\":\"3599\",\"email\":\"") + String(EMU_DEPLOYER)
        + String("\",\"email_verified\":\"true\"}")
    )


def _crm(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var base = String("/v3/projects/") + emu.project
    var resource = emu.project_resource()
    if req.method == "POST" and req.path == base + String(":getIamPolicy"):
        return get_policy(emu, resource)
    if req.method == "POST" and req.path == base + String(":setIamPolicy"):
        return set_policy(emu, resource, req.body)
    return failure(404, String("no Resource Manager path ") + req.path)


def serve(mut emu: GcpEmulator, req: EmuRequest) -> EmuResponse:
    emu.requests += 1
    if req.host == TOKENINFO_HOST:
        return _tokeninfo(req)
    if req.host != IAM_HOST and req.host != CRM_HOST and req.host != RUN_HOST:
        return failure(404, String("the emulator serves no host ") + req.host)
    if req.authorization != String("Bearer ") + String(EMU_TOKEN):
        return failure(401, String("Request had invalid authentication credentials"))
    try:
        if req.host == IAM_HOST:
            return serve_iam(emu, req)
        if req.host == CRM_HOST:
            return _crm(emu, req)
        return serve_run(emu, req)
    except e:
        return failure(400, String("emulator: ") + String(e))
