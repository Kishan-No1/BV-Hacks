# Claude Code hook contract for notchAgent

Verified on 2026-11-15 against <https://code.claude.com/docs/en/hooks> (local Claude Code: 2.1.325).
Quotes below are copied from that page. The Swift mirror of this contract is
`Sources/NotchAgentCore/Contracts/HookPayload.swift`; the fixtures are `Tests/NotchAgentCoreTests/Fixtures/*.json`.

**Verdict on the spec's open question:** `PermissionRequest` exists and can return a decision.
notchAgent uses it as designed. The `PreToolUse` fallback is not needed (it is documented in section 6 for reference).

## 1. Events

The docs list 33 events. notchAgent installs these nine:

| Event | notchAgent uses it for | Blocks Claude Code? |
|---|---|---|
| `SessionStart` | create the session (`source`: `startup`, `resume`, `clear`, `compact`, `fork`) | no |
| `UserPromptSubmit` | task title (`prompt`), status = working, reset the step list | no (notchAgent prints nothing) |
| `PreToolUse` | current step and tool card | no (notchAgent prints nothing) |
| `PostToolUse` | completed step | no |
| `PostToolUseFailure` | completed step, marked failed | no |
| `PermissionRequest` | the approval. The only event whose response notchAgent prints | yes, held until decided |
| `Notification` | `permission_prompt` marks the session "needs you" | no |
| `Stop` | turn finished: status = done, "Done" toast | no (notchAgent prints nothing) |
| `SessionEnd` | remove the session | no |

Other events exist (`SubagentStart`, `SubagentStop`, `StopFailure`, `PermissionDenied`, `PreCompact`, ...). notchAgent does
not install them. `HookEventName.other(String)` keeps unknown names decodable.

## 2. Input (stdin JSON)

> "For command hooks, this JSON arrives via stdin. For HTTP hooks, it arrives as the POST request body."

Common fields on every event:

| Field | Notes |
|---|---|
| `session_id` | "Current session identifier" |
| `hook_event_name` | "Name of the event that fired" |
| `cwd` | "Current working directory when the hook is invoked" |
| `transcript_path` | path to the conversation JSONL |
| `permission_mode` | `"default"`, `"plan"`, `"acceptEdits"`, `"auto"`, `"dontAsk"`, or `"bypassPermissions"`. Not on every event |
| `prompt_id` | UUID of the user prompt being processed |
| `scratchpad_dir`, `effort` | present, unused by notchAgent |
| `agent_id`, `agent_type` | present when the hook fires inside a subagent |

Event-specific fields:

| Event | Fields |
|---|---|
| `SessionStart` | `source`, `model` (can be omitted), `session_title` (when set) |
| `UserPromptSubmit` | `prompt`, `session_title` (when set) |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms` (optional) |
| `PostToolUseFailure` | `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt` (optional), `duration_ms` (optional) |
| `PermissionRequest` | `tool_name`, `tool_input`, optional `permission_suggestions`. **No `tool_use_id`** |
| `Notification` | `message`, optional `title`, `notification_type` |
| `Stop` | `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` |
| `SessionEnd` | `reason`: `clear`, `resume`, `logout`, `prompt_input_exit`, `other` |

> "PermissionRequest hooks receive `tool_name` and `tool_input` fields like PreToolUse hooks, but without
> `tool_use_id`. For an MCP tool, they also receive the `mcp_server` object. An optional `permission_suggestions`
> array contains the permission updates Claude Code suggests for this request"

`tool_input` per tool (from the docs' PreToolUse tables):

| Tool | Fields |
|---|---|
| `Bash` | `command`, `description`?, `timeout`? (ms), `run_in_background`? |
| `Edit` | `file_path` (absolute), `old_string`, `new_string`, `replace_all`? |
| `Write` | `file_path` (absolute), `content` |
| `Read` | `file_path` (absolute), `offset`?, `limit`? |
| `Glob` | `pattern`, `path`? |
| `Grep` | `pattern`, `path`?, `glob`?, `output_mode`?, `-i`?, `multiline`? |
| `WebFetch` | `url`, `prompt` |
| `WebSearch` | `query`, `allowed_domains`?, `blocked_domains`? |
| `Agent` | `prompt`, `description`, `subagent_type`, `model`? |

> "For file tools (`Write`, `Edit`, `Read`), `tool_input.file_path` is always absolute."

MCP tools are named `mcp__<server>__<tool>`. `NotebookEdit` uses `notebook_path`. The docs do not list `MultiEdit` or
`LS` among current built-in tools; the risk engine still handles those names because older sessions send them.

Example from the docs (`PermissionRequest`):

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
  "cwd": "/Users/...",
  "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf node_modules", "description": "Remove node_modules directory" },
  "permission_suggestions": [
    { "type": "addRules", "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf node_modules" }],
      "behavior": "allow", "destination": "localSettings" }
  ]
}
```

