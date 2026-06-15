//! Per-tab WebView2 child webview management for #125 step 3.
//!
//! Embeds a real WebView2 control inside the main app window via Tauri's
//! `Window::add_child(WebviewBuilder, LogicalPosition, LogicalSize)` API
//! (Path A from the issue spec). Each card-tab gets its own labeled child
//! webview, scoped so it can't reach Tauri's IPC surface. The React
//! drawer drives positioning + size via the `resize_browser_webview`
//! Tauri command — there is no z-order API in Tauri 2.x, so chrome
//! (URL bar, tab strip) must render *around* the child rect, never
//! overlapping it.
//!
//! Why Path A: the research summary in #125's epic call settled on
//! `add_child` over either separate top-level WebviewWindows (positioning
//! hell over a non-resizable drawer) or `webview2-com` directly
//! (everything is `unsafe`; reinvents lifecycle / DPI / devtools).
//! Reference: tauri-apps/tauri PR #11616, discussions #10079 / #10264,
//! and `examples/multiwebview/main.rs` in the tauri repo.
//!
//! Gotchas (cribbed from the research and worth reading before edits):
//!   1. Child WebView2s stack in creation order; no z-index. Render
//!      chrome in surrounding HTML, never on top.
//!   2. Use LogicalPosition / LogicalSize — physical units drift on
//!      multi-monitor DPI changes.
//!   3. Keyboard shortcuts: WebView2 swallows key events when focused.
//!      Step 5's window-level listener works only when chrome has
//!      focus. Long-term, migrate to Tauri's global-shortcut plugin
//!      or `WebviewWindow::on_window_event`.
//!   4. Capabilities: the tab webview labels MUST NOT match any
//!      capability that exposes a Tauri command. Otherwise an
//!      arbitrary URL gets the keys to the kingdom.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;

use tauri::{
    webview::WebviewBuilder, AppHandle, LogicalPosition, LogicalSize, Manager, WebviewUrl,
};

/// Top-level app window label that hosts every card's child webviews.
/// Tauri's default main window is `"main"`. If the project renames it
/// later this constant is the single source of truth.
const MAIN_WINDOW_LABEL: &str = "main";

/// Rectangle the React side computes for a tab's body area. Logical pixels
/// (not physical) — multi-monitor DPI shifts are the runtime's problem.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl BrowserRect {
    fn position(&self) -> LogicalPosition<f64> {
        LogicalPosition::new(self.x, self.y)
    }
    fn size(&self) -> LogicalSize<f64> {
        // 1x1 floor so a partially-collapsed drawer doesn't try to size a
        // child webview to (0, 0), which Tauri's WebviewBuilder rejects.
        LogicalSize::new(self.width.max(1.0), self.height.max(1.0))
    }
}

/// Stable label assignment for one card's tab. Tauri's webview labels are
/// global so we encode card id + tab id together. The leading `kc-tab-`
/// prefix is the capability boundary — `capabilities/*.json` must NOT
/// grant any command access to labels matching it.
fn label_for(card_id: &str, tab_id: &str) -> String {
    format!("kc-tab-{}-{}", card_id, tab_id)
}

/// Index of attached tab webviews. Held behind a Mutex so any Tauri
/// command can attach/detach without threading a state struct through
/// every signature. The values are pure bookkeeping — Tauri itself holds
/// the live Webview handles by label.
#[derive(Default)]
pub struct BrowserWebviewIndex {
    /// `label → currently navigated URL` so a re-attach can re-navigate
    /// without round-tripping through the React layer.
    labels: Mutex<HashMap<String, String>>,
}

impl BrowserWebviewIndex {
    pub fn new() -> Self {
        Self::default()
    }
    fn remember(&self, label: &str, url: &str) {
        if let Ok(mut guard) = self.labels.lock() {
            guard.insert(label.to_string(), url.to_string());
        }
    }
    fn forget(&self, label: &str) {
        if let Ok(mut guard) = self.labels.lock() {
            guard.remove(label);
        }
    }
}

/// Attach (or update) a child webview for `card_id`/`tab_id`. If one is
/// already attached under the same label, the call navigates the existing
/// webview to `url` and resizes it — that keeps tab-strip clicks cheap
/// (no webview tear-down) while still being a single command from React.
pub fn attach_or_update(
    app: &AppHandle,
    index: &BrowserWebviewIndex,
    card_id: &str,
    tab_id: &str,
    url: &str,
    rect: BrowserRect,
) -> Result<String> {
    let label = label_for(card_id, tab_id);

    // Fast path: child already attached — just navigate + reposition.
    if let Some(existing) = app.webviews().get(&label).cloned() {
        let parsed = url
            .parse()
            .map_err(|e| anyhow!("invalid url {url}: {e}"))?;
        existing
            .navigate(parsed)
            .context("navigate existing tab webview")?;
        existing
            .set_position(rect.position())
            .context("set position")?;
        existing.set_size(rect.size()).context("set size")?;
        index.remember(&label, url);
        return Ok(label);
    }

    let parent = app
        .get_window(MAIN_WINDOW_LABEL)
        .ok_or_else(|| anyhow!("main window '{MAIN_WINDOW_LABEL}' missing — child attach aborted"))?;

    let parsed = url
        .parse()
        .map_err(|e| anyhow!("invalid url {url}: {e}"))?;
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed))
        // Devtools off in release; the host shell already exposes them via
        // its own keyboard binding so the tab inheriting them is noise.
        .devtools(cfg!(debug_assertions));

    parent
        .add_child(builder, rect.position(), rect.size())
        .context("add_child failed — is the `unstable` Tauri feature on?")?;

    index.remember(&label, url);
    Ok(label)
}

