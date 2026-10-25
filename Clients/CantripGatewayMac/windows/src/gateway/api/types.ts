/**
 * Cantrip host remote-control HTTP API: request and response shapes.
 *
 * Authoritative sources (Swift):
 * - Server (what the host encodes): Cantrip/Sources/Cantrip/RemoteControlServer.swift and its
 *   models (RemoteHistory, CantripHome*, Remote*, ChatSession, GitHubBuildMonitor, CopilotUsage...).
 * - Mac/iOS client (what Cantrip Gateway sends/decodes): CantripGatewayMac/Hermes/Sources/CantripRemote.swift
 *   and related Cantrip*.swift files.
 * Where they disagree, these types follow the server and say so.
 *
 * Conventions
 * - Every `/api/v1/...` route requires `Authorization: Bearer <pairing token>`; otherwise 401.
 * - Errors are JSON `{ "error": string }` ({@link ApiErrorResponse}) with a 4xx/5xx status.
 * - UUIDs are emitted as uppercase `UUID.uuidString`; the server parses them case-insensitively.
 * - An optional (`?`) field is OMITTED when absent. The server never sends `null` except where a
 *   type says `| null` (live-status tabs).
 * - Dates use three encodings. Each date field's doc comment names its encoding:
 *   - {@link UnixSeconds}: seconds since 1970-01-01Z (fractional).
 *   - {@link AppleReferenceSeconds}: seconds since 2001-01-01Z (Swift `JSONEncoder`'s default `Date`
 *     encoding). Convert with `new Date((v + 978307200) * 1000)`.
 *   - {@link ISO8601String}: an RFC 3339 string.
 * - Binary payloads are standard base64 strings ({@link Base64String}) inside JSON, never raw bodies.
 *   The exception is chunk uploads (PUT .../files/<id> and .../videos/<id>), whose body is raw bytes.
 *
 * This file declares types only. Its runtime values are string-literal `const` arrays.
 */

// MARK: - Primitives

/** Hyphenated UUID string. The server emits uppercase; accepts any case. */
export type UUIDString = string;
/** Seconds since 1970-01-01T00:00:00Z (may be fractional). `new Date(v * 1000)`. */
export type UnixSeconds = number;
/**
 * Seconds since 2001-01-01T00:00:00Z (Apple reference date; Swift `JSONEncoder` default for `Date`).
 * `new Date((v + 978307200) * 1000)`. The host's web client does the same for Home task times.
 */
export type AppleReferenceSeconds = number;
/** ISO-8601 / RFC 3339 timestamp string, e.g. "2026-10-23T07:48:03Z". */
export type ISO8601String = string;
/** Standard (RFC 4648, padded) base64. */
export type Base64String = string;
/** 64 lowercase hex characters (SHA-256 digest). */
export type HexSHA256 = string;
/** Integer (the server rejects non-integers where this is used in a request). */
export type Int = number;

// MARK: - Enumerations

/** How a sent message is delivered (`MessageDeliveryMode`). UI titles: Auto, Queue, Redirect, Inject. */
export const DELIVERY_MODES = ['auto', 'queue', 'interrupt', 'inject'] as const;
export type DeliveryMode = (typeof DELIVERY_MODES)[number];

/** `ChatMessage.Role`. `handoff` = Home result card; `freshStart` = Start Fresh divider. */
export const MESSAGE_ROLES = ['user', 'assistant', 'error', 'handoff', 'freshStart'] as const;
export type MessageRole = (typeof MESSAGE_ROLES)[number];

/** Tool activity / subagent step state (`ToolActivityState`). */
export const ACTIVITY_STATES = ['running', 'succeeded', 'failed', 'cancelled'] as const;
export type ActivityState = (typeof ACTIVITY_STATES)[number];

/**
 * `SubagentInfo.Status`. Live (still working): queued, running, idle. The Mac client maps any
 * unknown value to an internal "working" (live, not cancellable) state.
 */
export const SUBAGENT_STATUSES = ['queued', 'running', 'idle', 'completed', 'failed', 'cancelled'] as const;
export type SubagentStatus = (typeof SUBAGENT_STATUSES)[number];

/** Home handoff (`CantripHomeDelegation.Status`). Active: queued, running. */
export const DELEGATION_STATUSES = ['queued', 'running', 'completed', 'failed', 'cancelled'] as const;
export type DelegationStatus = (typeof DELEGATION_STATUSES)[number];

/** Home handoff result card state (`CantripHomeHandoffResult.State`). The Mac maps unknown values to "other". */
export const HANDOFF_RESULT_STATES = ['working', 'needsInput', 'completed', 'failed', 'cancelled'] as const;
export type HandoffResultState = (typeof HANDOFF_RESULT_STATES)[number];

/** `InputRequestSnapshot.Kind`. */
export const INPUT_REQUEST_KINDS = ['approval', 'question', 'secret', 'login', 'localAction'] as const;
export type InputRequestKind = (typeof INPUT_REQUEST_KINDS)[number];

/**
 * `InputRequestAnswer.Decision`. Valid combinations (Backend.swift `respond`):
 * - `deny` / `cancel`: any kind, `text` must be absent.
 * - `approve`: approval, login, localAction; `text` absent.
 * - `submit`: question (non-empty text; must be one of `choices` unless `allowsFreeform`) and
 *   secret (non-empty, no CR/LF/NUL). `text` at most 8192 UTF-8 bytes.
 */
export const INPUT_DECISIONS = ['approve', 'deny', 'submit', 'cancel'] as const;
export type InputDecision = (typeof INPUT_DECISIONS)[number];

/** Tab move placement. */
export const PLACEMENTS = ['before', 'after'] as const;
export type Placement = (typeof PLACEMENTS)[number];

/** `CantripHomeSchedule.Kind`. */
export const HOME_SCHEDULE_KINDS = ['once', 'interval', 'weekdays'] as const;
export type HomeScheduleKind = (typeof HOME_SCHEDULE_KINDS)[number];

/** `CantripHomeTask.State`. `ready` = an unscheduled (manual) task that is not running. */
export const HOME_TASK_STATES = ['scheduled', 'running', 'succeeded', 'failed', 'paused', 'ready'] as const;
export type HomeTaskState = (typeof HOME_TASK_STATES)[number];

/** Workspace field kinds (`CantripHomeTaskField.Kind`) and the string format each record value uses. */
export const HOME_FIELD_KINDS = ['text', 'longText', 'number', 'boolean', 'date', 'dateTime', 'choice', 'url'] as const;
export type HomeFieldKind = (typeof HOME_FIELD_KINDS)[number];

/** Background run kind (`CantripHomeBackgroundRun.Kind`). */
export const HOME_RUN_KINDS = ['task', 'incident'] as const;
export type HomeRunKind = (typeof HOME_RUN_KINDS)[number];

/** Background run route: its own hidden session, or handed to a project tab. */
export const HOME_RUN_ROUTES = ['hidden', 'tab'] as const;
export type HomeRunRoute = (typeof HOME_RUN_ROUTES)[number];

/**
 * Known background-run / task-run status strings (field type is `string`; treat others as finished).
 * `running` is live; `interrupted` = the Mac app quit mid-run; `skipped` = de-duplicated or resolved.
 */
