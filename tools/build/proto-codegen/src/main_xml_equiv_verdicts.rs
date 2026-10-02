//! `xml-equiv-verdicts`: the verdicts of `xml_equiv` over the XML bodies of
//! botocore's protocol conformance corpus, for a differential test of
//! another XML implementation against the same bodies.
//!
//! usage: xml-equiv-verdicts --corpus <dir> --protocol <p> [--protocol <p>...]
//!            --ignore-list <file> --out <file>
//!
//! The bodies are every non-empty request body (`serialized.body`) and
//! response body (`response.body`) of the cases of the named protocols that
//! botocore's ignore list does not skip, in corpus order. The output is tab
//! separated, one record per line:
//!
//!     body <key> <parses|raw>          for each body, in order
//!     pair <key-a> <key-b> <equal|differ>  for each unordered pair a < b
//!
//! `raw` is a body that is not XML (it is compared byte for byte, as
//! botocore compares one). A key is `<direction>/<file>#<id>`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use komira_proto_codegen::aws_conformance::{load_file, Corpus, Direction, IgnoreList};
use komira_proto_codegen::xml_equiv::{parse, xml_bodies_equivalent};

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if let Err(e) = run(&argv) {
        eprintln!("xml-equiv-verdicts: {e}");
        std::process::exit(1);
    }
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))
}

fn run(argv: &[String]) -> Result<(), String> {
    let mut corpus_dir: Option<PathBuf> = None;
    let mut protocols: BTreeSet<String> = BTreeSet::new();
    let mut ignore_list: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut it = argv.iter();
    while let Some(flag) = it.next() {
        let value = it
            .next()
            .cloned()
            .ok_or_else(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--corpus" => corpus_dir = Some(PathBuf::from(value)),
            "--protocol" => {
                if value.is_empty() || !protocols.insert(value.clone()) {
                    return Err(format!("--protocol `{value}` is empty or given twice"));
                }
            }
            "--ignore-list" => ignore_list = Some(PathBuf::from(value)),
            "--out" => out = Some(PathBuf::from(value)),
            other => return Err(format!("unknown argument `{other}`")),
        }
    }
    let corpus_dir = corpus_dir.ok_or("--corpus is required")?;
    let ignore = IgnoreList::parse(&read(&ignore_list.ok_or("--ignore-list is required")?)?)?;
    let out = out.ok_or("--out is required")?;
    if protocols.is_empty() {
        return Err("at least one --protocol is required".into());
    }

    let mut corpus = Corpus::default();
    for direction in [Direction::Input, Direction::Output] {
        let dir = corpus_dir.join(direction.as_str());
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map_err(|e| format!("readdir {}: {e}", dir.display()))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
            .collect();
        files.sort();
        for path in files {
            let name = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            corpus.extend(load_file(direction, &name, &read(&path)?)?);
        }
    }

    let mut bodies: Vec<(String, String)> = Vec::new();
    for c in &corpus.input {
        if protocols.contains(&c.protocol)
            && !ignore.skips(Direction::Input, &c.file, &c.suite, &c.id)
        {
            if let Some(b) = c.expected.body.as_ref().filter(|b| !b.is_empty()) {
                bodies.push((c.key.clone(), b.clone()));
            }
        }
    }
    for c in &corpus.output {
        if protocols.contains(&c.protocol)
            && !ignore.skips(Direction::Output, &c.file, &c.suite, &c.id)
            && !c.response.body.is_empty()
        {
            bodies.push((c.key.clone(), c.response.body.clone()));
        }
    }
    if bodies.is_empty() {
        return Err(format!("no body in the corpus for {protocols:?}"));
    }

    let mut text = String::new();
    for (key, body) in &bodies {
        let kind = if parse(body).is_ok() { "parses" } else { "raw" };
        text.push_str(&format!("body\t{key}\t{kind}\n"));
    }
    for (i, (ka, ba)) in bodies.iter().enumerate() {
        for (kb, bb) in &bodies[i + 1..] {
            let v = if xml_bodies_equivalent(ba, bb) { "equal" } else { "differ" };
            text.push_str(&format!("pair\t{ka}\t{kb}\t{v}\n"));
        }
    }
    std::fs::write(&out, text).map_err(|e| format!("write {}: {e}", out.display()))
}