/// Resize an attached tab webview without navigating. Called from React's
/// ResizeObserver on the panel container — fires whenever the card
/// drawer width changes, the user resizes the window, or layout shifts.
pub fn resize(
    app: &AppHandle,
    card_id: &str,
    tab_id: &str,
    rect: BrowserRect,
) -> Result<()> {
    let label = label_for(card_id, tab_id);
    let Some(webview) = app.webviews().get(&label).cloned() else {
        // Resizing a tab that was never attached is a no-op, not an error.
        // This happens when the React side fires a resize before the
        // first attach round-trip lands.
        return Ok(());
    };
    webview.set_position(rect.position()).context("set_position")?;
    webview.set_size(rect.size()).context("set_size")?;
    Ok(())
}

/// Detach a tab webview by label. Idempotent — detaching an unknown label
/// is a no-op so the React side can fire it unconditionally on tab close.
pub fn detach(
    app: &AppHandle,
    index: &BrowserWebviewIndex,
    card_id: &str,
    tab_id: &str,
) -> Result<()> {
    let label = label_for(card_id, tab_id);
    if let Some(webview) = app.webviews().get(&label).cloned() {
        webview.close().context("close tab webview")?;
    }
    index.forget(&label);
    Ok(())
}

/// Detach every child webview for `card_id` — used when the card drawer
/// closes so a different card's tabs don't paint over the new view.
pub fn detach_all(app: &AppHandle, index: &BrowserWebviewIndex, card_id: &str) -> Result<()> {
    let prefix = format!("kc-tab-{}-", card_id);
    let labels: Vec<String> = app
        .webviews()
        .keys()
        .filter(|l| l.starts_with(&prefix))
        .cloned()
        .collect();
    for label in labels {
        if let Some(webview) = app.webviews().get(&label).cloned() {
            let _ = webview.close();
        }
        index.forget(&label);
    }
    Ok(())
}

/// Navigate an already-attached tab to `url` without resizing. Distinct
/// from `attach_or_update` so the React side can change URL while the
/// existing rect is still authoritative.
pub fn navigate(
    app: &AppHandle,
    index: &BrowserWebviewIndex,
    card_id: &str,
    tab_id: &str,
    url: &str,
) -> Result<()> {
    let label = label_for(card_id, tab_id);
    let Some(webview) = app.webviews().get(&label).cloned() else {
        return Err(anyhow!("tab webview {label} is not attached"));
    };
    let parsed = url
        .parse()
        .map_err(|e| anyhow!("invalid url {url}: {e}"))?;
    webview.navigate(parsed).context("navigate")?;
    index.remember(&label, url);
    Ok(())
}

/// Back / forward / reload via eval on the tab webview. Tauri 2 doesn't
/// expose explicit history APIs on Webview yet, but `window.history` works
/// fine inside the child — running the JS from the host is the same path
/// the macOS WKWebView side uses via `goBack()/goForward()/reload()`.
pub fn navigate_back(app: &AppHandle, card_id: &str, tab_id: &str) -> Result<()> {
    eval_in_tab(app, card_id, tab_id, "window.history.back();")
}

pub fn navigate_forward(app: &AppHandle, card_id: &str, tab_id: &str) -> Result<()> {
    eval_in_tab(app, card_id, tab_id, "window.history.forward();")
}

pub fn reload(app: &AppHandle, card_id: &str, tab_id: &str) -> Result<()> {
    eval_in_tab(app, card_id, tab_id, "window.location.reload();")
}

fn eval_in_tab(app: &AppHandle, card_id: &str, tab_id: &str, js: &str) -> Result<()> {
    let label = label_for(card_id, tab_id);
    let Some(webview) = app.webviews().get(&label).cloned() else {
        return Err(anyhow!("tab webview {label} is not attached"));
    };
    webview.eval(js).context("eval")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn label_is_card_then_tab() {
        assert_eq!(label_for("card_abc", "browser_xyz"), "kc-tab-card_abc-browser_xyz");
    }

    #[test]
    fn rect_floor_keeps_size_above_zero() {
        let collapsed = BrowserRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };
        let size = collapsed.size();
        assert!(size.width >= 1.0);
        assert!(size.height >= 1.0);
    }

    #[test]
    fn index_remembers_and_forgets() {
        let idx = BrowserWebviewIndex::new();
        idx.remember("kc-tab-a-1", "https://example.com");
        idx.remember("kc-tab-a-2", "https://other.com");
        assert_eq!(idx.labels.lock().unwrap().len(), 2);
        idx.forget("kc-tab-a-1");
        assert_eq!(idx.labels.lock().unwrap().len(), 1);
        assert!(idx.labels.lock().unwrap().contains_key("kc-tab-a-2"));
    }
}