export const HOME_RUN_STATUSES = ['running', 'succeeded', 'failed', 'cancelled', 'interrupted', 'skipped'] as const;
export type HomeRunStatus = (typeof HOME_RUN_STATUSES)[number];

/** `CantripHomeArtifact.kind` values derived from the file extension (Home may also supply its own). */
export const HOME_ARTIFACT_KINDS = ['image', 'video', 'audio', 'document'] as const;
export type HomeArtifactKind = (typeof HOME_ARTIFACT_KINDS)[number];

/** `RemoteMaintenanceAction`. */
export const MAINTENANCE_ACTIONS = ['check', 'update', 'rebuild', 'restart'] as const;
export type MaintenanceAction = (typeof MAINTENANCE_ACTIONS)[number];

/** Maintenance job phases. Finished: succeeded, failed (`finishedAt` set). */
export const MAINTENANCE_PHASES = ['starting', 'checking', 'updating', 'building', 'restarting', 'succeeded', 'failed'] as const;
export type MaintenancePhase = (typeof MAINTENANCE_PHASES)[number];

/** `LiveStatusTabState`. */
export const LIVE_TAB_STATES = ['input', 'running', 'done', 'failed', 'stopped', 'idle'] as const;
export type LiveTabState = (typeof LIVE_TAB_STATES)[number];

/** Memory catalog categories, in server sort order. */
export const MEMORY_CATEGORIES = ['core', 'notes', 'sessions'] as const;
export type MemoryCategory = (typeof MEMORY_CATEGORIES)[number];

/** `MacPermission`. */
export const MAC_PERMISSIONS = [
  'screenRecording', 'accessibility', 'microphone', 'speechRecognition', 'fullDiskAccess', 'keychain', 'authentication',
] as const;
export type MacPermission = (typeof MAC_PERMISSIONS)[number];

/** `MacPermissionStatus.state` values. */
export const MAC_PERMISSION_STATES = [
  'granted', 'notGranted', 'restartRequired', 'manualCheck', 'needsAttention', 'checkedWhenUsed',
  'localBiometricsAvailable', 'localPasswordRequired',
] as const;
export type MacPermissionState = (typeof MAC_PERMISSION_STATES)[number];

/** Desktop input command kinds (`DesktopCommand.kind`). */
export const DESKTOP_COMMAND_KINDS = ['click', 'rightClick', 'doubleClick', 'text', 'key', 'scroll'] as const;
export type DesktopCommandKind = (typeof DESKTOP_COMMAND_KINDS)[number];

/** Keys accepted by a `key` desktop command. */
export const DESKTOP_KEYS = ['return', 'tab', 'escape', 'delete', 'left', 'right', 'down', 'up'] as const;
export type DesktopKey = (typeof DESKTOP_KEYS)[number];

/** Session actions under POST /api/v1/sessions/<id>/<action> that take no body. */
export const SESSION_ACTIONS = ['cancel', 'resume', 'new-conversation', 'start-fresh', 'close'] as const;
export type SessionAction = (typeof SESSION_ACTIONS)[number];

/** MCP App server methods a view may call through POST .../apps/<appID>/request. */
export const MCP_APP_METHODS = ['tools/call', 'tools/list', 'resources/read'] as const;
export type MCPAppMethod = (typeof MCP_APP_METHODS)[number];

/** Model context tiers known to the client ("default" = Standard, "long_context" = Long). */
export const CONTEXT_TIERS = ['default', 'long_context'] as const;
export type ContextTier = (typeof CONTEXT_TIERS)[number];

/** GitHub build job assignment: only "assigned" means GitHub picked this runner. */
export const BUILD_JOB_ASSIGNMENTS = ['assigned', 'eligible', 'workflow'] as const;
export type BuildJobAssignment = (typeof BUILD_JOB_ASSIGNMENTS)[number];

// MARK: - Generic responses

/** Every non-2xx JSON body. */
export interface ApiErrorResponse {
  error: string;
}

/** Conditional fetch hit: the client's `revision` still matches. */
export interface UnchangedResponse {
  unchanged: true;
}

/** `{ "accepted": true }` (input answer, desktop input, MCP context). */
export interface AcceptedResponse {
  accepted: true;
}

/** `{ "deleted": true }` (Home task and artifact DELETE). */
export interface DeletedResponse {
  deleted: true;
}

/** Image and preview reads: `{ data }` with base64 JPEG bytes. */
export interface ImageDataResponse {
  /** Base64 JPEG. Mac client limits: 1 MiB for attachments, 4 MiB for generated previews. */
  data: Base64String;
}

/** GET /health (no auth). */
export interface HealthResponse {
  status: 'ok';
}

// MARK: - Conversation models

/** One tool call in a reply (`RemoteHistory.message` → `activities[]`). */
export interface RemoteActivity {
  id: string;
  title: string;
  toolName: string;
  state: ActivityState;
  /** Tool input text; omitted when none. */
  input?: string;
  /** Tool output text; omitted when none. */
  output?: string;
}

/** A recent step of a subagent (last 6). The Mac client derives an id from title+toolName+state. */
export interface RemoteSubagentStep {
  title: string;
  toolName: string;
  state: ActivityState;
}

/** One titled reasoning step. */
export interface RemoteReasoningStep {
  title: string;
  /** Text after the title (the whole text when the title was shortened). */
  text: string;
  /** 1-based position in the whole reply or subagent run (stable across dropped steps). */
  number: Int;
}

/** Subagent monitor card (`RemoteHistory.subagent`). */
export interface RemoteSubagent {
  /** Activity (tool-call) ID. */
  id: string;
  /** Backend agent/task ID; the cancel target in POST .../subagents/<agentID>/cancel. */
  agentID: string;
  name: string;
  agentType: string;
  summary: string;
  model?: string;
  effort?: string;
  /** Detached/background agent (counts toward Home's background badge while live). */
  background: boolean;
  status: SubagentStatus;
  /** UnixSeconds. */
  startedAt: UnixSeconds;
  /** UnixSeconds; omitted while active. */
  finishedAt?: UnixSeconds;
  intent?: string;
  /** Title of the running (else latest) step. */
  currentStep?: string;
  latestMessage?: string;
  /** Tool calls made. */
  steps: Int;
  tokens: Int;
  error?: string;
  /** True only when the backend can stop this agent alone AND it is still active. */
  canCancel: boolean;
  recentSteps: RemoteSubagentStep[];
  /** Latest ≤8 reasoning steps; omitted when none. */
  reasoning?: RemoteReasoningStep[];
  /** Finished cards only: the card follows this many reply blocks (0 = before the text). */
  textBlock?: Int;
}

/** Work Cantrip Home handed to a project tab (`CantripHomeDelegation.snapshot`). */
export interface RemoteDelegation {
  id: UUIDString;
  tabID: UUIDString;
  tabTitle: string;
  summary: string;
  prompt: string;
  status: DelegationStatus;
  /** UnixSeconds. */
  startedAt: UnixSeconds;
  /** UnixSeconds. */
  finishedAt?: UnixSeconds;
  latestStatus?: string;
  /** Present (true) only while the tab waits on the user. */
  needsInput?: true;
  /** What the tab asks while waiting (untrusted tab text). */
  question?: string;
  result?: string;
  /** One- or two-sentence outcome (untrusted tab text). */
  outcome?: string;
  error?: string;
}

