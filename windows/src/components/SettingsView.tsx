import { useEffect, useState, type ReactNode } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { getSettings, saveSettings, useBoardStore } from "../store/boardStore";
import type { Settings } from "../types";

export default function SettingsView() {
  const { setSettingsOpen } = useBoardStore();
  const [settings, setSettings] = useState<Settings | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [activeSection, setActiveSection] = useState<"projects" | "general" | "github" | "notifications">("general");

  useEffect(() => {
    getSettings().then(setSettings).catch(console.error);
  }, []);

  const handleSave = async () => {
    if (!settings) return;
    setSaving(true);
    try {
      await saveSettings(settings);
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      console.error(e);
    } finally {
      setSaving(false);
    }
  };

  if (!settings) {
    return (
      <div className="flex-1 flex items-center justify-center">
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 border-[1.5px] border-[#4f8ef7] border-t-transparent rounded-full animate-spin" />
          <span className="text-sm text-zinc-500">Loading settings...</span>
        </div>
      </div>
    );
  }

  const sections = ["general", "projects", "github", "notifications"] as const;
  const sectionIcons: Record<string, string> = {
    general: "M10.343 3.94c.09-.542.56-.94 1.11-.94h1.093c.55 0 1.02.398 1.11.94l.149.894c.07.424.384.764.78.93.398.164.855.142 1.205-.108l.737-.527a1.125 1.125 0 0 1 1.45.12l.773.774c.39.389.44 1.002.12 1.45l-.527.737c-.25.35-.272.806-.107 1.204.165.397.505.71.93.78l.893.15c.543.09.94.56.94 1.109v1.094c0 .55-.397 1.02-.94 1.11l-.893.149c-.425.07-.765.383-.93.78-.165.398-.143.854.107 1.204l.527.738c.32.447.269 1.06-.12 1.45l-.774.773a1.125 1.125 0 0 1-1.449.12l-.738-.527c-.35-.25-.806-.272-1.203-.107-.397.165-.71.505-.781.929l-.149.894c-.09.542-.56.94-1.11.94h-1.094c-.55 0-1.019-.398-1.11-.94l-.148-.894c-.071-.424-.384-.764-.781-.93-.398-.164-.854-.142-1.204.108l-.738.527c-.447.32-1.06.269-1.45-.12l-.773-.774a1.125 1.125 0 0 1-.12-1.45l.527-.737c.25-.35.273-.806.108-1.204-.165-.397-.505-.71-.93-.78l-.894-.15c-.542-.09-.94-.56-.94-1.109v-1.094c0-.55.398-1.02.94-1.11l.894-.149c.424-.07.765-.383.93-.78.165-.398.143-.854-.107-1.204l-.527-.738a1.125 1.125 0 0 1 .12-1.45l.773-.773a1.125 1.125 0 0 1 1.45-.12l.737.527c.35.25.807.272 1.204.107.397-.165.71-.505.78-.929l.15-.894Z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
    projects: "M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z",
    github: "M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4M14 4h6m0 0v6m0-6L10 14",
    notifications: "M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0",
  };

  return (
    <div className="flex-1 flex flex-col overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-6 py-4 border-b border-white/[0.06] shrink-0">
        <div className="flex items-center gap-3">
          <button
            onClick={() => setSettingsOpen(false)}
            className="text-zinc-500 hover:text-zinc-200 transition-colors"
            title="Back to board"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M10.5 19.5 3 12m0 0 7.5-7.5M3 12h18" />
            </svg>
          </button>
          <h1 className="text-base font-semibold text-zinc-200">Settings</h1>
        </div>
        <div className="flex items-center gap-2">
          {saved && (
            <span className="text-xs text-[#3fb950] animate-fade-in">Saved</span>
          )}
          <button
            onClick={handleSave}
            disabled={saving}
            className="px-4 py-1.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] disabled:opacity-50 text-white text-xs font-medium transition-all shadow-lg shadow-[#4f8ef7]/15"
          >
            {saving ? "Saving..." : "Save"}
          </button>
          <button
            onClick={() => setSettingsOpen(false)}
            className="text-zinc-500 hover:text-zinc-300 ml-1 transition-colors"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar */}
        <nav className="w-48 border-r border-white/[0.06] py-3 shrink-0">
          {sections.map((section) => (
            <button
              key={section}
              onClick={() => setActiveSection(section)}
              className={`w-full text-left px-4 py-2.5 text-sm capitalize transition-all flex items-center gap-2.5 ${
                activeSection === section
                  ? "text-zinc-200 bg-white/[0.04] border-r-2 border-[#4f8ef7]"
                  : "text-zinc-500 hover:text-zinc-300 hover:bg-white/[0.02]"
              }`}
            >
              <svg className="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d={sectionIcons[section]} />
              </svg>
              {section}
            </button>
          ))}
        </nav>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6">
          {activeSection === "general" && (
            <GeneralSection settings={settings} onChange={setSettings} />
          )}
          {activeSection === "projects" && (
            <ProjectsSection
              settings={settings}
              onChange={setSettings}
            />
          )}
          {activeSection === "github" && (
            <GitHubSection settings={settings} onChange={setSettings} />
          )}
          {activeSection === "notifications" && (
            <NotificationsSection settings={settings} onChange={setSettings} />
          )}
        </div>
      </div>
    </div>
  );
}

function GeneralSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Editor command">
        <input
          type="text"
          value={settings.editor}
          onChange={(e) => onChange({ ...settings, editor: e.target.value })}
          placeholder="code"
          className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none transition-colors"
        />
        <p className="text-[11px] text-zinc-500 mt-1">
          e.g. <code className="font-mono text-zinc-400">code</code>, <code className="font-mono text-zinc-400">cursor</code>, <code className="font-mono text-zinc-400">nvim</code>
        </p>
      </FieldGroup>

      <FieldGroup label="Session timeout (minutes)">
        <input
          type="number"
          value={settings.sessionTimeout.activeThresholdMinutes}
          onChange={(e) =>
            onChange({
              ...settings,
              sessionTimeout: {
                ...settings.sessionTimeout,
                activeThresholdMinutes: parseInt(e.target.value) || 1440,
              },
            })
          }
          className="w-32 bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 outline-none transition-colors"
        />
      </FieldGroup>

      <FieldGroup label="Terminal font size">
        <div className="flex items-center gap-3">
          <input
            type="range"
            min={8}
            max={24}
            step={1}
            value={settings.terminalFontSize || 15}
            onChange={(e) =>
              onChange({ ...settings, terminalFontSize: parseInt(e.target.value) })
            }
            className="flex-1 accent-[#4f8ef7] h-1.5 rounded-full cursor-pointer"
          />
          <span className="text-sm text-zinc-300 font-mono w-8 text-right">
            {settings.terminalFontSize || 15}
          </span>
        </div>
        <p className="text-[11px] text-zinc-500 mt-1">
          Adjust the font size in embedded terminals (8–24pt). Takes effect on next terminal launch.
        </p>
      </FieldGroup>

      <FieldGroup label="Terminal shell">
        <input
          type="text"
          value={settings.terminalShell || "cmd.exe"}
          onChange={(e) => onChange({ ...settings, terminalShell: e.target.value })}
          placeholder="cmd.exe"
          spellCheck={false}
          className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none font-mono transition-colors"
        />
        <p className="text-[11px] text-zinc-500 mt-1">
          Command used by the embedded terminal. Default <code className="font-mono text-zinc-400">cmd.exe</code> for native Windows. Set to <code className="font-mono text-zinc-400">wsl.exe</code> to run Claude inside WSL, or e.g. <code className="font-mono text-zinc-400">pwsh.exe -NoLogo</code>. Takes effect on the next terminal launch.
        </p>
      </FieldGroup>

      <FieldGroup label="Prompt template">
        <textarea
          rows={3}
          value={settings.promptTemplate}
          onChange={(e) =>
            onChange({ ...settings, promptTemplate: e.target.value })
          }
          placeholder="Optional default prompt prefix..."
          className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none resize-none transition-colors"
        />
      </FieldGroup>
    </div>
  );
}

function ProjectsSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  const addProjectViaDialog = async () => {
    const selected = await open({ directory: true, multiple: false, title: "Select project folder" });
    if (!selected || typeof selected !== "string") return;
    if (settings.projects.find((p) => p.path === selected)) return;
    onChange({
      ...settings,
      projects: [...settings.projects, { path: selected }],
    });
  };

  const removeProject = (path: string) => {
    onChange({
      ...settings,
      projects: settings.projects.filter((p) => p.path !== path),
    });
  };

  return (
    <div className="flex flex-col gap-4 max-w-lg">
      <button
        onClick={addProjectViaDialog}
        className="flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-[#4f8ef7]/90 hover:bg-[#4f8ef7] text-white text-xs font-medium transition-all shadow-lg shadow-[#4f8ef7]/15"
      >
        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
        Add Project Folder
      </button>

      {settings.projects.length === 0 && (
        <div className="text-center py-8">
          <svg className="w-8 h-8 text-zinc-700 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z" />
          </svg>
          <p className="text-sm text-zinc-500">No projects configured yet.</p>
        </div>
      )}

      <div className="flex flex-col gap-1.5">
        {settings.projects.map((p) => (
          <div
            key={p.path}
            className="flex items-center justify-between px-3 py-3 glass-card rounded-xl"
          >
            <div>
              <p className="text-sm text-zinc-300">
                {p.name ?? p.path.split(/[/\\]/).pop() ?? p.path}
              </p>
              <p className="text-[11px] text-zinc-500 font-mono">{p.path}</p>
            </div>
            <button
              onClick={() => removeProject(p.path)}
              className="text-zinc-600 hover:text-[#f85149] transition-colors ml-3"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function GitHubSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <FieldGroup label="Default issue filter">
        <input
          type="text"
          value={settings.github.defaultFilter}
          onChange={(e) =>
            onChange({
              ...settings,
              github: { ...settings.github, defaultFilter: e.target.value },
            })
          }
          placeholder="assignee:@me is:open"
          className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none transition-colors"
        />
      </FieldGroup>
      <FieldGroup label="Poll interval (seconds)">
        <input
          type="number"
          value={settings.github.pollIntervalSeconds}
          onChange={(e) =>
            onChange({
              ...settings,
              github: {
                ...settings.github,
                pollIntervalSeconds: parseInt(e.target.value) || 60,
              },
            })
          }
          className="w-32 bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 outline-none transition-colors"
        />
      </FieldGroup>
      <FieldGroup label="Merge command">
        <input
          type="text"
          value={settings.github.mergeCommand}
          onChange={(e) =>
            onChange({
              ...settings,
              github: { ...settings.github, mergeCommand: e.target.value },
            })
          }
          className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 font-mono outline-none transition-colors"
        />
      </FieldGroup>
    </div>
  );
}

function NotificationsSection({
  settings,
  onChange,
}: {
  settings: Settings;
  onChange: (s: Settings) => void;
}) {
  return (
    <div className="flex flex-col gap-5 max-w-lg">
      <Toggle
        checked={settings.notifications.notificationsEnabled}
        onChange={(v) =>
          onChange({
            ...settings,
            notifications: { ...settings.notifications, notificationsEnabled: v },
          })
        }
        label="Enable OS notifications"
        description="Show a system notification when Claude finishes a turn and needs your input"
      />

      <Toggle
        checked={settings.notifications.pushoverEnabled}
        onChange={(v) =>
          onChange({
            ...settings,
            notifications: { ...settings.notifications, pushoverEnabled: v },
          })
        }
        label="Enable Pushover notifications"
      />

      {settings.notifications.pushoverEnabled && (
        <>
          <FieldGroup label="Pushover token (optional)">
            <input
              type="password"
              value={settings.notifications.pushoverToken ?? ""}
              onChange={(e) =>
                onChange({
                  ...settings,
                  notifications: {
                    ...settings.notifications,
                    pushoverToken: e.target.value || undefined,
                  },
                })
              }
              className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none font-mono transition-colors"
            />
          </FieldGroup>
          <FieldGroup label="Pushover user key">
            <input
              type="password"
              value={settings.notifications.pushoverUserKey ?? ""}
              onChange={(e) =>
                onChange({
                  ...settings,
                  notifications: {
                    ...settings.notifications,
                    pushoverUserKey: e.target.value || undefined,
                  },
                })
              }
              className="w-full bg-white/[0.03] border border-white/[0.08] focus:border-[#4f8ef7]/40 rounded-xl px-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none font-mono transition-colors"
            />
          </FieldGroup>
        </>
      )}
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  label,
  description,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  description?: string;
}) {
  return (
    <div className="flex items-start gap-3 group">
      <label className="relative inline-flex cursor-pointer mt-0.5 shrink-0">
        <input
          type="checkbox"
          checked={checked}
          onChange={(e) => onChange(e.target.checked)}
          className="sr-only"
        />
        <div
          className={`w-9 h-5 rounded-full transition-colors ${
            checked ? "bg-[#4f8ef7]" : "bg-white/[0.08]"
          }`}
        >
          <div
            className={`w-4 h-4 bg-white rounded-full shadow mt-0.5 transition-transform ${
              checked ? "translate-x-4" : "translate-x-0.5"
            }`}
          />
        </div>
      </label>
      <div>
        <span className="text-sm text-zinc-300 group-hover:text-zinc-200 transition-colors">{label}</span>
        {description && (
          <p className="text-[11px] text-zinc-500 mt-0.5">{description}</p>
        )}
      </div>
    </div>
  );
}

function FieldGroup({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    <div>
      <label className="block text-[11px] font-medium text-zinc-400 mb-1.5 uppercase tracking-wider">
        {label}
      </label>
      {children}
    </div>
  );
}
