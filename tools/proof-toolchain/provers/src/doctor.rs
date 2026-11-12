// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
//! `doctor`: run each toolchain entry's own check and report it as PRESENT,
//! DRIFT or UNAVAILABLE with a reason. A tool that did not run is never
//! PRESENT (PROOF-POLICY §6). The capability record is total over the
//! manifest: every toolchain entry appears exactly once, in manifest order.

use crate::{Ctx, sha256_file, sha256_hex};
use serde_json::{Map, Value, json};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[cfg(test)]
pub const STATUSES: [&str; 3] = ["PRESENT", "DRIFT", "UNAVAILABLE"];

/// The record type, as an ADR-008 profile C UUIDv8 of RECORD_TYPE_NAME:
/// bytes 0..15 of SHA-256(name), version 8, variant 10.
pub const RECORD_TYPE_ID: &str = "5934cd83-73e5-80ab-abf5-f1c0bd3526fd";
pub const RECORD_TYPE_NAME: &str = "bofj-kitt.record-type:env-capability";

pub struct Opts {
    pub env: Option<String>,
    pub timeout: Duration,
    pub setup_report: PathBuf,
}

struct Ran {
    code: Option<i32>,
    first_line: String,
    output: String,
}

/// Run `cmd` under `sh -c` with stdin closed, a deadline and $PREFIX set.
fn run(cmd: &str, prefix: &str, toolchain: Option<&str>, timeout: Duration) -> Ran {
    let mut c = Command::new("sh");
    c.arg("-c").arg(cmd).env("PREFIX", prefix);
    if let Some(t) = toolchain {
        c.env("TOOLCHAIN", t);
    }
    let path = std::env::var("PATH").unwrap_or_default();
    c.env("PATH", format!("{prefix}/bin:{path}"));
    c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => return Ran { code: None, first_line: format!("could not start sh: {e}"), output: String::new() },
    };
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if start.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => break None,
        }
    };
    let mut out = String::new();
    if let Some(mut s) = child.stdout.take() {
        let _ = s.read_to_string(&mut out);
    }
    if let Some(mut s) = child.stderr.take() {
        let _ = s.read_to_string(&mut out);
    }
    let first_line = first_line(&out);
    match status {
        Some(s) => Ran { code: s.code(), first_line, output: out },
        None => Ran { code: None, first_line: format!("timed out after {}s", timeout.as_secs()), output: out },
    }
}

/// The first line that says something about the tool: JVM banners such as
/// "Picked up JAVA_TOOL_OPTIONS" carry proxy settings, not a version.
fn first_line(out: &str) -> String {
    let l = out
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("Picked up "))
        .unwrap_or("(no output)");
    scrub(l)
}

/// Keep a line short and free of the user's home path (proposal: Privacy).
fn scrub(line: &str) -> String {
    let mut l = line.to_string();
    if let Ok(home) = std::env::var("HOME") {
        if home.len() > 1 {
            l = l.replace(&home, "~");
        }
    }
    l.chars().take(160).collect()
}

fn failure_reason(what: &str, r: &Ran) -> String {
    match r.code {
        Some(127) => format!("{what}: command or file not found (exit 127): {}", r.first_line),
        Some(c) => format!("{what} exited {c}: {}", r.first_line),
        None => format!("{what} did not finish: {}", r.first_line),
    }
}

/// Resolve the executable a check starts, when it names one directly.
fn entry_point(cmd: &str, prefix: &str) -> Option<PathBuf> {
    let first = cmd.split_whitespace().next()?;
    if matches!(first, "sh" | "test" | "lake") {
        return None;
    }
    let first = first.replace("$PREFIX", prefix);
    if first.contains('/') {
        return Some(PathBuf::from(first)).filter(|p| p.is_file());
    }
    let path = std::env::var("PATH").unwrap_or_default();
    std::iter::once(format!("{prefix}/bin"))
        .chain(path.split(':').map(String::from))
        .map(|d| Path::new(&d).join(&first))
        .find(|p| p.is_file())
}