/** Home result card carried by a message with role `handoff` (`CantripHomeHandoffResult.snapshot`). */
export interface RemoteHandoffResult {
  delegationID: UUIDString;
  tabID: UUIDString;
  tabTitle: string;
  summary: string;
  state: HandoffResultState;
  /** Outcome, question or error as plain text (render as data, never as Markdown from Home). */
  detail: string;
  /** UnixSeconds. */
  startedAt: UnixSeconds;
  /** UnixSeconds. */
  finishedAt?: UnixSeconds;
  /** UnixSeconds. */
  updatedAt: UnixSeconds;
}

/** Context size and token use for a prompt (user messages only). Absent keys are unknown. */
export interface PromptUsage {
  modelCalls: Int;
  inputTokens: Int;
  cachedInputTokens: Int;
  outputTokens: Int;
  contextTokens?: Int;
  contextLimit?: Int;
  systemTokens?: Int;
  toolTokens?: Int;
  conversationTokens?: Int;
  /** Estimated (chars/4) tokens of the message as sent, including what Cantrip added. */
  messageTokens?: Int;
  addedTokens?: Int;
  latestContextTokens?: Int;
}

/**
 * Image reference in a message, queued prompt or input request.
 * - User attachments: `"<UUID>/image-<1..4>.jpg"` → GET /sessions/<sid>/attachments/<id>[/thumbnail].
 * - Generated previews: `"previews/<messageUUID>/<64 hex>.jpg"` → GET /sessions/<sid>/<id>[/thumbnail].
 * Markdown in `displayText` refers to previews as `cantrip-preview://image/<id>`.
 */
export interface MessageImageRef {
  id: string;
  /** Previews only. */
  altText?: string;
}

/** Interactive MCP App view summary on a reply (only when MCP Apps are enabled on the Mac). */
export interface MCPAppSummary {
  id: string;
  serverName: string;
  toolName: string;
  title?: string;
  prefersBorder?: boolean;
}

/** One transcript message (`RemoteHistory.message` + `messageSnapshot`). */
export interface RemoteMessage {
  id: UUIDString;
  role: MessageRole;
  /** Raw text. For Home assistant replies, Cantrip's protocol blocks are already stripped. */
  text: string;
  /** Raw streamed reasoning ("" when none). */
  thinking: string;
  activities: RemoteActivity[];
  /** Always present: true only in the Private Local tab. */
  isLocalPrivate: boolean;
  /** Council mode: the model that wrote it. */
  author?: string;
  /** User messages with usage only. */
  promptUsage?: PromptUsage;
  delegations?: RemoteDelegation[];
  /** role === 'handoff' only. */
  handoffResult?: RemoteHandoffResult;
  reasoning?: RemoteReasoningStep[];
  subagents?: RemoteSubagent[];
  apps?: MCPAppSummary[];
  /**
   * Show instead of `text` when present. User messages: attachment markers removed and files shown
   * as "📎 name" lines. Assistant messages: Mac image paths rewritten to preview links.
   */
  displayText?: string;
  /** Present together with `displayText` when images were found. */
  images?: MessageImageRef[];
  /** Legacy: read by the web client; the current server never sets it. */
  isPreview?: boolean;
}

/** A queued prompt (session detail only). */
export interface QueuedPrompt {
  id: UUIDString;
  text: string;
  /**
   * Paged responses (`history=recent`): always present (equals `text` without attachments).
   * Full responses: only when attachments replaced the text.
   */
  displayText?: string;
  /** Paged: always present (may be []). Full: only with `displayText`. */
  images?: MessageImageRef[];
}

/** Image in a question's `detail` rewritten to a preview (`InputRequestSnapshot.PreviewImage`). */
export interface InputRequestImage {
  id: string;
  altText: string;
}

/**
 * A pending approval, question, secret, login or local action (`InputRequestSnapshot`).
 * Identical shape in session snapshots (`pendingInputs`), GET .../input and background `inputs`.
 */
export interface InputRequest {
  id: UUIDString;
  kind: InputRequestKind;
  /** Who asks (≤160 chars). */
  source: string;
  /** ≤240 chars. */
  title: string;
  /** Markdown for questions. */
  detail: string;
  /** Suggested answers (question). Always present, may be []. */
  choices: string[];
  /** Question accepts text other than `choices`. */
  allowsFreeform: boolean;
  /** Login/local action URL. */
  url?: string;
  /** Device/login code. */
  code?: string;
  /** UnixSeconds. Requests last 600 s by default; expired ones are cancelled by the Mac. */
  expiresAt: UnixSeconds;
  /** Questions with Mac images only: `detail` with previews linked. Sent together with `images`. */
  displayText?: string;
  images?: InputRequestImage[];
}

// MARK: - Sessions (tabs)

/**
 * Session summary: one tab in GET /api/v1/sessions, `home`, POST .../move, GET /ready.
 * Detail responses ({@link RemoteSessionDetail}) carry all of these plus messages and queue.
 */
export interface RemoteSessionSummary {
  id: UUIDString;
  /** Auto title. */
  title: string;
  /** User's name for the tab; "" when none (always present). Show it instead of `title` when non-empty. */
  customTitle: string;
  isLocked: boolean;
  /** The saved Private Local (self-hosted model) tab. */
  isLocalPrivate: boolean;
  isCantripHome: boolean;
  /** Home's background log or one of its hidden runs. */
  isCantripHomeBackground: boolean;
  workdir: string;
  isStreaming: boolean;
  /** An interrupted run can be resumed (POST .../resume). */
  canResume: boolean;
  councilMode: boolean;
  queuedCount: Int;
  /** Live status line (statusText), e.g. "Waiting for your input"; omitted when none. */
  status?: string;
  /** Delivery notice for the last sent/queued message; omitted when none. */
  deliveryStatus?: string;
  /** The latest message when it's an error repeating the previous one with no reply between. */
  repeatedErrorMessageID?: UUIDString;
  pendingInputCount: Int;
  /** Always present (may be []). */
  pendingInputs: InputRequest[];
  modelSettingsRevision: string;
  /** SHA-256 hex over the summary fields + message/queue mutation tokens. Use as `?revision=`. */
  historyRevision: string;
  /** UnixSeconds. Current run's start while working, else when the latest run finished (or transcript mtime). Omitted for Home/background sessions and tabs that never ran. */
  lastActivityAt?: UnixSeconds;
  /** One line (≤140) about the latest reply; omitted while streaming and for Home/background sessions. */
  preview?: string;

  // Capability flags (all always present on current hosts; absent means an older host).
  supportsPrivateLocalSettings: boolean;
  supportsInputRequests: true;
  supportsChatInputReplies: true;
  /** False for Home/background sessions. */
  supportsTabMetadata: boolean;
  supportsTabReordering: boolean;
  /** The tab can be filed under a section. Absent on hosts without sections. */
  supportsTabSections?: boolean;
  /** The section the tab is filed under; absent shows it under Tabs. */
  sectionID?: string;
  /** False for Private Local and Home background sessions. */
  supportsModelSettings: boolean;
  /** True when the backend is Claude, Copilot or Codex. */
  supportsImageAttachments: boolean;
  supportsVideoAttachments: boolean;
  supportsFileAttachments: boolean;
  /** Images, a video and files together in one message. */
  supportsMixedAttachments: true;
  supportsAutoDelivery: true;
  supportsQueueRemoval: true;
  supportsQueueSendNow: true;
  supportsPagedHistory: true;
  /** False for Home-reserved sessions. */
  supportsStartFresh: boolean;
  /** GET .../commands lists the backend's slash commands and skills. Absent on older hosts: never call it. */
  supportsBackendCommands?: boolean;

