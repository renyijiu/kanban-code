//! Wires the `kanban statusline` subcommand into Claude Code's per-user
//! settings. The producer side of the self-compact pipeline — once Claude
//! Code is told to run our binary as its statusline, every turn snapshots
//! context usage to `<data_dir>/context/<sessionId>.json`, which the
//! polling loop (this module's sibling) and drop guard already consume.
//!
//! Claude Code reads `statusLine` from `~/.claude/settings.json`. macOS
//! does the same. Wire format:
//!
//! ```json
//! { "statusLine": { "type": "command", "command": "<path>", "padding": 0 } }
//! ```
//!
//! We round-trip the rest of the settings file untouched so other fields
//! the user has set (model, tool perms, …) are preserved.

use anyhow::{Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use tokio::fs;

const STATUSLINE_KEY: &str = "statusLine";

/// Path to `~/.claude/settings.json`. The home dir is resolved fresh each
/// call so a user who reconfigures profiles mid-session still hits the
/// right file.
fn claude_settings_path() -> Result<PathBuf> {
    let home = dirs::home_dir().context("no home dir")?;
    Ok(home.join(".claude").join("settings.json"))
}

/// Absolute path to the `kanban` binary we'll wire in. We resolve it from
/// the running app's directory so dev (`cargo run`) and a packaged install
/// both produce a runnable command.
fn statusline_command() -> Result<String> {
    let exe = std::env::current_exe().context("current_exe")?;
    let dir = exe.parent().context("exe has no parent dir")?;
    // Sibling binary in the same install dir. On Windows it's `kanban.exe`.
    let candidate = dir.join(if cfg!(target_os = "windows") { "kanban.exe" } else { "kanban" });
    if !candidate.exists() {
        // Fallback: trust PATH. Better a usable plain-name command than a
        // broken absolute path that just happens to point at the dev dir.
        return Ok("kanban statusline".to_string());
    }
    let quoted = quote_path_for_shell(&candidate);
    Ok(format!("{quoted} statusline"))
}

/// Wraps `path` in double quotes when it contains a space — Claude Code
/// passes the string straight to its shell, so unquoted spaces split args.
fn quote_path_for_shell(path: &Path) -> String {
    let s = path.to_string_lossy().to_string();
    if s.contains(' ') {
        format!("\"{}\"", s)
    } else {
        s
    }
}

/// Reads the existing settings, leaves everything alone, and overwrites the
/// `statusLine` key with our binding. Creates the file (and parent dir) if
/// missing. Idempotent — re-install with no change to disk after the first.
pub async fn install() -> Result<()> {
    install_at(&claude_settings_path()?, &statusline_command()?).await
}

/// Removes only the `statusLine` key. Other settings are preserved. No-op
/// when the file or key doesn't exist.
pub async fn uninstall() -> Result<()> {
    uninstall_at(&claude_settings_path()?).await
}

/// True iff `statusLine.command` currently points at our `kanban statusline`
/// invocation. A false reading just means the user is on the bare CLI — not
/// an error.
pub async fn is_installed() -> bool {
    let Ok(path) = claude_settings_path() else { return false };
    let Ok(bytes) = fs::read(&path).await else { return false };
    let Ok(v) = serde_json::from_slice::<Value>(&bytes) else { return false };
    matches_our_command(&v)
}

fn matches_our_command(v: &Value) -> bool {
    let Some(cmd) = v.get(STATUSLINE_KEY).and_then(|s| s.get("command")).and_then(|c| c.as_str()) else {
        return false;
    };
    cmd.contains("kanban") && cmd.contains("statusline")
}

async fn install_at(path: &Path, command: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await.context("create ~/.claude dir")?;
    }
    let mut root = read_json(path).await?.unwrap_or_else(|| Value::Object(Default::default()));
    let Some(obj) = root.as_object_mut() else {
        // settings.json existed but wasn't an object — bail rather than
        // clobber it, so a hand-edited oddball doesn't get nuked silently.
        anyhow::bail!("~/.claude/settings.json is not a JSON object");
    };
    obj.insert(
        STATUSLINE_KEY.into(),
        serde_json::json!({
            "type": "command",
            "command": command,
            "padding": 0,
        }),
    );
    write_atomic(path, &root).await
}

async fn uninstall_at(path: &Path) -> Result<()> {
    let Some(mut root) = read_json(path).await? else { return Ok(()) };
    let Some(obj) = root.as_object_mut() else { return Ok(()) };
    if obj.remove(STATUSLINE_KEY).is_none() {
        return Ok(());
    }
    write_atomic(path, &root).await
}

async fn read_json(path: &Path) -> Result<Option<Value>> {
    match fs::read(path).await {
        Ok(bytes) => {
            if bytes.iter().all(u8::is_ascii_whitespace) {
                return Ok(None);
            }
            Ok(Some(serde_json::from_slice(&bytes).context("parse settings.json")?))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).context("read settings.json"),
    }
}

async fn write_atomic(path: &Path, v: &Value) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(v).context("serialize settings")?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, &bytes).await.context("write tmp")?;
    fs::rename(&tmp, path).await.context("rename tmp")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> PathBuf {
        std::env::temp_dir().join(format!("kanban-statusline-{}", uuid::Uuid::new_v4().simple()))
    }

    #[tokio::test]
    async fn install_creates_file_and_writes_command() {
        let dir = tmp();
        let path = dir.join("settings.json");
        install_at(&path, "kanban statusline").await.unwrap();
        let read: Value = serde_json::from_slice(&fs::read(&path).await.unwrap()).unwrap();
        assert_eq!(read["statusLine"]["command"], "kanban statusline");
        assert_eq!(read["statusLine"]["type"], "command");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn install_preserves_unrelated_keys() {
        let dir = tmp();
        let path = dir.join("settings.json");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            &path,
            br#"{"model":"opus-4-7","permissions":{"allow":["Read"]}}"#,
        )
        .unwrap();
        install_at(&path, "kanban statusline").await.unwrap();
        let read: Value = serde_json::from_slice(&fs::read(&path).await.unwrap()).unwrap();
        assert_eq!(read["model"], "opus-4-7");
        assert_eq!(read["permissions"]["allow"][0], "Read");
        assert_eq!(read["statusLine"]["command"], "kanban statusline");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn uninstall_removes_only_the_status_line_key() {
        let dir = tmp();
        let path = dir.join("settings.json");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            &path,
            br#"{"model":"opus","statusLine":{"type":"command","command":"x"}}"#,
        )
        .unwrap();
        uninstall_at(&path).await.unwrap();
        let read: Value = serde_json::from_slice(&fs::read(&path).await.unwrap()).unwrap();
        assert_eq!(read["model"], "opus");
        assert!(read.get("statusLine").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn uninstall_missing_file_is_a_no_op() {
        let dir = tmp();
        let path = dir.join("settings.json");
        // No file exists yet.
        uninstall_at(&path).await.unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn matches_only_when_command_mentions_kanban_and_statusline() {
        let yes: Value = serde_json::from_str(
            r#"{"statusLine":{"type":"command","command":"\"C:/x/kanban.exe\" statusline"}}"#,
        )
        .unwrap();
        assert!(matches_our_command(&yes));
        let no: Value = serde_json::from_str(
            r#"{"statusLine":{"type":"command","command":"some-other-tool"}}"#,
        )
        .unwrap();
        assert!(!matches_our_command(&no));
        let missing: Value = serde_json::from_str("{}").unwrap();
        assert!(!matches_our_command(&missing));
    }
}
