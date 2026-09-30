# =============================================================================
# komira_ci_params — THE GENERIC MANAGED-APP PARAMETER MECHANISM.
# =============================================================================
#
# One mechanism, THREE consumers that must not depend on each other:
#   * the DEPLOY renderer (komira_ci / the pipeline's deploy renderer) turns a
#     declaration + supplied values into the argv a revision runs with,
#   * the APP parses that argv at ONE site at startup, against the SAME
#     declaration,
#   * the CONTROL PLANE persists the resulting map OPAQUELY — names and values as
#     strings, no arm, enum, column or route per parameter.
#
# ZERO deps, by design: a shared contract with a dependency closure is not
# adoptable by all three sides, and two copies of a parameter contract is exactly
# the fork this mechanism exists to end.
#
# See `app_params.mojo` for the full model, the obligation vocabulary it shares
# with per-binary env contracts, and why the values travel in argv while secrets
# travel only as references.
# =============================================================================

from komira_ci_params.app_params import (
    PARAM_REQUIRED,
    PARAM_RUNNER_INJECTED,
    PARAM_OPTIONAL,
    param_obligation_label,
    param_obligation_is_required,
    PARAM_KIND_LITERAL,
    PARAM_KIND_REFERENCE,
    PARAM_KIND_SECRET_REFERENCE,
    param_kind_label,
    param_kind_is_reference,
    AppParamDecl,
    validate_param_name,
    validate_param_decls,
    find_param_decl,
    AppParamValue,
    literal_param,
    reference_param,
    secret_reference_param,
    find_param_value,
    render_app_params,
    AppParamBinding,
    parse_app_params,
    param_map_names,
    param_map_is_storable,
    APP_PARAM_CONFIG_PREFIX,
    app_param_config_key,
    is_app_param_config_key,
    app_param_name_from_config_key,
    encode_app_param_config_value,
    decode_app_param_config_value,
    collect_app_params_from_config,
    render_app_param_argv,
)