  // Cantrip Home session only.
  /** Home only: always true there. */
  supportsBackgroundRuns?: true;
  /** Home only: queued jobs + running hidden runs + running tab handoffs. */
  backgroundActiveCount?: Int;
  /** Home only: total pending input requests across live hidden runs. */
  backgroundInputCount?: Int;
}

/** Session with transcript and queue (GET /sessions/<id>, actions, /home). */
export interface RemoteSessionDetail extends RemoteSessionSummary {
  messages: RemoteMessage[];
  queued: QueuedPrompt[];
  /** Paged responses only: ID of the session's first message overall, or "empty". */
  historyStartID?: string;
  /** Paged responses only: older messages exist before `messages[0]`. */
  hasOlderMessages?: boolean;
}

/** Detail as returned with `history=recent` (what Cantrip Gateway should always request). */
export interface PagedRemoteSessionDetail extends RemoteSessionDetail {
  historyStartID: string;
  hasOlderMessages: boolean;
}

/** `{ session }` wrapper used by every single-session response. */
export interface SessionResponse<S extends RemoteSessionDetail = PagedRemoteSessionDetail> {
  session: S;
}

/** GET /api/v1/sessions/<id>?revision=… and GET /api/v1/home?revision=… (paged mode). */
export type SessionUpdateResponse<S extends RemoteSessionDetail = PagedRemoteSessionDetail> =
  | SessionResponse<S>
  | UnchangedResponse;

/** A hidden Home background run waiting on the user (listed because it is never a tab). */
export interface HomeInputGroup {
  runID: UUIDString;
  /** The run's hidden session; answer via POST /sessions/<sessionID>/input/<requestID>. */
  sessionID: UUIDString;
  label: string;
  requests: InputRequest[];
}

/** GET /api/v1/sessions. */
export interface SessionsListResponse {
  /** Visible tabs in Mac order (Home and background sessions are not included). */
  sessions: RemoteSessionSummary[];
  /** Hash of the host's embedded web app; browser clients reload when it changes. */
  uiRevision: string;
  /** Present only when Cantrip Home is enabled on the Mac. */
  home?: RemoteSessionSummary;
  /** Present only when non-empty and Home is enabled. Not decoded by the Mac client. */
  homeInputs?: HomeInputGroup[];
  /** Named groups for the tab list, in order. Absent on hosts without sections. */
  sections?: TabSection[];
  supportsTabSections?: boolean;
}

/** GET /api/v1/ready. */
export interface ReadyResponse {
  status: 'ready';
  sessions: RemoteSessionSummary[];
}

/** POST /api/v1/sessions/<id>/move response. */
export interface MoveTabResponse {
  sessions: RemoteSessionSummary[];
  sections?: TabSection[];
}

/** A named group of tabs (the Mac keeps them; `/api/v1/sections`). */
export interface TabSection {
  id: string;
  name: string;
}

export interface TabSectionsResponse {
  sections: TabSection[];
  section?: TabSection;
  sessions?: RemoteSessionSummary[];
}

/** GET /api/v1/sessions/<id>/messages/<messageID>. */
export interface FullMessageResponse {
  message: RemoteMessage;
}

/** GET /api/v1/sessions/<id>/input. */
export interface InputRequestsResponse {
  requests: InputRequest[];
}

/** POST /api/v1/sessions/<id>/subagents/<agentID>/cancel. */
export interface SubagentCancelResponse {
  cancelled: boolean;
}

// MARK: - Backend slash commands

/** `BackendCommand.kind`. Unknown values are shown like "custom". */
export const BACKEND_COMMAND_KINDS = ['builtin', 'custom', 'skill', 'cantrip'] as const;
export type BackendCommandKind = (typeof BACKEND_COMMAND_KINDS)[number];

/** "runs": the backend runs it; "cantrip": Cantrip's own equivalent (see `note`); "unavailable": can't run from Cantrip. */
export const BACKEND_COMMAND_AVAILABILITIES = ['runs', 'cantrip', 'unavailable'] as const;
export type BackendCommandAvailability = (typeof BACKEND_COMMAND_AVAILABILITIES)[number];

/** One slash command, custom command or skill of the tab's backend. Unlike most types here, absent values may be `null`. */
export interface BackendCommand {
  /** Without the leading slash: what the user types after "/". */
  name: string;
  /** One line (may be long). */
  description: string;
  kind: BackendCommandKind | string;
  /** Short display label ("Copilot", "Project", "Personal", "System", …). */
  source: string;
  /** Argument hint shown after the name, e.g. "prompt" or "[on|off]". */
  inputHint?: string | null;
  /** The command needs text after it. */
  requiresInput: boolean;
  aliases?: string[] | null;
  /** Exact composer text when chosen (usually "/name ", Codex skills "$name "). Never build it. */
  insert: string;
  availability: BackendCommandAvailability | string;
  /** Why it's unavailable, or how Cantrip handles it. */
  note?: string | null;
  /** Client action for "cantrip" rows: "modelSettings" opens the tab's model settings. Unknown: insert. */
  action?: string | null;
}

/** GET /api/v1/sessions/<id>/commands[?refresh=true] (sessions with `supportsBackendCommands`; 404 for unknown sessions). */
export interface BackendCommandsResponse {
  /** Cantrip backend label of the tab ("Copilot", "Claude Code", "Codex", …). Display only. */
  backend: string;
  /** The tab folder the list was discovered for. */
  workdir: string;
  /** Changes whenever the list changes. */
  revision: string;
  /** One line to show when the list is empty or partial. */
  status?: string | null;
  /** Host order (kept for equal match scores). */
  commands: BackendCommand[];
}

// MARK: - Session requests

/** Query parameters understood by session-returning routes. */
export interface HistoryQuery {
  /** Enables paged history, `{unchanged:true}` and `recentExchanges`. The Mac sends it on EVERY request. */
  history?: 'recent';
  /** 1–3 (400 otherwise): return complete last N user→reply exchanges. The Mac sends 3 on session reads and mutations. Ignored with `before`. */
  recentExchanges?: 1 | 2 | 3;
  /** GET /sessions/<id> and /home: the cached `historyRevision`; match → `{unchanged:true}`. Ignored with `before`. */
  revision?: string;
  /** GET /sessions/<id>: older page ending before this message UUID. 409 if the message is gone. */
  before?: UUIDString;
}

/** One inline image (`CantripMessageBody.ImageUpload`): base64 JPEG ≤1 MiB, 1–2048 px per side. */
export interface ImageUpload {
  data: Base64String;
}

/**
 * POST /api/v1/sessions/<id>/messages body (`CantripMessageBody`). Absent optionals are omitted.
 * Rules (server): `text` required (may be "" when images/video/files are attached); ≤4 images;
 * ≤5 unique `fileIDs`; attachments refused for prompts starting with "!" or "/"; `inputRequestID`
 * requires mode "auto" and a pending, unexpired `question` of this session.
 */
