//! Disk-backed storage for images pasted into prompts.
//!
//! Layout: `<data_dir>/images/<ksuid>.<ext>`. Paths returned to the frontend
//! are absolute file paths the frontend can stuff into Link.promptImagePaths
//! / QueuedPrompt.imagePaths. On send, those paths become markdown
//! references (`![](path)`) when the marker substitution runs.
//!
//! Images live forever in this directory — they're cheap and the user can
//! prune the folder manually. Mirrors macOS behavior where attachments
//! live under `~/.kanban-code/images/`.

use anyhow::{Context, Result};
use std::path::PathBuf;
use tokio::fs;

use crate::coordination_store::kanban_data_dir;
use crate::ksuid;

fn images_dir() -> PathBuf {
    kanban_data_dir().join("images")
}

/// Best-effort extension sniffing from the leading bytes. Falls back to
/// "png" — the clipboard image path on Windows almost always hands us PNG.
fn extension_for(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        "png"
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "gif"
    } else if bytes.starts_with(b"RIFF") && bytes.len() > 11 && &bytes[8..12] == b"WEBP" {
        "webp"
    } else {
        "png"
    }
}

/// Save raw image bytes to `<data_dir>/images/<ksuid>.<ext>`, returning the
/// absolute file path. The KSUID id sorts chronologically so a listing of
/// the directory shows newest pastes last.
pub async fn save_bytes(bytes: &[u8]) -> Result<String> {
    let dir = images_dir();
    fs::create_dir_all(&dir).await.context("create images dir")?;
    let id = ksuid::generate(Some("img"));
    let ext = extension_for(bytes);
    let path = dir.join(format!("{}.{}", id, ext));
    fs::write(&path, bytes).await.context("write image bytes")?;
    Ok(path.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_detects_png() {
        assert_eq!(extension_for(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), "png");
    }

    #[test]
    fn extension_detects_jpeg() {
        assert_eq!(extension_for(&[0xFF, 0xD8, 0xFF, 0xE0]), "jpg");
    }

    #[test]
    fn extension_falls_back_to_png() {
        assert_eq!(extension_for(&[0xDE, 0xAD, 0xBE, 0xEF]), "png");
    }
}
