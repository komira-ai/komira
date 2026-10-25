"""The transition ledger: generated libraries still built from the generator.

`mojo_aws_client`, `mojo_gcp_client`, `mojo_proto_library` and
`mojo_db_proto_library` build a library from its committed directory
`generated/<name>/` (defs.bzl). A library listed here has no committed
directory yet and is built from the generator, as every one was before; it has
no `<name>_fresh`. This is a switch with an end: the list only shrinks, and
when it is empty the code that builds from the generator is deleted.

To migrate a library: delete its line here and lower `max` of `:transition` in
BUCK by one, run
`./buck2 run komira//tools/build/gen:regen -- <library target>`, commit the
directory. A line for a library that has a committed directory is an error at
load. Never add a line: a new generated library starts committed.

Keep the lines sorted (`:transition_lint`).
"""

UNMIGRATED = [
    "komira//src/kci_artifact_proto:kci_artifact_proto",
    "komira//src/kci_deploy_model_proto:kci_deploy_model_proto",
    "komira//src/kci_manifest_proto:kci_manifest_proto",
    "komira//src/kci_resource_proto:kci_resource_proto",
    "komira//src/komira_broker_proto:komira_broker_proto",
    "komira//src/komira_calendar_proto:komira_calendar_proto",
    "komira//src/komira_chat_proto:komira_chat_proto",
    "komira//src/komira_contacts_proto:komira_contacts_proto",
    "komira//src/komira_crm_proto:komira_crm_proto",
    "komira//src/komira_job_report_proto:komira_job_report_proto",
    "komira//src/komira_managed_mail_proto:komira_managed_mail_proto",
    "komira//src/komira_proto_codec:copy_hazard_proto",
    "komira//src/komira_proto_codec:implicit_presence_proto",
    "komira//src/komira_supervisor_proto:komira_supervisor_proto",
    "komira//src/komira_wkt:value_null_proto",
    "komira//tools/build/proto-codegen/aws_endpoint_rules:endpoint_bindings",
    "komira//tools/build/proto-codegen/aws_query:komira_aws_tiny_ec2",
    "komira//tools/build/proto-codegen/aws_query:komira_aws_tiny_query",
    "komira//tools/build/proto-codegen/aws_query:komira_aws_tiny_query_client",
    "komira//tools/build/proto-codegen/aws_rest_json:komira_aws_tiny_rest",
    "komira//tools/build/proto-codegen/aws_rest_xml:komira_aws_tiny_xml",
    "komira//tools/build/proto-codegen/gcp_grpc:komira_gcp_tiny_grpc",
    "komira//tools/build/proto-codegen/gcp_rest:komira_gcp_nohost_rest",
    "komira//tools/build/proto-codegen/routes:komira_routes_fixture_messages",
    "tests//functional/aws_client_mode:komira_aws_logs_client",
    "tests//functional/mojo_aws_client:komira_aws_logs",
    "tests//functional/mojo_aws_client:komira_aws_logs_hand",
    "tests//functional/mojo_gcp_client:komira_gcp_shop",
    "tests//functional/mojo_gcp_client:komira_gcp_shop_grpc_messages",
    "tests//functional/mojo_gcp_client:komira_gcp_shop_own_renamed",
    "tests//functional/mojo_gcp_client:komira_gcp_shop_renamed",
    "tests//functional/mojo_gcp_client:komira_gcp_shop_roots",
    "tests//functional/proto:person_proto",
    "tests//functional/proto:roster_proto",
    "tests//functional/proto:tasks_db",
    "tests//functional/proto:team_proto",
    "tests//negative/mojo_aws_client:caller_test_red",
    "tests//negative/mojo_aws_client:env_read_backtick_hash",
    "tests//negative/mojo_aws_client:env_read_backtick_quote",
    "tests//negative/mojo_aws_client:env_read_backtick_triple",
    "tests//negative/mojo_aws_client:env_read_compound",
    "tests//negative/mojo_aws_client:env_read_continuation",
    "tests//negative/mojo_aws_client:env_read_cr",
    "tests//negative/mojo_aws_client:env_read_crlf_continuation",
    "tests//negative/mojo_aws_client:env_read_escaped_quote",
    "tests//negative/mojo_aws_client:env_read_ff",
    "tests//negative/mojo_aws_client:env_read_hand",
    "tests//negative/mojo_aws_client:env_read_home",
    "tests//negative/mojo_aws_client:env_read_import_as",
    "tests//negative/mojo_aws_client:env_read_indented",
    "tests//negative/mojo_aws_client:env_read_raw_quote",
    "tests//negative/mojo_aws_client:env_read_semicolon",
    "tests//negative/mojo_aws_client:env_read_std_os",
    "tests//negative/mojo_aws_client:env_read_t_rt",
    "tests//negative/mojo_aws_client:env_read_t_string",
    "tests//negative/mojo_aws_client:env_read_t_tr",
    "tests//negative/mojo_aws_client:env_read_t_upper",
    "tests//negative/mojo_aws_client:env_read_triple_escape",
    "tests//negative/mojo_aws_client:env_read_vt",
    "tests//negative/mojo_gcp_client:caller_test_red",
    "tests//negative/mojo_gcp_client:rest_reaches_plugin",
    "tests//negative/proto:person_renamed_proto",
    "tests//negative/proto:roster_full_bundle",
    "tests//negative/proto:tasks_db_wrong_outs",
    "tests//negative/proto:team_unbundled_proto",
]