`Notification` matcher values notchAgent cares about: `permission_prompt` ("Claude needs you to approve a tool use ... and
the prompt has waited about six seconds") and `idle_prompt` ("Claude finished responding about 60 seconds ago").

## 3. `PermissionRequest` decision output

Printed to stdout by the hook, exit code 0:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from notchAgent."}}}
```

| `decision` field | Docs |
|---|---|
| `behavior` | "`\"allow\"` grants the permission, `\"deny\"` denies it. Deny and ask rules are still evaluated, so a hook returning `\"allow\"` doesn't override a matching deny rule" |
| `updatedInput` | "For `\"allow\"` only: modifies the tool's input parameters before execution." notchAgent never sends it |
| `updatedPermissions` | "For `\"allow\"` only: array of permission update entries to apply". notchAgent never sends it; "always allow" is notchAgent's own `RulesStore` |
| `message` | "For `\"deny\"` only: tells Claude why the permission was denied" |
| `interrupt` | "For `\"deny\"` only: if `true`, stops Claude". notchAgent never sends it |

`HookOutput.permissionRequest(_:)` builds exactly these bytes; `ContractTests.swift` pins them.

When it fires:

> "PreToolUse hooks run before every tool call, whether or not it needs permission. PermissionRequest hooks run only
> when Claude Code is about to ask you for permission, or when it would otherwise auto-deny a call that can't prompt."

Two tools must pass through untouched, because they

> "need `updatedInput` paired with `\"allow\"`"

They are `AskUserQuestion` and `ExitPlanMode`. notchAgent returns no decision for them (`SessionStore.passThroughTools`).

## 4. No decision = normal prompt (the fail-open rule)

> "Exit code 0 with no output means the hook has no decision to report, so the tool call continues through the normal
> permission flow ... The hook can deny the call, but staying silent doesn't approve it."

| Situation | What `notch-agent-hook.sh` does | Result in Claude Code |
|---|---|---|
| notchAgent not running (connection refused) | curl fails in ~10 ms, prints nothing, exits 0 | normal prompt |
| notchAgent held the request until its 580 s timeout | server answers 204 with an empty body; hook prints nothing, exits 0 | normal prompt |
| Hook hits its own `timeout` (600 s) | "Claude Code cancels a `command`, `http`, or `mcp_tool` hook that reaches its `timeout`, discarding the hook's output, so on most events a timed-out hook renders no decision" | normal prompt |
| Hook exits 2 on `PermissionRequest` | "Exit code 2 isn't honored for this event and the permission flow proceeds unchanged" | normal prompt |
| Hook exits with another code or prints invalid JSON | "Non-blocking error ... The action goes ahead" (for this event: the permission flow goes ahead) | normal prompt, plus an error notice |

Rules that follow for the hook script:

- Always `exit 0`. Never exit 2 (on `PreToolUse`, `UserPromptSubmit` and `Stop`, exit 2 **blocks**).
- "Print nothing but the JSON object to stdout." Print only for `PermissionRequest`, only when the HTTP status is 200
  and the body is non-empty. Everything else prints nothing.
- Never set `onFailure: "block"`.
- The user may answer in the terminal while notchAgent holds the request. Claude Code then ends the hook process, curl
  drops the connection, and the server cancels the held request. `PostToolUse` for the same call also clears it.
  Checked live with Claude Code 2.1.325: the terminal prompt IS visible while notchAgent holds the request, and a
  `permission_prompt` notification fires about 6 s later. A terminal No/Esc ends the hook (notchAgent dropped the request
  about 40 ms later); a terminal Yes is cleared by the matching `PostToolUse`. The first answer wins.
- After a deny, Claude Code sends no `PostToolUse` or `PostToolUseFailure`; the store clears the tool card itself.

## 5. Settings shape

Three levels: event → matcher group → handlers.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          { "type": "command", "command": "'/abs/path/hooks/notch-agent-hook.sh' PermissionRequest", "timeout": 600 }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "'/abs/path/hooks/notch-agent-hook.sh' PreToolUse", "timeout": 5 }
        ]
      }
    ]
  }
}
```

- Matcher: "`\"*\"`, `\"\"`, or omitted" means match all. notchAgent omits it. For tool events it matches the tool name; for
  `Notification` the notification type; for `SessionStart` the source; for `SessionEnd` the reason.