export interface SendMessageRequest {
  text: string;
  /** Defaults to "auto" when omitted. The Mac always sends it. */
  mode: DeliveryMode;
  images?: ImageUpload[];
  /** A completed (and prepared) video upload ID. */
  videoID?: UUIDString;
  /** Completed file upload IDs. Omit (never []) when none. */
  fileIDs?: UUIDString[];
  /** Answer this pending question in chat instead of sending a new prompt. */
  inputRequestID?: UUIDString;
}

/** POST /api/v1/sessions/<id>/metadata. At least one key; no other keys. */
export interface TabMetadataUpdateRequest {
  /** Whitespace-collapsed, ≤80 chars; "" clears the custom title. */
  customTitle?: string;
  isLocked?: boolean;
}

/** POST /api/v1/sessions/<id>/move. Exactly these keys. */
export interface MoveRequest {
  targetID: UUIDString;
  placement: Placement;
}

/** POST /api/v1/sessions/<id>/input/<requestID>. Keys ⊆ {decision, text}; `decision` required. */
export interface InputAnswerRequest {
  decision: InputDecision;
  /** Only with `submit`. ≤8192 UTF-8 bytes. Body ≤12000 bytes. */
  text?: string;
}

// MARK: - Uploads (files and videos)

/** Query for PUT /api/v1/sessions/<id>/files/<uploadID> (all required; values percent-encoded). */
export interface FileChunkQuery {
  /** Byte offset of this chunk; must equal the Mac's `receivedBytes` (or repeat an identical earlier chunk). */
  offset: Int;
  /** 1 … 104857600 (100 MiB). */
  totalBytes: Int;
  /** Display name, 1–160 chars, no control characters. */
  name: string;
  /** SHA-256 of the whole file, lowercase hex. */
  sha256: HexSHA256;
}

/** Query for PUT /api/v1/sessions/<id>/videos/<uploadID> (all required). */
export interface VideoChunkQuery extends FileChunkQuery {
  /** "mov" or "mp4". */
  format: 'mov' | 'mp4';
}

/** `RemoteFileUpload` manifest (GET/PUT .../files/<uploadID>). */
export interface FileUploadStatus {
  totalBytes: Int;
  name: string;
  sha256: HexSHA256;
  receivedBytes: Int;
  /** Claimed by a sent message. */
  claimed: boolean;
}

/** `RemoteVideoUpload` manifest (GET/PUT .../videos/<uploadID>). */
export interface VideoUploadStatus extends FileUploadStatus {
  format: 'mov' | 'mp4';
}

export interface FileUploadResponse {
  upload: FileUploadStatus;
}

export interface VideoUploadResponse {
  upload: VideoUploadStatus;
}

/** POST /api/v1/sessions/<id>/videos/<uploadID>/prepare. */
export interface VideoPrepareResponse {
  ready: true;
}

// MARK: - Model settings and Private Local

/** Empty strings mean "use default". */
export interface ModelSelection {
  model: string;
  effort: string;
  /** "", "default" or "long_context" (or another tier listed by the model). */
  contextTier: string;
}

/** `CopilotModelInfo`. */
export interface ModelOption {
  id: string;
  contextWindow?: Int;
  maxOutputTokens?: Int;
  /** Omitted = unknown; [] = effort unsupported. */
  reasoningEfforts?: string[];
  contextTiers?: string[];
  defaultContextPromptTokens?: Int;
  longContextPromptTokens?: Int;
}

/** GET/POST /api/v1/sessions/<id>/model-settings (`SessionModelSettingsSnapshot`). */
export interface ModelSettingsSnapshot {
  /** Effective selection (override or defaults). */
  selection: ModelSelection;
  /** Mac defaults. */
  defaults: ModelSelection;
  usesDefaults: boolean;
  /** Echo back in POST; mismatch → 409. */
  revision: string;
  models: ModelOption[];
  fileDefaultModel?: string;
  fileDefaultContextTier?: string;
  /** Why changes are refused now (busy, non-Copilot backend, Council mode). */
  unavailableReason?: string;
  catalogError?: string;
  /** Catalog refresh in flight; the Mac re-reads every 1 s (≤30 times). */
  isRefreshing: boolean;
}

/** POST model-settings to use Mac defaults: exactly these keys. */
export interface ModelSettingsUseDefaultsRequest {
  revision: string;
  usesDefaults: true;
}

/** POST model-settings with an override: exactly these keys (strings, may be ""). */
export interface ModelSettingsOverrideRequest extends ModelSelection {
  revision: string;
  usesDefaults: false;
}

export type ModelSettingsUpdateRequest = ModelSettingsUseDefaultsRequest | ModelSettingsOverrideRequest;

/** `PrivateLocalConfiguration`. */
export interface PrivateLocalConfiguration {
  /** OpenAI-compatible server, e.g. "http://127.0.0.1:11434". */
  baseURL: string;
  model: string;
  /** Integer tokens. */
  contextWindow: Int;
  systemPrompt: string;
}

/** GET/POST /api/v1/sessions/<privateLocalID>/private-settings. */
export interface PrivateLocalSettingsSnapshot {
  configuration: PrivateLocalConfiguration;
  revision: string;
  unavailableReason?: string;
}

/** POST private-settings: exactly {revision, configuration} with all four configuration keys. */
export interface PrivateLocalUpdateRequest {
  revision: string;
  configuration: PrivateLocalConfiguration;
}

/** GET /api/v1/sessions/<privateLocalID>/private-models?baseURL=… */
export interface PrivateLocalModelsResponse {
  models: string[];
}

// MARK: - Cantrip Home: tasks

/** Wall-clock time `{hour, minute}` (decoder also accepts "HH:mm"). */
export interface HomeScheduleTime {
  hour: Int;
  minute: Int;
}

/** `CantripHomeSchedule`. */
export interface HomeSchedule {
  kind: HomeScheduleKind;
  /** Human summary, e.g. "Weekdays at 9:00 AM". */
  summary: string;
  /** IANA zone ID. */
  timeZone: string;
  /** AppleReferenceSeconds. `once`: when; `interval`: baseline. */
  startAt?: AppleReferenceSeconds;
  /** `interval`: 5 … 525600. */
  intervalMinutes?: Int;
  /** `weekdays`: 1 = Sunday … 7 = Saturday (Gregorian `weekday`). */
  weekdays?: Int[];
  /** Earliest daily run time (kept for older clients). */
  hour?: Int;
  minute?: Int;
  /** `weekdays`: every daily run time, earliest first (newer hosts; not decoded by the Mac client). */
  times?: HomeScheduleTime[];
}

/** A finished run in a task's history (newest first, ≤20). */
export interface HomeTaskRun {
  id: UUIDString;
  /** AppleReferenceSeconds. */
  startedAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  finishedAt: AppleReferenceSeconds;
  /** "succeeded" | "failed" | "cancelled" | … */
  status: string;
  summary: string;
  /** The model the run used (newer hosts). */
  model?: string;
}

export interface HomeTaskField {
  key: string;
  label: string;
  kind: HomeFieldKind;
  required: boolean;
  /** `choice` options. JSON may carry this key absent. */
  options?: string[];
}

