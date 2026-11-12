// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
//! provers: doctor and render for the bofj-kitt proof toolchain and its
//! environment classes. Invoked through tools/proof-toolchain/provers.sh.
//!
//!   provers [--root DIR] doctor [--json] [--env ID] [--timeout SECS]
//!   provers [--root DIR] render [--check] [--out DIR]
//!
//! doctor exits 0 when every entry is PRESENT, 1 on any DRIFT, 3 when
//! something is UNAVAILABLE and nothing drifted, 2 on a usage or manifest
//! error. render exits 1 under --check when a committed file differs.

mod doctor;
mod kyaml;
mod render;

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

pub struct Ctx {
    pub root: PathBuf,
    pub toolchain: Value,
    pub toolchain_src: String,
    pub environments: Value,
    pub environments_src: String,
}

pub fn sha256_hex(b: &[u8]) -> String {
    Sha256::digest(b)
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect()
}

pub fn sha256_file(p: &Path) -> Option<String> {
    std::fs::read(p).ok().map(|b| sha256_hex(&b))
}

/// RFC 3339 UTC timestamp to the second, from the system clock.
pub fn utc_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn load(root: &Path) -> Result<Ctx, String> {
    let read = |rel: &str| -> Result<(String, Value), String> {
        let p = root.join(rel);
        let src = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        let v = kyaml::parse(&src).map_err(|e| format!("{rel}: {e}"))?;
        Ok((src, v))
    };
    let (toolchain_src, toolchain) = read("tools/proof-toolchain/toolchain.kyaml")?;
    let (environments_src, environments) = read("tools/environments/environments.kyaml")?;
    Ok(Ctx {
        root: root.to_path_buf(),
        toolchain,
        toolchain_src,
        environments,
        environments_src,
    })
}

/// JCS bytes of the record plus the one final newline estate files carry.
fn jcs_line(v: &Value) -> Result<String, String> {
    ijson_jcs::validate_i_json(v).map_err(|e| format!("record is not I-JSON: {e}"))?;
    let s = ijson_jcs::to_jcs_string(v).map_err(|e| format!("JCS: {e}"))?;
    Ok(format!("{s}\n"))
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: provers [--root DIR] doctor [--json] [--env ID] [--timeout SECS] [--setup-report FILE]\n       provers [--root DIR] render [--check] [--out DIR]"
    );
    ExitCode::from(2)
}

fn fail(context: &str, e: impl std::fmt::Display) -> ExitCode {
    eprintln!("{context}: {e}");
    ExitCode::from(2)
}

/// Parse doctor's options; None means a usage error.
fn doctor_opts(rest: &[String]) -> Option<(doctor::Opts, bool)> {
    let mut json = false;
    let mut o = doctor::Opts {
        env: None,
        timeout: Duration::from_secs(20),
        setup_report: PathBuf::from(
            std::env::var("PROVERS_SETUP_REPORT")
                .unwrap_or_else(|_| "/var/lib/bofj-kitt/setup-report.tsv".into()),
        ),
    };
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--json" => json = true,
            "--env" => o.env = Some(it.next()?.clone()),
            "--timeout" => o.timeout = Duration::from_secs(it.next()?.parse().ok()?),
            "--setup-report" => o.setup_report = PathBuf::from(it.next()?),
            _ => return None,
        }
    }
    Some((o, json))
}

fn cmd_doctor(ctx: &Ctx, rest: &[String]) -> ExitCode {
    let Some((o, json)) = doctor_opts(rest) else {
        return usage();
    };
    let (rec, code) = match doctor::record(ctx, &o) {
        Ok(r) => r,
        Err(e) => return fail("provers doctor", e),
    };
    if json {
        match jcs_line(&rec) {
            Ok(s) => print!("{s}"),
            Err(e) => return fail("provers", e),
        }
    } else {
        print!("{}", doctor::text(&rec));
    }
    ExitCode::from(code as u8)
}

fn write_rendered(p: &Path, body: &str) -> Result<(), String> {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
    }
    std::fs::write(p, body).map_err(|e| format!("{}: {e}", p.display()))
}

