//! `aws-client-gen`: a validated botocore model, an operation list and an
//! overrides manifest in, one Mojo client module out.

use std::path::PathBuf;

use komira_proto_codegen::aws_in::lower_aws_service;
use komira_proto_codegen::emit_aws::{emit_aws_client, AwsEmitOptions};
use komira_proto_codegen::json::parse;
use komira_proto_codegen::overrides::AwsOverrides;

struct Args {
    model: PathBuf,
    service: String,
    operations: Vec<String>,
    module: String,
    out: PathBuf,
    overrides: Option<PathBuf>,
    hand_srcs: Vec<PathBuf>,
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
    let model_text = std::fs::read_to_string(&args.model)
        .map_err(|e| format!("read {}: {e}", args.model.display()))?;
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

    let lowering = lower_aws_service(
        &model,
        &args.service,
        &args.operations,
        &args.model.display().to_string(),
        &format!("aws.{}", args.service),
    )?;

    let (_, src) = emit_aws_client(&lowering, &overrides, &args.module, args.options)?;

    if src.trim().is_empty() {
        return Err(format!(
            "the emitter produced an EMPTY module for `{}`. Exit 0 with no bytes is \
             the one failure an exit code cannot carry, so it is checked here.",
            args.service
        ));
    }
    if let Some(dir) = args.out.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    std::fs::write(&args.out, &src)
        .map_err(|e| format!("write {}: {e}", args.out.display()))?;

    let f = &lowering.model.files[0];
    Ok(format!(
        "aws-client-gen: {} {} -> {} ({} operations, {} messages, {} enums, {} \
         overrides, {} bytes)",
        args.service,
        lowering.service.protocol,
        args.out.display(),
        args.operations.len(),
        f.messages.len(),
        f.enums.len(),
        overrides.len(),
        src.len()
    ))
}

fn parse_args() -> Result<Args, String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut model = None;
    let mut service = None;
    let mut operations: Vec<String> = Vec::new();
    let mut module = None;
    let mut out = None;
    let mut overrides = None;
    let mut hand_srcs = Vec::new();
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
            "--service" => service = Some(take(&mut i)?),
            "--module" => module = Some(take(&mut i)?),
            "--out" => out = Some(PathBuf::from(take(&mut i)?)),
            "--overrides" => overrides = Some(PathBuf::from(take(&mut i)?)),
            "--hand-src" => hand_srcs.push(PathBuf::from(take(&mut i)?)),
            "--emit-model-json" => options.emit_model_json = true,
            "--pure-only" => options.pure_only = true,
            "--operations" => {
                operations = take(&mut i)?
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect();
            }
            other => return Err(format!("unknown argument `{other}`")),
        }
        i += 1;
    }
    if operations.is_empty() {
        return Err(
            "--operations is MANDATORY and may not be empty. This generator is \
             operation-scoped by design: 77 of 741 operations are used across the \
             hand-written clients it replaces (10.4%), and emitting a whole service \
             is ~9.6x the code we use on a build that already OOMs on co-compile \
             mass. Name the operations."
                .into(),
        );
    }
    Ok(Args {
        model: model.ok_or("--model is required")?,
        service: service.ok_or("--service is required")?,
        operations,
        module: module.ok_or("--module is required")?,
        out: out.ok_or("--out is required")?,
        overrides,
        hand_srcs,
        options,
    })
}