/// A version is matched as a token, so "4.8.12" does not match "4.8.120".
fn contains_version(output: &str, v: &str) -> bool {
    let v = v.trim_start_matches('v');
    output.match_indices(v).any(|(i, _)| {
        let before = output[..i].chars().next_back();
        let after = output[i + v.len()..].chars().next();
        !before.is_some_and(|c| c.is_ascii_digit() || c == '.')
            && !after.is_some_and(|c| c.is_ascii_digit())
            && !(after == Some('.') && output[i + v.len() + 1..].starts_with(|c: char| c.is_ascii_digit()))
    })
}

/// A pin that names a version, rather than a rule for resolving one.
fn concrete_pin(pin: &Value) -> Option<String> {
    let p = pin.as_str()?;
    let rule = p.starts_with("resolve") || p.starts_with("from ") || p.starts_with("consumer ");
    (!rule).then(|| p.to_string())
}

pub fn detect_env(explicit: Option<&str>) -> (String, String) {
    if let Some(e) = explicit {
        return (e.to_string(), "--env".into());
    }
    if std::env::var("CLAUDE_CODE_REMOTE").as_deref() == Ok("true") {
        return ("agent-session".into(), "CLAUDE_CODE_REMOTE=true".into());
    }
    if std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true") {
        return ("ci-runner".into(), "GITHUB_ACTIONS=true".into());
    }
    ("workstation".into(), "default: no session or CI marker set".into())
}

fn read_setup_report(path: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({"present": false, "reason": "no setup report: this environment's setup script has not run here"});
    };
    let items: Vec<Value> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let mut f = l.splitn(3, '\t');
            json!({"id": f.next().unwrap_or(""), "status": f.next().unwrap_or(""), "detail": f.next().unwrap_or("")})
        })
        .collect();
    json!({"present": true, "items": items})
}