fn cmd_render(ctx: &Ctx, rest: &[String]) -> ExitCode {
    let mut check = false;
    let mut out = ctx.root.join("tools/environments/rendered");
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match (a.as_str(), it.clone().next()) {
            ("--check", _) => check = true,
            ("--out", Some(v)) => {
                out = PathBuf::from(v);
                it.next();
            }
            _ => return usage(),
        }
    }
    let files = match render::render_all(ctx) {
        Ok(f) => f,
        Err(e) => return fail("provers render", e),
    };
    if !check {
        for (rel, body) in &files {
            let p = out.join(rel);
            if let Err(e) = write_rendered(&p, body) {
                return fail("provers render", e);
            }
            println!("rendered {}", p.display());
        }
        return ExitCode::SUCCESS;
    }
    let drifted: Vec<PathBuf> = files
        .iter()
        .map(|(rel, body)| (out.join(rel), body))
        .filter(|(p, body)| std::fs::read_to_string(p).ok().as_deref() != Some(body.as_str()))
        .map(|(p, _)| p)
        .collect();
    for p in &drifted {
        eprintln!(
            "DRIFT {}: differs from what the manifests render; run provers.sh render",
            p.display()
        );
    }
    if !drifted.is_empty() {
        return ExitCode::from(1);
    }
    println!("render --check: {} files match the manifests", files.len());
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut root = PathBuf::from(".");
    if args.first().map(String::as_str) == Some("--root") {
        if args.len() < 2 {
            return usage();
        }
        root = PathBuf::from(args.remove(1));
        args.remove(0);
    }
    let Some(cmd) = args.first().cloned() else {
        return usage();
    };
    let ctx = match load(&root) {
        Ok(c) => c,
        Err(e) => return fail("provers", e),
    };
    match cmd.as_str() {
        "doctor" => cmd_doctor(&ctx, &args[1..]),
        "render" => cmd_render(&ctx, &args[1..]),
        _ => usage(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Ctx {
        load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")).unwrap()
    }

    #[test]
    fn timestamps_are_rfc3339() {
        let t = utc_now();
        assert_eq!(t.len(), 20);
        assert!(t.ends_with('Z') && t.as_bytes()[10] == b'T');
    }

    #[test]
    fn record_is_total_over_the_manifest_and_canonical() {
        let c = ctx();
        let o = doctor::Opts {
            env: Some("agent-session".into()),
            timeout: Duration::from_secs(5),
            setup_report: PathBuf::from("/nonexistent/setup-report.tsv"),
        };
        let (rec, _) = doctor::record(&c, &o).unwrap();
        let ids: Vec<&str> = c.toolchain["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect();
        let got: Vec<&str> = rec["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, got, "every manifest entry exactly once, in order");
        for t in rec["tools"]
            .as_array()
            .unwrap()
            .iter()
            .chain(rec["environment_tools"].as_array().unwrap())
        {
            let st = t["status"].as_str().unwrap();
            assert!(doctor::STATUSES.contains(&st));
            if st == "UNAVAILABLE" {
                assert!(
                    t["reason"].as_str().is_some_and(|r| !r.is_empty()),
                    "UNAVAILABLE without a reason"
                );
            }
        }
        let line = jcs_line(&rec).unwrap();
        let back =
            ijson_jcs::parse_json(line.trim_end_matches('\n'), ijson_jcs::JsonMode::Canonical)
                .unwrap();
        assert_eq!(jcs_line(&back).unwrap(), line, "JCS round trip");
        assert_eq!(rec["setup"]["present"], false);
    }

    #[test]
    fn committed_render_matches_the_manifests() {
        let c = ctx();
        let files = render::render_all(&c).unwrap();
        for (rel, body) in files {
            let p = c.root.join("tools/environments/rendered").join(&rel);
            let committed = std::fs::read_to_string(&p).unwrap_or_default();
            assert_eq!(
                committed, body,
                "{rel} drifted; run tools/proof-toolchain/provers.sh render"
            );
        }
    }
}
