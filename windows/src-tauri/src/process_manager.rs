//! Snapshots of running processes the app cares about, for the
//! Process Manager modal. Mirrors `Sources/KanbanCode/ProcessManagerView.swift`
//! at the data layer — three lists (tmux sessions, Claude processes,
//! worktrees) the UI surfaces side by side.
//!
//! Reads are best-effort. A missing tmux/WSL or a `tasklist`/`ps` that
//! can't run returns an empty list, not an error. The caller treats
//! "no rows" the same as "feature unavailable" — same as macOS does
//! when `tmux` isn't on the PATH.

use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::{git_worktree, logging, tmux};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TmuxSessionInfo {
    pub name: String,
    /// Unix timestamp (seconds) the session was created.
    pub created_at: i64,
    pub attached: bool,
    pub windows: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeProcessInfo {
    pub pid: u32,
    pub command: String,
    /// Best-effort extraction of `--session-id <id>` or `--resume <id>` from
    /// the command line. Null when we can't tell.
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeRow {
    pub repo_root: String,
    pub project_name: String,
    pub path: String,
    pub branch: Option<String>,
    pub is_main: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProcessState {
    pub tmux_sessions: Vec<TmuxSessionInfo>,
    pub claude_processes: Vec<ClaudeProcessInfo>,
    pub worktrees: Vec<WorktreeRow>,
}

/// Mirrors `tmux list-sessions -F '#{session_name}\t#{session_created}\t#{session_attached}\t#{session_windows}'`.
/// Returns an empty vec when tmux isn't available (also when there are no
/// sessions — both look the same from the UI's perspective).
pub fn list_tmux_sessions() -> Vec<TmuxSessionInfo> {
    if !tmux::is_available() {
        return vec![];
    }
    // Build the command through tmux's helper indirectly: we shell out to
    // `wsl tmux list-sessions …` on Windows and `tmux list-sessions …`
    // elsewhere. Reuse the path tmux.rs uses for the rest of its commands.
    #[cfg(target_os = "windows")]
    let mut c = {
        let mut x = Command::new("wsl.exe");
        x.arg("--");
        x.arg("tmux");
        x
    };
    #[cfg(not(target_os = "windows"))]
    let mut c = Command::new("tmux");

    c.args([
        "list-sessions",
        "-F",
        "#{session_name}\t#{session_created}\t#{session_attached}\t#{session_windows}",
    ]);
    let out = match c.output() {
        Ok(o) => o,
        Err(_) => return vec![],
    };
    if !out.status.success() {
        return vec![];
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    stdout
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(4, '\t');
            let name = parts.next()?.to_string();
            let created_at = parts.next()?.parse::<i64>().ok()?;
            let attached_raw = parts.next()?;
            let windows = parts.next()?.parse::<i64>().unwrap_or(0);
            Some(TmuxSessionInfo {
                name,
                created_at,
                attached: attached_raw != "0",
                windows,
            })
        })
        .collect()
}

/// Find every running Claude process. On Windows uses WMIC to grab the full
/// command line (the only reliable way to surface `--session-id` / `--resume`
/// args alongside the PID); falls back to bare `tasklist` if WMIC is gone.
pub fn list_claude_processes() -> Vec<ClaudeProcessInfo> {
    #[cfg(target_os = "windows")]
    {
        windows_list_claude()
    }
    #[cfg(not(target_os = "windows"))]
    {
        unix_list_claude()
    }
}

#[cfg(target_os = "windows")]
fn windows_list_claude() -> Vec<ClaudeProcessInfo> {
    // PowerShell's CIM gives us PID + CommandLine in one shot and survives
    // long arg strings WMIC truncates at 80 cols. The filter is loose on
    // purpose — Claude installs land as `claude.exe`, `claude.cmd`, or
    // `node.exe …\claude\cli.js`, and we want to surface them all.
    let script = r#"
        Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -match 'claude' -or $_.Name -match '^claude' } |
        ForEach-Object { "$($_.ProcessId)`t$($_.CommandLine)" }
    "#;
    let out = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output();
    let bytes = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return vec![],
    };
    let text = String::from_utf8_lossy(&bytes);
    text.lines()
        .filter_map(|line| {
            let mut parts = line.splitn(2, '\t');
            let pid = parts.next()?.trim().parse::<u32>().ok()?;
            let command = parts.next().unwrap_or("").trim().to_string();
            if command.is_empty() {
                return None;
            }
            let session_id = extract_session_id(&command);
            Some(ClaudeProcessInfo {
                pid,
                command,
                session_id,
            })
        })
        .collect()
}

