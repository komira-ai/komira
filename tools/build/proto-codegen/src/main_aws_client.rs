//! `aws-client-gen`: a validated botocore model, an operation list and an
//! overrides manifest in, one Mojo client module out, and optionally the
//! layout probe for that module.
//!
//! Every input is a flag; nothing is read from the environment.
//!
//! ```text
//! aws-client-gen --model <service-2.json> --model-sha256 <hex>
//!     --service <botocore id> --operations <Op>[,<Op>...]
//!     --module <name> --out <file.mojo>
//!     [--pure-only] [--emit-model-json] [--customization s3|route53]
//!     [--overrides <manifest> [--hand-src <file.mojo>]...]
//!     [--probe-out <_layout_probe.mojo> [--probe-import <dotted path>]]
//!     [--endpoint-rules <endpoint-rule-set-1.json> --partitions <partitions.json>]
//! ```
//!
//! `--endpoint-rules` and `--partitions` (botocore's ruleset for the service
//! and its partition table, always together) make the module resolve
//! endpoints through the ruleset: both are embedded in it, and the header
//! records the sha256 of each.
//!
//! `--customization s3` applies botocore's S3 response handling the model
//! does not state (`emit_aws::S3_CUSTOMIZATION`); it is refused unless the
//! model's serviceId is `S3` and its protocol is restXml.
//!
//! `--customization route53` applies botocore's Route 53 Id handling the
//! model does not state (`emit_aws::ROUTE53_CUSTOMIZATION`); it is refused
//! unless the model's serviceId is `Route 53` and its protocol is restXml.

use std::path::PathBuf;

use komira_proto_codegen::aws_in::lower_aws_service;
use komira_proto_codegen::emit_aws::{
    emit_aws_module_with_endpoints, emit_layout_probe, AwsEmitOptions, AwsEndpointRules,
    AwsProvenance, ROUTE53_CUSTOMIZATION, S3_CUSTOMIZATION,
};
use komira_proto_codegen::json::parse;
use komira_proto_codegen::overrides::AwsOverrides;
use komira_proto_codegen::sha256;

struct Args {
    model: PathBuf,
    model_sha256: String,
    service: String,
    operations: Vec<String>,
    module: String,
    out: PathBuf,
    overrides: Option<PathBuf>,
    hand_srcs: Vec<PathBuf>,
    probe_out: Option<PathBuf>,
    probe_import: Option<String>,
    endpoint_rules: Option<PathBuf>,
    partitions: Option<PathBuf>,
    options: AwsEmitOptions,
}