pub fn record(ctx: &Ctx, o: &Opts) -> Result<(Value, i32), String> {
    let (env_id, detected_by) = detect_env(o.env.as_deref());
    let envs = ctx.environments["environments"].as_array().ok_or("environments.kyaml: no environments list")?;
    let env = envs
        .iter()
        .find(|e| e["id"] == env_id.as_str())
        .ok_or_else(|| format!("environment '{env_id}' is not declared in environments.kyaml"))?;
    let render = &ctx.environments["render"][env_id.as_str()];
    let prefix = ctx.toolchain["prefix"].as_str().ok_or("toolchain.kyaml: no prefix")?.to_string();

    let lock_path = ctx.root.join("tools/proof-toolchain/toolchain.lock.json");
    let lock: Option<Value> = match std::fs::read(&lock_path) {
        Ok(b) => Some(
            ijson_jcs::parse_json_bytes(&b, ijson_jcs::JsonMode::Canonical)
                .map_err(|e| format!("toolchain.lock.json is not canonical I-JSON: {e}"))?,
        ),
        Err(_) => None,
    };
    let lock_info = match &lock {
        Some(_) => json!({"present": true, "sha256": sha256_file(&lock_path)}),
        None => json!({"present": false, "sha256": null, "reason": "no toolchain.lock.json: the bundle build has not run, so no version is locked"}),
    };

    // What this environment's own setup promises, by toolchain entry.
    let mut promised: Map<String, Value> = Map::new();
    for item in render["setup"].as_array().into_iter().flatten() {
        if let Some(t) = item["provides"]["tool"].as_str() {
            promised.insert(t.to_string(), item["provides"].clone());
        }
    }

    let mut tools = Vec::new();
    let (mut n_present, mut n_drift, mut n_unavail) = (0, 0, 0);
    for t in ctx.toolchain["tools"].as_array().ok_or("toolchain.kyaml: no tools list")? {
        let id = t["id"].as_str().ok_or("toolchain entry without id")?;
        let locked = lock.as_ref().map(|l| &l["tools"][id]).filter(|v| !v.is_null());
        let (expected, expected_from) = if let Some(v) = locked.and_then(|l| l["version"].as_str()) {
            (Some(v.to_string()), "lock")
        } else if let Some(v) = promised.get(id).and_then(|p| p["version"].as_str()) {
            (Some(v.to_string()), "environment setup")
        } else if let Some(v) = concrete_pin(&t["pin"]) {
            (Some(v), "manifest pin")
        } else {
            (None, "none")
        };
        let toolchains: Vec<String> = locked
            .and_then(|l| l["toolchains"].as_array())
            .or_else(|| promised.get(id).and_then(|p| p["toolchains"].as_array()))
            .map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
            .unwrap_or_default();

        let mut rec = Map::new();
        rec.insert("id".into(), json!(id));
        rec.insert("role".into(), t["role"].clone());
        rec.insert("expected_version".into(), json!(expected));
        rec.insert("expected_from".into(), json!(expected_from));
        let verify = t["verify"].as_str().unwrap_or("");
        let version_cmd = t["version"].as_str();

        let outcome: Result<(String, Option<PathBuf>), String> = (|| {
            if verify.is_empty() {
                return Err("the manifest entry has no verify command".into());
            }
            let runs: Vec<Option<&str>> = if verify.contains("$TOOLCHAIN") {
                if toolchains.is_empty() {
                    return Err("verify runs once per toolchain, and neither a lock nor this environment's setup names any".into());
                }
                toolchains.iter().map(|s| Some(s.as_str())).collect()
            } else {
                vec![None]
            };
            let mut text = String::new();
            for tc in &runs {
                let r = run(verify, &prefix, *tc, o.timeout);
                if r.code != Some(0) {
                    let what = tc.map_or("verify".to_string(), |s| format!("verify for {s}"));
                    return Err(failure_reason(&what, &r));
                }
                text.push_str(&r.output);
            }
            if let Some(vc) = version_cmd {
                let r = run(vc, &prefix, None, o.timeout);
                if r.code != Some(0) {
                    return Err(failure_reason("version command", &r));
                }
                text = r.output;
            }
            Ok((text, entry_point(version_cmd.unwrap_or(verify), &prefix)))
        })();

        match outcome {
            Err(reason) => {
                n_unavail += 1;
                rec.insert("status".into(), json!("UNAVAILABLE"));
                rec.insert("reason".into(), json!(reason));
            }
            Ok((text, exe)) => {
                let observed = first_line(&text);
                rec.insert("observed_version".into(), json!(observed));
                rec.insert("observed_sha256".into(), json!(exe.as_deref().and_then(sha256_file)));
                if let Some(l) = locked {
                    rec.insert("locked_sha256".into(), l["sha256"].clone());
                }
                if !toolchains.is_empty() {
                    rec.insert("toolchains".into(), json!(toolchains));
                }
                match &expected {
                    Some(v) if !contains_version(&text, v) => {
                        n_drift += 1;
                        rec.insert("status".into(), json!("DRIFT"));
                        rec.insert("mismatch".into(), json!(format!("expected {v} ({expected_from}); the check printed: {observed}")));
                    }
                    Some(_) => {
                        n_present += 1;
                        rec.insert("status".into(), json!("PRESENT"));
                    }
                    None => {
                        n_present += 1;
                        rec.insert("status".into(), json!("PRESENT"));
                        rec.insert("version_check".into(), json!("unchecked: no lock, no environment pin and no concrete manifest pin name a version"));
                    }
                }
            }
        }
        tools.push(Value::Object(rec));
    }

    // Items the environment installs that are not toolchain entries.
    let mut env_tools = Vec::new();
    for item in render["setup"].as_array().into_iter().flatten() {
        let Some(cmd) = item["verify"].as_str() else { continue };
        let id = item["id"].as_str().unwrap_or("");
        let r = run(cmd, &prefix, None, o.timeout);
        let mut rec = json!({"id": id});
        if r.code != Some(0) {
            rec["status"] = json!("UNAVAILABLE");
            rec["reason"] = json!(failure_reason("verify", &r));
            n_unavail += 1;
        } else if let Some(v) = item["expect"].as_str().filter(|v| !contains_version(&r.output, v)) {
            rec["status"] = json!("DRIFT");
            rec["mismatch"] = json!(format!("expected {v}; the check printed: {}", r.first_line));
            n_drift += 1;
        } else {
            rec["status"] = json!("PRESENT");
            rec["observed_version"] = json!(r.first_line);
            n_present += 1;
        }
        env_tools.push(rec);
    }
    for item in render["unavailable"].as_array().into_iter().flatten() {
        n_unavail += 1;
        env_tools.push(json!({"id": item["id"], "status": "UNAVAILABLE", "reason": item["reason"]}));
    }

    let measured = match &env["measured"] {
        Value::Array(a) => a.last().cloned().unwrap_or(Value::Null),
        Value::Object(m) if m.is_empty() => Value::Null,
        v => v.clone(),
    };
    let rec = json!({
        "record_type": {"id": RECORD_TYPE_ID, "profile": "ESTATE-UUID-V8 profile C", "name": RECORD_TYPE_NAME},
        "schema": 1,
        "producer": format!("provers doctor {}", env!("CARGO_PKG_VERSION")),
        "observed_at": crate::utc_now(),
        "environment": {
            "id": env_id,
            "detected_by": detected_by,
            "host": {"os": std::env::consts::OS, "arch": std::env::consts::ARCH},
            "measured": measured,
            "measured_note": "the latest dated probe block recorded in environments.kyaml for this class; doctor does not probe the network",
        },
        "manifests": {
            "toolchain_sha256": sha256_hex(ctx.toolchain_src.as_bytes()),
            "environments_sha256": sha256_hex(ctx.environments_src.as_bytes()),
        },
        "lock": lock_info,
        "setup": read_setup_report(&o.setup_report),
        "summary": {"present": n_present, "drift": n_drift, "unavailable": n_unavail},
        "tools": tools,
        "environment_tools": env_tools,
    });
    let code = if n_drift > 0 { 1 } else if n_unavail > 0 { 3 } else { 0 };
    Ok((rec, code))
}