#[cfg(not(target_os = "windows"))]
fn unix_list_claude() -> Vec<ClaudeProcessInfo> {
    let out = Command::new("ps")
        .args(["-eo", "pid,command"])
        .output();
    let bytes = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return vec![],
    };
    let text = String::from_utf8_lossy(&bytes);
    text.lines()
        .filter(|l| l.contains("claude"))
        .filter_map(|line| {
            let trimmed = line.trim_start();
            let mut parts = trimmed.splitn(2, char::is_whitespace);
            let pid = parts.next()?.parse::<u32>().ok()?;
            let command = parts.next().unwrap_or("").trim().to_string();
            let session_id = extract_session_id(&command);
            Some(ClaudeProcessInfo {
                pid,
                command,
                session_id,
            })
        })
        .collect()
}

/// Pull a Claude session id out of `--session-id <id>` or `--resume <id>`.
/// Matches the macOS heuristic so card→process linking lines up.
fn extract_session_id(command: &str) -> Option<String> {
    for flag in ["--session-id", "--resume"] {
        if let Some(idx) = command.find(flag) {
            let after = &command[idx + flag.len()..];
            let trimmed = after.trim_start();
            // Accept either `--flag id` or `--flag=id`.
            let candidate: &str = if let Some(eq) = trimmed.strip_prefix('=') {
                eq
            } else {
                trimmed
            };
            let token: String = candidate
                .chars()
                .take_while(|c| !c.is_whitespace())
                .collect();
            if !token.is_empty() {
                return Some(token);
            }
        }
    }
    None
}

/// Kill a Claude process by PID. `/F` so it doesn't sit on the wait list.
pub async fn kill_claude_process(pid: u32) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "windows")]
        {
            let out = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/F"])
                .output()
                .map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
            }
            logging::info("process_manager", &format!("killed claude pid={}", pid));
            Ok(())
        }
        #[cfg(not(target_os = "windows"))]
        {
            let out = Command::new("kill")
                .args(["-9", &pid.to_string()])
                .output()
                .map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
            }
            logging::info("process_manager", &format!("killed claude pid={}", pid));
            Ok(())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Iterate the user's configured project paths and gather all worktrees
/// known to git for each. `project_name` is the trailing path segment so
/// the UI can group rows without re-walking the disk.
pub async fn list_all_worktrees(repo_roots: Vec<String>) -> Vec<WorktreeRow> {
    let mut rows = vec![];
    for root in repo_roots {
        match git_worktree::list_worktrees(&root).await {
            Ok(wts) => {
                let project_name = std::path::Path::new(&root)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| root.clone());
                for w in wts {
                    rows.push(WorktreeRow {
                        repo_root: root.clone(),
                        project_name: project_name.clone(),
                        path: w.path,
                        branch: w.branch,
                        is_main: w.is_main,
                    });
                }
            }
            Err(e) => {
                logging::warn(
                    "process_manager",
                    &format!("list_worktrees({}) failed: {}", root, e),
                );
            }
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_session_id_from_resume_flag() {
        assert_eq!(
            extract_session_id("node cli.js --resume abc-123 --foo"),
            Some("abc-123".to_string())
        );
    }

    #[test]
    fn extracts_session_id_from_session_id_flag_with_equals() {
        assert_eq!(
            extract_session_id("claude.exe --session-id=xyz789"),
            Some("xyz789".to_string())
        );
    }

    #[test]
    fn returns_none_for_no_session_flag() {
        assert_eq!(extract_session_id("claude.exe --help"), None);
    }
}