- Handler `type`: "`\"command\"`, `\"http\"`, `\"mcp_tool\"`, `\"prompt\"`, or `\"agent\"`". notchAgent uses `command`.
- `timeout`: "Seconds before canceling." "Defaults: 600 for `command`, `http`, and `mcp_tool`; 30 for `prompt`; 60
  for `agent`." The default drops to 30 on `UserPromptSubmit`. No maximum is documented.
- `SessionEnd`: "SessionEnd hooks have a default timeout of 1.5 seconds." A per-hook `timeout` raises that budget, so
  notchAgent sets no `timeout` on `SessionEnd` and relies on curl's `--max-time 1`.
- `async: true` exists for command hooks ("runs in the background without blocking"). notchAgent does not use it: sync
  hooks keep event order, and with notchAgent down the curl call returns in about 10 ms.
- "Direct edits to hooks in settings files are normally picked up automatically by the file watcher." `/hooks` shows
  what is installed.
- Hook commands run with the session's environment; `CLAUDE_PROJECT_DIR` is set.

notchAgent's entries are recognised by the substring `notch-agent-hook.sh` in `command`. Install and uninstall touch only those.

Timeout chain for `PermissionRequest`: store 580 s < curl `--max-time 590` < hook `timeout` 600.

## 6. Fallback kept for reference: `PreToolUse`

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Destructive command blocked by hook"}}
```

`permissionDecision` is `allow`, `deny`, `ask` or `defer`. It runs before every tool call, including ones that would
never prompt, so it is the wrong event for approvals. `HookOutput.preToolUse(_:)` builds it; nothing installs it.

## 7. HTTP between the hook script and notchAgent

| Request | Response |
|---|---|
| `GET /health` | 200 `{"app":"notchAgent","ok":true}` |
| `POST /hook/<EventName>`, body = the stdin JSON | non-permission event: 200 `{"ok":true}` |
| `POST /hook/PermissionRequest` | decided: 200 + the section 3 JSON. Not decided: 204, empty body |
| undecodable body | 400 |

The server reads `hook_event_name` from the body and falls back to the path. That also makes the endpoint usable
from a native `"type": "http"` hook ("2xx with an empty body: success, equivalent to exit code 0 with no output").
notchAgent does not install http hooks, because with notchAgent down each event would log a non-blocking error.

Port: 47474, overridable with `NOTCH_AGENT_PORT` in both the app and the hook script.

## 8. Fixtures

All use session `7f3c2a10-5b1e-4c7a-9d54-0e2b6a1f9c33` and cwd `/Users/dev/code/acme-web`.

| File | Event |
|---|---|
| `session-start.json` | `SessionStart` (`startup`) |
| `user-prompt-submit.json` | `UserPromptSubmit` "add token refresh to auth" |
| `pre-tool-use-read.json`, `post-tool-use-read.json` | Read `src/auth/session.ts` |
| `pre-tool-use-bash.json`, `post-tool-use-bash.json` | Bash `npm test -- src/auth` |
| `post-tool-use-edit.json`, `post-tool-use-grep.json` | Edit `session.ts`; Grep "SessionError" |
| `post-tool-use-failure-bash.json` | `PostToolUseFailure`, exit code 1 |
| `permission-request-bash-npm-test.json` | low risk |
| `permission-request-edit.json` | review, with `old_string` / `new_string` |
| `permission-request-bash-rm-rf-outside.json` | high risk: `rm -rf ../design-assets/export/*` |
| `permission-request-write-env.json` | high risk: Write `.env.local` |
| `permission-request-webfetch.json` | review: fetch docs.example.com |
| `permission-request-ask-user-question.json` | pass-through tool |
| `notification-permission-prompt.json`, `notification-idle-prompt.json` | `Notification` |
| `stop.json`, `session-end.json` | `Stop`, `SessionEnd` |

The payloads follow the documented schemas. They were written by hand, not captured from a live session; the
`tool_response` shapes in particular are illustrative and nothing in notchAgent depends on them.