pub fn text(rec: &Value) -> String {
    let mut s = format!(
        "provers doctor: environment {} ({})\n",
        rec["environment"]["id"].as_str().unwrap_or("?"),
        rec["environment"]["detected_by"].as_str().unwrap_or("?")
    );
    for section in ["tools", "environment_tools"] {
        for t in rec[section].as_array().into_iter().flatten() {
            let detail = t["reason"]
                .as_str()
                .or(t["mismatch"].as_str())
                .or(t["observed_version"].as_str())
                .unwrap_or("");
            s.push_str(&format!(
                "{:<12} {:<22} {}\n",
                t["status"].as_str().unwrap_or("?"),
                t["id"].as_str().unwrap_or("?"),
                detail
            ));
        }
    }
    let sm = &rec["summary"];
    s.push_str(&format!("summary: {} present, {} drift, {} unavailable\n", sm["present"], sm["drift"], sm["unavailable"]));
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_match_as_tokens() {
        assert!(contains_version("Z3 version 4.8.12 - 64 bit", "4.8.12"));
        assert!(!contains_version("Z3 version 4.8.120", "4.8.12"));
        assert!(!contains_version("Z3 version 14.8.12", "4.8.12"));
        assert!(!contains_version("version 4.8.12.1", "4.8.12"));
        assert!(contains_version("agda-stdlib v2.3", "v2.3"));
        assert!(contains_version("Lean (version 4.13.0, x86_64)", "4.13.0"));
    }

    #[test]
    fn pin_rules_are_not_versions() {
        assert_eq!(concrete_pin(&json!("0.8.0")), Some("0.8.0".into()));
        for rule in ["resolve", "resolve-stable", "from creusot rust-toolchain", "consumer lean-toolchain files"] {
            assert_eq!(concrete_pin(&json!(rule)), None);
        }
        assert_eq!(concrete_pin(&json!(["a", "b"])), None);
    }

    #[test]
    fn a_missing_tool_is_unavailable_not_a_pass() {
        let r = run("definitely-not-a-tool-xyz --version", "/nonexistent", None, Duration::from_secs(5));
        assert_eq!(r.code, Some(127));
        assert!(failure_reason("verify", &r).contains("not found"));
    }

    #[test]
    fn a_hung_check_times_out() {
        let r = run("sleep 5", "/nonexistent", None, Duration::from_millis(200));
        assert_eq!(r.code, None);
    }
}

#[cfg(test)]
mod id_tests {
    use super::*;

    #[test]
    fn record_type_id_is_profile_c_of_its_name() {
        let h = crate::sha256_hex(RECORD_TYPE_NAME.as_bytes());
        let mut b: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect();
        b[6] = (b[6] & 0x0f) | 0x80;
        b[8] = (b[8] & 0x3f) | 0x80;
        let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
        let id = format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]);
        assert_eq!(id, RECORD_TYPE_ID);
    }
}