export interface HomeTaskListGroup {
  title: string;
  /** `groupField` choice values in this section. */
  values: string[];
  /** Starts collapsed (per-device expansion). */
  collapsed?: boolean;
}

export interface HomeTaskListPresentation {
  titleField: string;
  subtitleFields: string[];
  badgeField?: string;
  /** A `date`/`dateTime` field shown on rows. */
  dateField?: string;
  /** A `choice` field that splits the list into sections. */
  groupField?: string;
  groups?: HomeTaskListGroup[];
}

export interface HomeTaskDetailSection {
  title?: string;
  fields: string[];
}

/**
 * A workspace record. `values` are strings keyed by field key; by kind:
 * number → decimal text; boolean → "true"/"false"; date → "YYYY-MM-DD"; dateTime → ISO-8601;
 * choice → one of `options`; url → http(s) URL; text/longText → any (≤4000 chars).
 */
export interface HomeTaskRecord {
  id: UUIDString;
  values: Record<string, string>;
  /** AppleReferenceSeconds. */
  createdAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  updatedAt: AppleReferenceSeconds;
}

export interface HomeTaskWorkspace {
  /** Singular noun, e.g. "Package". */
  recordLabel: string;
  recordLabelPlural?: string;
  /** SF Symbol name. */
  icon: string;
  fields: HomeTaskField[];
  list: HomeTaskListPresentation;
  detailSections: HomeTaskDetailSection[];
  records: HomeTaskRecord[];
}

/** `CantripHomeTask`. */
export interface HomeTask {
  id: UUIDString;
  title: string;
  prompt: string;
  schedule: HomeSchedule;
  /** `false` = manual task (schedule is a placeholder). Omitted means scheduled. */
  hasSchedule?: boolean;
  workspace?: HomeTaskWorkspace;
  /** false = paused. */
  enabled: boolean;
  /** AppleReferenceSeconds. */
  createdAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  updatedAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  nextRunAt?: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  lastRunAt?: AppleReferenceSeconds;
  state: HomeTaskState;
  activeRunID?: UUIDString;
  runs: HomeTaskRun[];
  /** Task IDs whose due runs finish first. */
  runsAfter?: UUIDString[];
  /** Wait limit for `runsAfter` (default 30). */
  runsAfterTimeoutMinutes?: Int;
  /** The task's own Copilot model and effort; omitted runs on Home's model. */
  model?: string;
  effort?: string;
}

/** GET /api/v1/home/tasks (changed) and POST .../tasks/<id>/move. */
export interface HomeTasksSnapshot {
  tasks: HomeTask[];
  /** Store revision; shared with the artifacts list. */
  revision: string;
  /** Mac storage problem; when set, the server never answers `unchanged`. */
  error?: string;
  supportsReordering: true;
}

/** GET /api/v1/home/tasks?revision=<same>. */
export interface HomeTasksUnchanged {
  unchanged: true;
  revision: string;
}

export type HomeTasksResponse = HomeTasksSnapshot | HomeTasksUnchanged;

/** PATCH /api/v1/home/tasks/<id>: non-empty subset of these keys (body ≤16 KiB). Returns {@link HomeTask}. */
export interface HomeTaskUpdateRequest {
  title?: string;
  prompt?: string;
  /** false pauses, true resumes. */
  enabled?: boolean;
}

/** POST/PATCH /api/v1/home/tasks/<id>/records[/<recordID>] (body ≤64 KiB). Returns {@link HomeTask}. */
export interface HomeTaskRecordUpdateRequest {
  values: Record<string, string>;
}

// MARK: - Cantrip Home: artifacts

/** `CantripHomeArtifact`. */
export interface HomeArtifact {
  id: UUIDString;
  title: string;
  /** Path under Home's artifacts folder (use its extension for saved files). */
  relativePath: string;
  /** Usually a {@link HomeArtifactKind}; Home may supply another lowercase string. */
  kind: string;
  mimeType: string;
  /** Bytes (≤20 MiB). */
  size: Int;
  /** AppleReferenceSeconds (file modification time when saved). */
  createdAt: AppleReferenceSeconds;
}

/** GET /api/v1/home/artifacts (changed). */
export interface HomeArtifactsSnapshot {
  artifacts: HomeArtifact[];
  /** Same store revision as the tasks list. */
  revision: string;
}

export interface HomeArtifactsUnchanged {
  unchanged: true;
  revision: string;
}

export type HomeArtifactsResponse = HomeArtifactsSnapshot | HomeArtifactsUnchanged;

/** GET /api/v1/home/artifacts/<id>. */
export interface HomeArtifactDataResponse {
  artifact: {
    id: UUIDString;
    title: string;
    mimeType: string;
  };
  /** Base64 file bytes (≤20 MiB decoded). */
  data: Base64String;
}

/** GET /api/v1/home/artifacts/<id>/thumbnail (images and videos only; 404 otherwise). */
export interface HomeArtifactThumbnailResponse {
  /** Base64 JPEG, ≤600 px per side, ≤512 KiB. */
  data: Base64String;
  width: Int;
  height: Int;
  /** Videos only. */
  durationSeconds?: number;
}

// MARK: - Cantrip Home: background runs

/** A handoff inside a background run (`CantripHomeBackgroundSnapshot.Handoff`). */
export interface HomeBackgroundHandoff {
  id: UUIDString;
  tabID: UUIDString;
  tabTitle: string;
  summary: string;
  /** ≤600 chars. */
  prompt: string;
  status: DelegationStatus;
  /** UnixSeconds (unlike the run's own dates). */
  startedAt: UnixSeconds;
  /** UnixSeconds. */
  finishedAt?: UnixSeconds;
  latestStatus?: string;
  result?: string;
  error?: string;
}

/** `CantripHomeBackgroundSnapshot.Run`. */
export interface HomeBackgroundRun {
  id: UUIDString;
  kind: HomeRunKind;
  label: string;
  taskID?: UUIDString;
  /** AppleReferenceSeconds. */
  startedAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds. */
  finishedAt?: AppleReferenceSeconds;
  /** See {@link HomeRunStatus}; "running" is live. */
  status: string;
  summary: string;
  /** Live hidden run's session (only while stoppable and not routed to a tab). */
  sessionID?: UUIDString;
  incidentID?: UUIDString;
  route: HomeRunRoute;
  /** Duplicate triggers folded into this run. */
  repeats?: Int;
  handoffs: HomeBackgroundHandoff[];
  /** This run's live status, e.g. "Needs your input", "Waiting on a background task", "Working in <tab>". */
  activity?: string;
  canStop: boolean;
  /** Pending requests of a live hidden run (omitted when none). */
  inputs?: InputRequest[];
  /** The model a hidden run used (newer hosts). */
  model?: string;
}

/** A job waiting to start. */
export interface HomeBackgroundQueuedRun {
  id: UUIDString;
  kind: HomeRunKind;
  label: string;
  taskID?: UUIDString;
  /** Why it waits (e.g. for `runsAfter` or parallel limit). */
  reason?: string;
  /** AppleReferenceSeconds. */
  dueAt?: AppleReferenceSeconds;
  repeats?: Int;
}

