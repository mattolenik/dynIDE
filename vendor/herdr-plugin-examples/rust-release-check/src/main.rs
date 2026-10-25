use std::env;
use std::process::{self, Command};

fn main() {
    let context = env::var("HERDR_PLUGIN_CONTEXT_JSON").unwrap_or_default();
    let Some(repo) = json_string_field(&context, "focused_pane_cwd")
        .or_else(|| json_string_field(&context, "workspace_cwd"))
    else {
        eprintln!("No focused pane or workspace cwd found in HERDR_PLUGIN_CONTEXT_JSON.");
        process::exit(2);
    };

    let output = match Command::new("git")
        .args(["-C", &repo, "status", "--short"])
        .output()
    {
        Ok(output) => output,
        Err(err) => {
            eprintln!("Failed to run git: {err}");
            process::exit(2);
        }
    };

    if !output.status.success() {
        eprintln!("git status failed for {repo}");
        eprint!("{}", String::from_utf8_lossy(&output.stderr));
        process::exit(2);
    }

    let status = String::from_utf8_lossy(&output.stdout);
    if status.trim().is_empty() {
        println!("Release check passed: {repo} is clean.");
        return;
    }

    println!("Release check failed: {repo} has uncommitted changes.");
    print!("{status}");
    process::exit(1);
}

fn json_string_field(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let after_key = json.split_once(&needle)?.1;
    let after_colon = after_key.split_once(':')?.1.trim_start();
    let value = after_colon.strip_prefix('"')?;
    let mut out = String::new();
    let mut escaped = false;
    for ch in value.chars() {
        if escaped {
            out.push(match ch {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                other => other,
            });
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == '"' {
            return Some(out);
        } else {
            out.push(ch);
        }
    }
    None
}
