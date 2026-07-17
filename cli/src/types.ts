// Types matching the Swift data model in KanbanCodeCore

export type KanbanColumn =
  | "backlog"
  | "in_progress"
  | "requires_attention"
  | "in_review"
  | "done"
  | "all_sessions";

export type ActivityState =
  | "actively_working"
  | "needs_attention"
  | "idle_waiting"
  | "ended"
  | "stale";

export type PRStatus =
  | "failing"
  | "unresolved"
  | "changesRequested"
  | "reviewNeeded"
  | "pending_ci"
  | "approved"
  | "merged"
  | "closed";

export type LinkSource = "discovered" | "hook" | "manual" | "githubIssue";
export type CodingAssistant = "claude" | "gemini" | "codex";
export type CodexRuntimeBackend = "app" | "cliTmux" | "unknown";
export type RuntimeOwnership = "managed" | "observed";
export type RuntimeEvidence =
  | "userConfirmed"
  | "boardCreated"
  | "tmuxBinding"
  | "appServerSource"
  | "cliMetadata"
  | "unknown";
export type TelemetryQuality = "precise" | "limited" | "unknown";
export type CodexLifecyclePhase =
  | "queued"
  | "launching"
  | "running"
  | "waiting"
  | "inReview"
  | "done"
  | "unknown";
export type CodexLifecycleWaitReason =
  | "input"
  | "approval"
  | "ordinaryStop"
  | "fault"
  | "disconnected"
  | "launchUncertain"
  | "unknown";

export interface CodexRuntimeState {
  cardId: string;
  lifecycle: {
    phase: CodexLifecyclePhase;
    waitReason?: CodexLifecycleWaitReason;
    telemetryQuality: TelemetryQuality;
  };
  updatedAt: string;
}

export interface CodexRuntimeProvenance {
  backend: CodexRuntimeBackend;
  ownership: RuntimeOwnership;
  evidence: RuntimeEvidence;
  telemetryQuality: TelemetryQuality;
  observedAt?: string;
}

export interface CodexExecutionBinding {
  backend: CodexRuntimeBackend;
  ownership: RuntimeOwnership;
  evidence: RuntimeEvidence;
  telemetryQuality: TelemetryQuality;
  threadId?: string;
  sessionId?: string;
  tmuxSessionName?: string;
  boundAt?: string;
}

export interface CodexBoardSettings {
  runtime: CodexRuntimeBackend;
  maxConcurrency: number;
}

export interface SessionLink {
  sessionId: string;
  sessionPath?: string;
  sessionNumber?: number;
}

export interface TmuxLink {
  sessionName: string;
  extraSessions?: string[];
  tabNames?: Record<string, string>;
  isShellOnly?: boolean;
  isPrimaryDead?: boolean;
}

export interface WorktreeLink {
  path: string;
  branch?: string;
}

export interface CheckRun {
  name: string;
  status: string;
  conclusion?: string;
}

export interface PRLink {
  number: number;
  url?: string;
  status?: PRStatus;
  unresolvedThreads?: number;
  title?: string;
  body?: string;
  approvalCount?: number;
  checkRuns?: CheckRun[];
  firstUnresolvedThreadURL?: string;
  mergeStateStatus?: string;
}

export interface IssueLink {
  number: number;
  url?: string;
  body?: string;
  title?: string;
}

export interface QueuedPrompt {
  id: string;
  body: string;
  sendAutomatically: boolean;
  imagePaths?: string[];
}

export interface BrowserTabInfo {
  id: string;
  url: string;
  title?: string;
}

export interface ManualOverrides {
  worktreePath: boolean;
  tmuxSession: boolean;
  name: boolean;
  column: boolean;
  prLink: boolean;
  issueLink: boolean;
  dismissedPRs?: number[];
  branchWatermark?: number;
}

export interface Link {
  id: string;
  name?: string;
  projectPath?: string;
  column: KanbanColumn;
  createdAt: string;
  updatedAt: string;
  lastActivity?: string;
  lastOpenedAt?: string;
  manualOverrides: ManualOverrides;
  manuallyArchived: boolean;
  source: LinkSource;
  promptBody?: string;
  promptImagePaths?: string[];
  sessionLink?: SessionLink;
  tmuxLink?: TmuxLink;
  worktreeLink?: WorktreeLink;
  prLinks?: PRLink[];
  issueLink?: IssueLink;
  queuedPrompts?: QueuedPrompt[];
  browserTabs?: BrowserTabInfo[];
  discoveredBranches?: string[];
  discoveredRepos?: Record<string, string>;
  isRemote: boolean;
  sortOrder?: number;
  assistant?: CodingAssistant;
  isLaunching?: boolean;
  /// Cross-platform display/binding metadata written by the Swift app.
  /// Lifecycle snapshots and launch leases live in codex-runtime-state.json
  /// and are intentionally not part of the CLI's writable model.
  executionBinding?: CodexExecutionBinding;
}

export interface TmuxSession {
  name: string;
  path: string;
  attached: boolean;
}

export interface Project {
  path: string;
  name: string;
  repoRoot?: string;
  visible: boolean;
  githubFilter?: string;
  promptTemplate?: string;
}

export interface Settings {
  projects: Project[];
  globalView?: { excludedPaths?: string[] };
  github?: {
    defaultFilter?: string;
    pollInterval?: number;
    mergeCommand?: string;
  };
  promptTemplate?: string;
  columnOrder?: KanbanColumn[];
  hasCompletedOnboarding?: boolean;
  defaultAssistant?: CodingAssistant;
  enabledAssistants?: CodingAssistant[];
  codexBoard?: CodexBoardSettings;
}

export interface SessionContext {
  usedPercentage: number;
  contextWindowSize: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCostUsd: number;
  model: string;
}

// Output types for CLI

export interface CardSummary {
  id: string;
  name: string;
  column: KanbanColumn;
  project?: string;
  assistant?: CodingAssistant;
  executionBinding?: CodexExecutionBinding;
  lifecycle?: CodexRuntimeState["lifecycle"];
  needsAttention?: boolean;
  sessionId?: string;
  tmuxSession?: string;
  tmuxAlive: boolean;
  worktree?: string;
  branch?: string;
  prs: { number: number; status?: PRStatus; url?: string }[];
  lastActivity?: string;
  lastMessage?: string;
  peek?: string;
  queuedPrompts: number;
  isRemote: boolean;
  tokens?: {
    input: number;
    output: number;
    cost: number;
    context: { used: number; max: number; percentage: string };
    model?: string;
  };
}

export interface CardDetail extends CardSummary {
  promptBody?: string;
  sessionPath?: string;
  extraTmuxSessions: string[];
  prDetails: PRLink[];
  issueLink?: IssueLink;
  browserTabs: BrowserTabInfo[];
  queuedPromptBodies: QueuedPrompt[];
  transcript?: TranscriptTurn[];
}

export interface TranscriptTurn {
  role: string;
  text: string;
  timestamp?: string;
}
