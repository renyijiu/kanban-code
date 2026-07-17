import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { applyCodexRuntimeProjection, readCodexRuntimeStates, toCardSummary } from "./data.js";
import type { Link } from "./types.js";

test("CLI projects the Swift-owned Codex lifecycle without writing it", () => {
  const home = mkdtempSync(join(tmpdir(), "kanban-codex-projection-"));
  const previous = process.env.KANBAN_CODE_HOME;
  process.env.KANBAN_CODE_HOME = home;
  try {
    writeFileSync(join(home, "codex-runtime-state.json"), JSON.stringify({
      version: 1,
      states: {
        card_1: {
          cardId: "card_1",
          lifecycle: {
            phase: "waiting",
            waitReason: "approval",
            telemetryQuality: "precise",
          },
          updatedAt: "2026-07-18T00:00:00Z",
        },
      },
    }));
    const link: Link = {
      id: "card_1",
      name: "Review permissions",
      column: "backlog",
      createdAt: "2026-07-18T00:00:00Z",
      updatedAt: "2026-07-18T00:00:00Z",
      manualOverrides: {
        worktreePath: false, tmuxSession: false, name: false,
        column: false, prLink: false, issueLink: false,
      },
      manuallyArchived: false,
      source: "manual",
      isRemote: false,
      assistant: "codex",
    };
    const states = readCodexRuntimeStates();
    const projected = applyCodexRuntimeProjection([link], states);
    assert.equal(projected[0].column, "requires_attention");
    const summary = toCardSummary(projected[0], new Set(), states);
    assert.equal(summary.lifecycle?.waitReason, "approval");
    assert.equal(summary.needsAttention, true);
  } finally {
    if (previous === undefined) delete process.env.KANBAN_CODE_HOME;
    else process.env.KANBAN_CODE_HOME = previous;
    rmSync(home, { recursive: true, force: true });
  }
});