fn main() {
    match run() {
        Ok(msg) => eprintln!("{msg}"),
        Err(e) => {
            eprintln!("aws-client-gen: {e}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<String, String> {
    let args = parse_args()?;
    let model_bytes =
        std::fs::read(&args.model).map_err(|e| format!("read {}: {e}", args.model.display()))?;

    // The header records this digest, so it must be the digest of the bytes
    // the module was generated from.
    let got = sha256::hex(&model_bytes);
    if got != args.model_sha256 {
        return Err(format!(
            "{} has sha256 {got}, and --model-sha256 says {}. The model is not the \
             pinned one.",
            args.model.display(),
            args.model_sha256
        ));
    }
    let model_text = String::from_utf8(model_bytes)
        .map_err(|e| format!("{} is not UTF-8: {e}", args.model.display()))?;
    if model_text.trim().is_empty() {
        return Err(format!(
            "{} is EMPTY. A zero-byte model is a silent build failure three stages \
             downstream ('unexpected end of input'), so it is refused here.",
            args.model.display()
        ));
    }
    let model = parse(&model_text).map_err(|e| format!("{}: {e}", args.model.display()))?;

    let overrides = match &args.overrides {
        None => AwsOverrides::empty(),
        Some(p) => {
            let t = std::fs::read_to_string(p)
                .map_err(|e| format!("read {}: {e}", p.display()))?;
            AwsOverrides::parse_manifest(&t).map_err(|e| format!("{}: {e}", p.display()))?
        }
    };

    // The owner-symbol check runs BEFORE emission, so a manifest whose owner
    // nobody wrote fails naming the manifest rather than at every call site.
    if !overrides.is_empty() {
        let mut sources = Vec::new();
        for p in &args.hand_srcs {
            let t = std::fs::read_to_string(p)
                .map_err(|e| format!("read {}: {e}", p.display()))?;
            sources.push((p.display().to_string(), t));
        }
        overrides.check_symbols(&sources)?;
    }

    let endpoint_rules = match (&args.endpoint_rules, &args.partitions) {
        (Some(r), Some(p)) => {
            let rb = std::fs::read(r).map_err(|e| format!("read {}: {e}", r.display()))?;
            let pb = std::fs::read(p).map_err(|e| format!("read {}: {e}", p.display()))?;
            let rt = std::str::from_utf8(&rb)
                .map_err(|e| format!("{} is not UTF-8: {e}", r.display()))?;
            let pt = std::str::from_utf8(&pb)
                .map_err(|e| format!("{} is not UTF-8: {e}", p.display()))?;
            Some(
                AwsEndpointRules::parse(rt, &sha256::hex(&rb), pt, &sha256::hex(&pb))
                    .map_err(|e| format!("{} / {}: {e}", r.display(), p.display()))?,
            )
        }
        _ => None,
    };

    let lowering = lower_aws_service(
        &model,
        &args.service,
        &args.operations,
        &args.model.display().to_string(),
        &format!("aws.{}", args.service),
    )?;

    // The botocore data key: `botocore/data/<service>/<api version>/`.
    let model_key = format!("{}/{}", args.service, lowering.service.api_version);
    let emitted = emit_aws_module_with_endpoints(
        &lowering,
        &overrides,
        &args.module,
        args.options,
        Some(AwsProvenance {
            model_key: &model_key,
            model_sha256: &args.model_sha256,
        }),
        endpoint_rules.as_ref(),
    )?;

    if emitted.source.trim().is_empty() {
        return Err(format!(
            "the emitter produced an EMPTY module for `{}`. Exit 0 with no bytes is \
             the one failure an exit code cannot carry, so it is checked here.",
            args.service
        ));
    }
    // Build the probe before writing anything, so a refusal leaves no output.
    let probe = match &args.probe_out {
        None => None,
        Some(p) => {
            let import = args.probe_import.as_deref().unwrap_or(&args.module);
            Some((p, emit_layout_probe(&emitted, import)?))
        }
    };
    write(&args.out, &emitted.source)?;
    if let Some((p, text)) = &probe {
        write(p, text)?;
    }

    let f = &lowering.model.files[0];
    Ok(format!(
        "aws-client-gen: {} {} -> {} ({} operations, {} messages, {} enums, {} \
         overrides, {} bytes{}{})",
        args.service,
        lowering.service.protocol,
        args.out.display(),
        args.operations.len(),
        f.messages.len(),
        f.enums.len(),
        overrides.len(),
        emitted.source.len(),
        match &probe {
            Some(_) => format!(", probe of {} structs", emitted.structs.len()),
            None => String::new(),
        },
        match &endpoint_rules {
            Some(r) => format!(
                ", endpoint ruleset of {} parameters embedded in {} + {} bytes",
                r.params.len(),
                r.ruleset.len(),
                r.partitions.len()
            ),
            None => String::new(),
        }
    ))
}

fn write(path: &std::path::Path, text: &str) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    std::fs::write(path, text).map_err(|e| format!("write {}: {e}", path.display()))
}

fn parse_args() -> Result<Args, String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut model = None;
    let mut model_sha256 = None;
    let mut service = None;
    let mut operations: Option<Vec<String>> = None;
    let mut module = None;
    let mut out = None;
    let mut overrides = None;
    let mut hand_srcs = Vec::new();
    let mut probe_out = None;
    let mut probe_import = None;
    let mut endpoint_rules = None;
    let mut partitions = None;
    let mut options = AwsEmitOptions::default();
    let mut i = 0;
    while i < argv.len() {
        let take = |i: &mut usize| -> Result<String, String> {
            *i += 1;
            argv.get(*i)
                .cloned()
                .ok_or_else(|| format!("{} needs a value", argv[*i - 1]))
        };
        match argv[i].as_str() {
            "--model" => model = Some(PathBuf::from(take(&mut i)?)),
            "--model-sha256" => model_sha256 = Some(take(&mut i)?),
            "--service" => service = Some(take(&mut i)?),
            "--module" => module = Some(take(&mut i)?),
            "--out" => out = Some(PathBuf::from(take(&mut i)?)),
            "--overrides" => overrides = Some(PathBuf::from(take(&mut i)?)),
            "--hand-src" => hand_srcs.push(PathBuf::from(take(&mut i)?)),
            "--probe-out" => probe_out = Some(PathBuf::from(take(&mut i)?)),
            "--probe-import" => probe_import = Some(take(&mut i)?),
            "--endpoint-rules" => endpoint_rules = Some(PathBuf::from(take(&mut i)?)),
            "--partitions" => partitions = Some(PathBuf::from(take(&mut i)?)),
            "--emit-model-json" => options.emit_model_json = true,
            "--pure-only" => options.pure_only = true,
            "--customization" => {
                let c = take(&mut i)?;
                if c == S3_CUSTOMIZATION {
                    options.s3 = true;
                } else if c == ROUTE53_CUSTOMIZATION {
                    options.route53 = true;
                } else {
                    return Err(format!(
                        "--customization `{c}` is not one this generator has; the set is \
                         `{S3_CUSTOMIZATION}`, `{ROUTE53_CUSTOMIZATION}`"
                    ));
                }
            }
            "--operations" => {
                operations = Some(
                    take(&mut i)?
                        .split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(str::to_string)
                        .collect(),
                );
            }
            other => return Err(format!("unknown argument `{other}`")),
        }
        i += 1;
    }
    let operations = operations.unwrap_or_default();
    if operations.is_empty() {
        return Err(
            "--operations is MANDATORY and may not be empty. This generator is \
             operation-scoped: it emits only the operations a consumer calls, and \
             an empty list would emit a client with no verbs. Name the operations."
                .into(),
        );
    }
    let model_sha256 = model_sha256.ok_or("--model-sha256 is required")?;
    if model_sha256.len() != 64
        || !model_sha256
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(format!(
            "--model-sha256 `{model_sha256}` is not 64 lowercase hex digits"
        ));
    }
    if endpoint_rules.is_some() != partitions.is_some() {
        return Err(
            "--endpoint-rules and --partitions go together: the ruleset's aws.partition \
             reads the partition table"
                .into(),
        );
    }
    if probe_import.is_some() && probe_out.is_none() {
        return Err("--probe-import names the probe's import, so it needs --probe-out".into());
    }
    Ok(Args {
        model: model.ok_or("--model is required")?,
        model_sha256,
        service: service.ok_or("--service is required")?,
        operations,
        module: module.ok_or("--module is required")?,
        out: out.ok_or("--out is required")?,
        overrides,
        hand_srcs,
        probe_out,
        probe_import,
        endpoint_rules,
        partitions,
        options,
    })
}
