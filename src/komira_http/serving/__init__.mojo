# =============================================================================
# src/komira_http/serving/__init__.mojo — the per-cloud serving seam.
# =============================================================================
#
# MULTICLOUD PHASE 1 FOUNDATION. `serving/` holds the `ServerlessEntry` trait —
# a per-cloud serving driver, generic over ANY `RequestDispatcher`, where each
# cloud packages its own `Runtime` — so a per-app binary `main` becomes trivial
# (`GcpServerlessEntry().serve(build_my_app_router())`).
#
# Today: the trait + the Cloud Run conformer (`GcpServerlessEntry`). Future
# conformers (`AwsServerlessEntry` for Lambda, `AzureServerlessEntry`) land
# beside them.
# =============================================================================

from .serverless_entry import (
    DEFAULT_SERVE_PORT,
    GcpServerlessEntry,
    ServerlessEntry,
    parse_serve_port,
    serve_one_iteration_chained_over,
    serve_one_iteration_over,
)
