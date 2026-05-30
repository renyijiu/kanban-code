/// Detect Claude Code's interactive numbered picker in a tmux pane snapshot
/// so the bridge can mirror the choices as Slack interactive buttons.
///
/// The picker has a stable shape:
///   <question>
///   ❯ 1. <title>
///        <description>
///     2. <title>
///        <description>
///     ...
///     N-1. Type something.
///     N.   Chat about this
///   Enter to select · Tab/Arrow keys to navigate · Esc to cancel
///
/// We anchor on that footer (it never appears in regular tool output) and
/// then walk up. The "Type something." and "Chat about this" entries are
/// keyboard-only escape hatches — they always trail the real options, so we
/// drop them from the Slack buttons. Same for the highlighted-line caret (❯).

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
const BOX_DECOR_RE = /^[\s─-╿]+$/;
const PICKER_FOOTER = "Enter to select";
/// Two trailing escape-hatch options that we never expose as Slack buttons.
const ESCAPE_HATCH_TITLES = ["Type something.", "Chat about this"];

export interface PickerOption {
  number: number;
  title: string;
  description?: string;
}

export interface Picker {
  question: string;
  options: PickerOption[];
  /// Stable fingerprint of (question + option titles) so callers can dedupe
  /// across poll ticks and avoid reposting the same picker every tick.
  hash: string;
}

/// Strip the ANSI CSI escape sequences tmux emits when we capture with -e.
export function stripAnsi(s: string): string {
  return s.replace(ANSI_RE, "");
}

/// Locate the picker block in the pane snapshot, returning null when none is
/// active. Walks bottom-up so the most recent picker wins when an older one
/// is still in scrollback (tmux capture-pane can include both).
export function parsePicker(paneText: string): Picker | null {
  const lines = paneText.split("\n").map((l) => stripAnsi(l).trimEnd());

  // 1. Footer position — bottom-most occurrence is the active picker.
  let footerIdx = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].includes(PICKER_FOOTER)) {
      footerIdx = i;
      break;
    }
  }
  if (footerIdx < 0) return null;

  // 2. Walk up from the footer collecting numbered option lines. A picker is
  // a run of `N. <title>` lines (sometimes separated by a horizontal rule and
  // with indented description lines below each). The first non-numbered,
  // non-blank, non-decor, non-indented line we hit going up IS the question.
  //
  // Description lines live BELOW their parent option, so when walking
  // bottom-up we collect them into a buffer and assign them to the next
  // numbered option we hit.
  type Raw = { number: number; title: string; descLines: string[] };
  const raw: Raw[] = [];
  let pendingDesc: string[] = [];
  let question = "";
  for (let i = footerIdx - 1; i >= 0; i--) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (BOX_DECOR_RE.test(line)) {
      // Horizontal rule inside the picker or above the question. Skip and
      // keep walking — the question (or the run-out top of the snapshot)
      // tells us where to stop.
      continue;
    }
    const m = parseNumberedLine(trimmed);
    if (m) {
      raw.unshift({ number: m.number, title: m.title, descLines: pendingDesc });
      pendingDesc = [];
      continue;
    }
    const isIndented = line.startsWith("     ") || line.startsWith("\t");
    if (isIndented) {
      pendingDesc.unshift(trimmed);
      continue;
    }
    // Non-blank, non-decor, non-indented, non-numbered: this is the question.
    question = trimmed;
    break;
  }
  if (raw.length === 0) return null;
  return assemble(question, raw);
}

function parseNumberedLine(s: string): { number: number; title: string } | null {
  // Optional caret prefix (❯ or ›), then `N. title`. Picker numbers are
  // always single-digit so an arbitrary "1234." in a tool output line does
  // not trip the detector.
  let body = s;
  if (body.startsWith("❯") || body.startsWith("›")) body = body.slice(1).trim();
  const m = /^(\d{1,2})\.\s+(.+)$/.exec(body);
  if (!m) return null;
  const number = parseInt(m[1], 10);
  if (number < 1 || number > 20) return null;
  return { number, title: m[2].trim() };
}

function assemble(question: string, raw: { number: number; title: string; descLines: string[] }[]): Picker | null {
  const sorted = [...raw].sort((a, b) => a.number - b.number);
  const filtered = sorted.filter((o) => !ESCAPE_HATCH_TITLES.some((t) => o.title.startsWith(t)));
  if (filtered.length === 0) return null;
  const options: PickerOption[] = filtered.map((o) => ({
    number: o.number,
    title: o.title,
    description: o.descLines.length ? o.descLines.join(" ") : undefined,
  }));
  const hashSource = [question, ...options.map((o) => `${o.number}.${o.title}`)].join("\n");
  return { question, options, hash: fnv1a(hashSource) };
}

/// 32-bit FNV-1a — fine for dedupe across a handful of poll ticks; we are
/// not relying on it for security.
function fnv1a(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}