/** GET /api/v1/home/background and POST /api/v1/home/background/<runID>/stop. */
export interface HomeBackgroundSnapshot {
  /** Home's background log session ID (openable via GET /sessions/<id>, never listed). */
  sessionID: UUIDString;
  runs: HomeBackgroundRun[];
  queued: HomeBackgroundQueuedRun[];
  /** Legacy: the one hidden run's activity when exactly one runs. */
  activity?: string;
  revision: string;
  /** Default 3. */
  maxParallel: Int;
  runningCount: Int;
  supportsStop: true;
}

// MARK: - Cantrip Home: OTA builds

/** One published iOS build on the Mac's install page. */
export interface OTABuild {
  /** "<bundle id>/<build folder>"; icon at GET /home/builds/<part0>/<part1>/icon. */
  id: string;
  bundleID: string;
  title: string;
  version: string;
  build: string;
  note?: string;
  hasIcon: boolean;
  size?: Int;
  sizeLabel?: string;
  profileName?: string;
  profileKind?: string;
  /** Free-form string from build metadata. */
  profileExpires?: string;
  /** AppleReferenceSeconds. */
  publishedAt: AppleReferenceSeconds;
  publishedLabel?: string;
  sourceCommit?: string;
  /** https manifest (tailnet-only). */
  manifestURL: string;
  /** itms-services:// link (iOS only). */
  installURL: string;
}

export interface OTAApp {
  /** Page key the builds share. */
  id: string;
  title: string;
  bundleID: string;
  /** Newest first. */
  builds: OTABuild[];
}

/** GET /api/v1/home/builds. */
export interface OTABuildsSnapshot {
  apps: OTAApp[];
  pageURL?: string;
  /** False when the Mac has no install page folder. */
  available: boolean;
  /** Unreadable build folders. */
  skipped: Int;
  revision: string;
}

/** GET /api/v1/home/builds/<bundle>/<folder>/icon (404 when none). */
export interface OTABuildIconResponse {
  /** Base64 PNG, ≤2 MiB. */
  data: Base64String;
  mimeType: 'image/png';
}

// MARK: - MCP Apps

/** Network origins declared by a view (plain scheme://host[:port] sources only). */
export interface MCPAppCSP {
  connectDomains: string[];
  resourceDomains: string[];
  frameDomains: string[];
  baseUriDomains: string[];
}

/** GET /api/v1/sessions/<id>/apps/<appID> (`MCPAppPayload`). */
export interface MCPAppPayload {
  /** Tool call ID. */
  id: string;
  serverName: string;
  toolName: string;
  title?: string;
  /** "ui://…". */
  resourceURI: string;
  /** View HTML (≤1 MiB). */
  html: string;
  csp: MCPAppCSP;
  /** Granted sandbox permissions; clients honor only "clipboardWrite". */
  permissions: string[];
  prefersBorder?: boolean;
  /** JSON object text of the tool call arguments. */
  toolInput: string;
  /** JSON object text of the MCP CallToolResult. */
  toolResult: string;
  /** JSON object text of the tool definition. */
  tool: string;
}

/** POST .../apps/<appID>/view → single-use (60 s) host-relative URL "/mcp-app/<48 hex>" serving sandboxed HTML. */
export interface MCPAppViewResponse {
  url: string;
}

/** POST .../apps/<appID>/request (body ≤256 KiB). Keys ⊆ {method, params}. */
export interface MCPAppServerRequest {
  method: MCPAppMethod;
  params?: Record<string, unknown>;
}

export interface MCPAppServerResponse {
  /** The MCP result object (502 {error} on failure). */
  result: Record<string, unknown>;
}

/** POST .../apps/<appID>/message: exactly {text} (≤16 KiB body). Sends a user prompt from the view. */
export interface MCPAppMessageRequest {
  text: string;
}

export interface MCPAppMessageResponse {
  accepted: true;
  /** The text actually submitted (normalized). */
  text: string;
}

/** POST .../apps/<appID>/context: exactly {text}; string (≤8000 chars kept) or null to clear. */
export interface MCPAppContextRequest {
  text: string | null;
}

// MARK: - Memory

export interface MemoryEntry {
  /** Relative path, e.g. "MEMORY.md", "USER.md", "notes/x.md", "sessions/2026-10-22.md". */
  id: string;
  category: MemoryCategory;
  bytes: Int;
  /** UnixSeconds (file mtime). */
  modifiedAt: UnixSeconds;
  /** MEMORY.md only. */
  characterLimit?: Int;
}

/** GET /api/v1/memory?q=&after= (50 per page). */
export interface MemoryCatalog {
  enabled: boolean;
  /** False when the memory folder doesn't exist. */
  exists: boolean;
  documents: MemoryEntry[];
  /** Pass as `after` for the next page (equals the last document's id). */
  nextCursor?: string;
}

/** GET /api/v1/memory/document?id=&offset=&revision= (16 KiB pages; `revision` required when offset > 0). */
export interface MemoryPage {
  document: MemoryEntry;
  text: string;
  offset: Int;
  nextOffset?: Int;
  /** File version; a mismatch on later pages → 409. */
  revision: string;
}

// MARK: - Maintenance

export interface MaintenanceRequest {
  /** Client-generated; reusing it is idempotent. */
  id: UUIDString;
  action: MaintenanceAction;
  /** The snapshot's current `revision`. */
  revision: UUIDString;
}

export interface MaintenanceJob {
  request: MaintenanceRequest;
  phase: MaintenancePhase;
  message: string;
  output: string;
  /** AppleReferenceSeconds. */
  startedAt: AppleReferenceSeconds;
  /** AppleReferenceSeconds; omitted while running. */
  finishedAt?: AppleReferenceSeconds;
}

/** GET (200) / POST (202) /api/v1/maintenance. */
export interface MaintenanceSnapshot {
  revision: UUIDString;
  available: boolean;
  unavailableReason?: string;
  runningBuild: string;
  /** Build staged for next launch. */
  installedBuild?: string;
  /** Tabs streaming, queued or running a shell command. */
  busySessions: Int;
  branch?: string;
  localChanges?: boolean;
  commitsBehind?: Int;
  /** AppleReferenceSeconds. */
  checkedAt?: AppleReferenceSeconds;
  job?: MaintenanceJob;
  /** Recently accepted request IDs (clear a pending request when its ID appears). */
  acceptedRequestIDs: UUIDString[];
}

// MARK: - Copilot usage

export interface CopilotQuotaBucket {
  /** "premium_interactions" | "chat" | "completions" | … */
  id: string;
  /** "credits" | "requests" | … */
  billingMode: string;
  isUnlimited: boolean;
  remainingPercent?: number;
  entitlement?: number;
  remaining?: number;
  overage?: number;
  overageAllowed?: boolean;
  /** ISO-8601. */
  resetAt?: ISO8601String;
  /** ISO-8601. */
  observedAt?: ISO8601String;
}

export interface CopilotAccountUsage {
  login?: string;
  plan?: string;
  buckets: CopilotQuotaBucket[];
}

/** GET /api/v1/copilot/usage. */
export interface CopilotUsageSnapshot {
  account?: CopilotAccountUsage;
  /** ISO-8601. */
  checkedAt?: ISO8601String;
  isRefreshing: boolean;
  error?: string;
}

// MARK: - GitHub builds

export interface GitHubBuildJob {
  /** "<owner/repo>/job/<id>" or "<owner/repo>/run/<id>". */
  id: string;
  workflow: string;
  title: string;
  number: Int;
  attempt: Int;
  branch: string;
  commit: string;
  /** GitHub status: "queued" | "in_progress" | "waiting" | … */
  status: string;
  job: string;
  step?: string;
  /** ISO-8601. */
  createdAt: ISO8601String;
  /** ISO-8601. */
  startedAt?: ISO8601String;
  url: string;
  assignment: BuildJobAssignment;
}

export interface GitHubBuildRepository {
  repository: string;
  app: string;
  runner: string;
  /** "online" | "offline" | "unknown". */
  runnerStatus: string;
  busy: boolean;
  /** ISO-8601. */
  checkedAt?: ISO8601String;
  jobs: GitHubBuildJob[];
  warning?: string;
}

/** GET /api/v1/github/builds (refreshes in the background at most every 60 s). */
export interface GitHubBuildSnapshot {
  repositories: GitHubBuildRepository[];
  isRefreshing: boolean;
  error?: string;
}

// MARK: - Live status (widget / Live Activity feed)

export interface LiveStatusTab {
  id: UUIDString;
  /** custom title else title, ≤48 chars. */
  title: string;
  state: LiveTabState;
  /** UnixSeconds; null when not running/input. Always present (explicit null). */
  startedAt: UnixSeconds | null;
  /** UnixSeconds; null unless done/failed/stopped. */
  finishedAt: UnixSeconds | null;
  /** ≤72 chars; null when none. */
  detail: string | null;
  queued: Int;
  /** Active subagents in the current run. */
  subagents: Int;
  /** Input tabs only: first request's kind. */
  inputKind?: InputRequestKind;
}

/** GET /api/v1/live-status. */
export interface LiveStatusSnapshot {
  version: 1;
  /** UnixSeconds. */
  generatedAt: UnixSeconds;
  hostName: string;
  running: Int;
  needsInput: Int;
  total: Int;
  /** At most 8: input first, then running (oldest start first), then finished (newest first). */
  tabs: LiveStatusTab[];
}

/**
 * POST /api/v1/live-status/subscription (APNs; iOS-specific). For each token key: absent = keep,
 * "" = clear, hex string = set.
 */
export interface LiveStatusSubscriptionUpdate {
  installationID: UUIDString;
  serverID: UUIDString;
  environment: 'development' | 'production';
  widgetToken?: string;
  startToken?: string;
  activityToken?: string;
  activityID?: string;
  liveActivities?: boolean;
}

/** DELETE /api/v1/live-status/subscription body; also DELETE /api/v1/notifications body. */
export interface PushRemovalRequest {
  installationID: UUIDString;
  serverID: UUIDString;
}

export interface LiveStatusSubscriptionStatus {
  configured: boolean;
  message: string;
  supportsWidgetPush: boolean;
  supportsLiveActivities: boolean;
}

// MARK: - Completion notifications (APNs)

/** POST /api/v1/notifications body (`RemotePushRegistration`). */
export interface PushRegistrationRequest {
  installationID: UUIDString;
  serverID: UUIDString;
  /** APNs device token, lowercase hex, 32–200 chars. */
  deviceToken: string;
  environment: 'development' | 'production';
  /** Also alert when a tab needs input. */
  inputNeeded?: boolean;
}

/** GET/POST/DELETE /api/v1/notifications response. */
export interface PushStatus {
  configured: boolean;
  message: string;
  lastDeliveryError?: string;
  supportsInputAlerts: boolean;
}

// MARK: - Mac access and View Mac (remote desktop)

export interface MacPermissionStatus {
  permission: MacPermission;
  title: string;
  state: MacPermissionState;
}

export interface MacAttentionIssue {
  id: UUIDString;
  permission: MacPermission;
  title: string;
}

/** GET /api/v1/mac-access. */
export interface MacAccessSnapshot {
  name: string;
  desktopEnabled: boolean;
  permissions: MacPermissionStatus[];
  issues: MacAttentionIssue[];
  /** UnixSeconds: active View Mac lease expiry. */
  activeUntil?: UnixSeconds;
}

/** POST /api/v1/mac-access: exactly {permission}; opens that System Settings pane on the Mac. */
export interface OpenMacSettingsRequest {
  permission: MacPermission;
}

export interface OpenMacSettingsResponse {
  opened: true;
}

export interface DesktopDisplay {
  /** CGDirectDisplayID (UInt32). */
  id: Int;
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

/** POST /api/v1/desktop/start: exactly {control}. */
export interface DesktopStartRequest {
  control: boolean;
}

/** Lease (5 minutes; ends after 60 s without a frame or input). */
export interface DesktopLease {
  id: UUIDString;
  /** Lease secret sent with every desktop call. */
  token: string;
  /** Base64 32-byte AES-256-GCM key for frames and input. */
  key: Base64String;
  /** UnixSeconds. */
  expiresAt: UnixSeconds;
  control: boolean;
  displays: DesktopDisplay[];
}

/** POST /api/v1/desktop/frame: exactly {id, token, displayID}. */
export interface DesktopFrameRequest {
  id: UUIDString;
  token: string;
  displayID: Int;
}

/**
 * Encrypted JPEG. `encryptedJPEG` = base64(nonce[12] ‖ ciphertext ‖ tag[16]) (CryptoKit "combined"),
 * AAD = UTF-8 "cantrip-desktop|<leaseID>|<frameID>|<displayID>|<width>|<height>" (UUIDs uppercase).
 */
export interface DesktopFrame {
  id: UUIDString;
  display: DesktopDisplay;
  width: Int;
  height: Int;
  encryptedJPEG: Base64String;
}

/**
 * Plaintext of a desktop input (JSON, then AES-GCM sealed). Coordinates are 0…1 of the frame.
 * text ≤4096 bytes; scroll delta −10…10 (≠0); text/key/scroll need a prior click on that display.
 */
export interface DesktopCommand {
  /** A frame received within the last 15 s. */
  frameID: UUIDString;
  kind: DesktopCommandKind;
  x?: number;
  y?: number;
  text?: string;
  key?: DesktopKey;
  delta?: Int;
}

/**
 * POST /api/v1/desktop/input: exactly {id, token, sequence, encrypted}. `sequence` strictly increases
 * per lease (starts at 1). `encrypted` = base64(combined AES-GCM of JSON {@link DesktopCommand}),
 * AAD = "cantrip-desktop|<leaseID>|input|<sequence>".
 */
export interface DesktopInputRequest {
  id: UUIDString;
  token: string;
  sequence: Int;
  encrypted: Base64String;
}

/** POST /api/v1/desktop/stop: exactly {id, token}. */
export interface DesktopStopRequest {
  id: UUIDString;
  token: string;
}

export interface DesktopStopResponse {
  stopped: true;
}

// MARK: - Pairing link

/**
 * `cantripagent://pair?v=1&token=…&url=…&direct=…&name=…&tailscaleOnly=0|1` (CantripPairing.swift).
 * token: 32–128 chars [A-Za-z0-9_-]; url: HTTPS origin (Tailscale Serve); direct: "host:port" of the
 * encrypted TLS-PSK LAN listener; tailscaleOnly=1 requires url.
 */
export interface PairingLink {
  v: 1;
  token: string;
  url?: string;
  direct?: string;
  name?: string;
  tailscaleOnly?: '0' | '1';
}
