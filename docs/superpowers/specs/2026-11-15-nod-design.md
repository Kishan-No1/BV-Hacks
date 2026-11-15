# Nod: approve your coding agents from the notch (design)

**Status:** the user approved the visual direction (prototype v3) and said to start building on 2026-11-15. The deadline is end of day the same day.
**Visual source of truth:** [`docs/design/prototype.html`](../../design/prototype.html), open it in Chrome. Screenshots: `docs/design/v3-low-risk.png` and `docs/design/v3-high-risk.png`.

## Intent

The user runs several Claude Code sessions in parallel (separate worktrees). Each session stops to ask permission ("run `npm test`?", "edit session.ts?"), which forces a window switch into that session every time. Nod moves both progress and approvals into the MacBook notch. You see what every agent is doing at a glance and answer requests with one keystroke without leaving your current app. Each request also tells you, in plain English, how risky it is.

Success for the hackathon: a reliable live demo with real Claude Code sessions, plus a 60–90 second demo video, both delivered today.

## Goals

1. **Live progress in the notch.** Collapsed, it shows the Claude Code mascot on the left and an animated wave on the right while any session works. Hovering expands it to **Progress**: session avatars, **Claude ● <last prompt>**, a checklist of completed steps, the current step, and a tool card with a live seconds counter.
2. **Approve or deny from the notch.** Claude Code permission requests appear in the notch. Clicking or a global hotkey answers them, and the decision goes back to Claude Code.
3. **A risk read-out on every request.** A plain-English title, a risk level (low/green, review/amber, high/red), reason chips, and a diff preview for edits.
4. **Multiple sessions.** One avatar per session with a status dot (working = orange, needs you = amber, done = green). Pending requests across sessions form a FIFO queue.
5. **Safety affordances.** For high risk, the island glows red, Deny is the default, and allowing takes a 0.9-second press-and-hold. "Always allow `<cmd>` here" creates a per-repo rule, and later matches pass through automatically and get counted.
6. **Demo mode.** A scripted "story" drives the real UI through the real event path without Claude Code, for the video and as a live-demo backup.

## Non-goals

- Codex, Cursor, or agents other than Claude Code.
- Settings UI beyond a minimal menu-bar menu (install hooks, demo, quit).
- App Store sandboxing, notarization, auto-update.
- Windows or Linux. External displays without a notch get a simulated notch, but that isn't a focus.

## Anti-goals (a failure even if it technically works)

- **Never auto-allow anything except an explicit user rule.** The risk engine only advises.
- **Never block Claude Code when Nod is down or slow.** If Nod isn't running, the hook must exit quickly with no output so Claude Code shows its normal prompt. Fail open to the *normal prompt*, never to "allow".
- **Never steal ⌥↵ or ⌥⌫ when no request is pending.** Register the hotkeys only while one is.
- **Never modify the user's real `~/.claude/settings.json` during development.** Installing hooks is an explicit user action (a script or menu item), and it backs up the file first.

## Constraints

- macOS 26+ on Apple silicon, built on macOS 27 with Xcode 27.2 and Swift 6.4. Using macOS 26 lets us use SwiftUI's native Liquid Glass (`.glassEffect`).
- One day, so prefer boring, debuggable pieces.

## Approaches considered (for the bridge between Claude Code and the app)

| Approach | Trade-off | Verdict |
|---|---|---|
| **A. Claude Code command hooks → `curl` → local HTTP server in Nod** | Uses the standard documented hooks. The hook is a tiny shell script with no compiled helper. Nod holds the HTTP response open for permission requests until the user decides. | **Chosen** |
| B. Parse session transcripts (`~/.claude/projects/*.jsonl`) for progress, plus hooks only for approvals | No hook needed for progress, but transcript formats are undocumented and change. Two mechanisms. | Rejected |
| C. Compiled `nod-hook` CLI talking over a Unix socket | Slightly faster, but a second binary to build, sign and install. | Rejected; possible later |

## Architecture

```
Claude Code session ──hook (stdin JSON)──▶ hooks/nod-hook.sh ──curl POST──▶ Nod.app  (127.0.0.1:47474)
        ▲                                                                  │
        └──── stdout decision JSON ◀── held response (permission only) ◀───┘ user clicks / ⌥↵
```

### 1. Hook bridge: `hooks/nod-hook.sh`
- Reads hook JSON from stdin and POSTs it to `http://127.0.0.1:47474/hook/<EventName>`. It passes `--connect-timeout 0.3`. The max time is short for non-blocking events and up to about 590s for `PermissionRequest`.
- For `PermissionRequest`, it prints whatever Nod returns (the decision JSON) to stdout. For everything else it prints nothing. It always exits 0, and if curl fails it prints nothing, so Claude Code falls back to its normal behavior.
- Events used: `SessionStart`, `UserPromptSubmit` (the task title), `PreToolUse` (the current step), `PostToolUse` (completed step), `PermissionRequest` (approval), `Notification`, `Stop` (turn finished), `SessionEnd`. **The builder must verify the exact event names, input fields and `PermissionRequest` decision output format against the current Claude Code hooks docs** (https://code.claude.com/docs/en/hooks). If `PermissionRequest` can't return a decision, fall back to `PreToolUse` returning `permissionDecision: allow|deny|ask`.
- `scripts/install-hooks.sh` / `scripts/uninstall-hooks.sh` merge or remove Nod's entries in `~/.claude/settings.json` using `jq`. They write a timestamped backup first, are idempotent, and set `"timeout": 600` on the permission hook. Both accept `--settings <path>` so tests target a temp file.

### 2. `NodCore` (Swift library, unit-tested, no UI)
- **Hook models:** decode Claude Code hook payloads (`session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `prompt`, and so on). Tolerate unknown fields.
- **`RiskEngine`:** pure function from (tool name, tool input, cwd) to `Assessment { level: low|review|high, title: String, reasons: [String], diff: DiffPreview? }`.
  - Read-only tools (Read, Grep, Glob, LS, WebSearch) → low.
  - Bash: read-only or test/build commands (`ls`, `cat`, `git status/diff/log`, `npm test`, `pytest`, `swift build/test`) → low. Installs and network fetches (`npm install`, `pip install`, `brew`, `curl` without a pipe) → review. Destructive commands (`rm -r`/`-rf`, `git push --force`, `git reset --hard`, `git clean -f`, `sudo`, `chmod -R`, `curl … | sh`, `dd`, `mkfs`, writing to `~/.ssh` or `.env`) → high. Any path that resolves outside `cwd` raises the level one step, up to high.
  - Edit, Write, MultiEdit, NotebookEdit: inside the repo → review, with a diff preview from `old_string`/`new_string` or the content. Outside the repo, or sensitive files (`.env*`, `~/.ssh`, `~/.claude/settings*`, keychains) → high.
  - Titles come from templates and are plain English: "Run `npm test`", "Edit session.ts", "Delete files outside this repo", "Fetch docs.example.com". Reasons are short chips: "Outside the project", "Not in git · can't undo", "Read-only".
- **`SessionStore`** (observable, main-actor): sessions keyed by `session_id` with name (cwd folder and git branch), last prompt, steps (done and current), current tool and start time, and status (`working|needsYou|done|idle`). It also holds the pending request queue and an auto-allowed counter. Step text comes from `PostToolUse`, for example "Read src/auth/session.ts", "Ran `npm test`", "Edited session.ts", "Searched “X”".
- **`RulesStore`:** per-repo "always allow" rules (an exact Bash command prefix, or a tool name), stored as JSON in `~/Library/Application Support/Nod/rules.json`.
- **`HookServer`:** a localhost-only `NWListener` HTTP server on port 47474. Non-permission events return 200 immediately. `PermissionRequest` checks the rules first and auto-answers allow on a match. Otherwise it enqueues the request and holds the connection until the user decides, Claude Code disconnects, or the timeout hits; a timeout returns *no decision*, so Claude Code falls back to its own prompt.

### 3. `Nod` app (SwiftUI + AppKit, `LSUIElement` menu-bar agent)
- **Notch window:** a borderless, non-activating `NSPanel` at about `.mainMenu + 3` level, on all spaces including full-screen, with a transparent background. It is pinned to the top center of the built-in display, using `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` for the notch size, and falls back to a 185×32 simulated notch. Mouse clicks pass through everywhere except the island's current shape.
- **Island states** match the prototype one-to-one: `idle`, `working` (compact 272×32: mascot plus wave), `attention`, `progress` (about 600×256), `request` (low, review or high, about 560 wide and fit to content), and the `done`, `allowed` and `denied` toasts.
- **Motion:** open with `.spring(response: 0.5, dampingFraction: 0.8)` and close with `.spring(response: 0.38, dampingFraction: 1.0)`. Content blurs and scales in from 0.94 and is laid out at its final width, so nothing reflows. The step list fades under the bottom edge.
- **Materials:** solid black where the island meets the notch, and native Liquid Glass (`.glassEffect`) at the bottom edge. Buttons are glass capsules, with Allow in white and Deny in red. The risk glow is a soft colored shadow only, with no outline.
- **Input:** hover opens Progress after 120ms and closes it after 220ms. While a request is pending, Carbon `RegisterEventHotKey` binds ⌥↵ (the default: allow for low/review, deny for high) and ⌥⌫ (deny). Clicking an avatar switches the Progress view to that session.
- **Menu-bar item:** Install Claude Code hooks…, Play demo, Quit.
- **Demo mode** (`Nod --demo` or the menu): replays the prototype's story by POSTing scripted payloads to its own server. Use realistic payloads that match the real hook schema.

### 4. Demo video: `video/` (Remotion)
- 1920×1080 at 30fps, 60–90s. Port the prototype's island to React components for pixel-identical, deterministic rendering.
- Beats:
  1. Problem: four agents, constant window switching to approve.
  2. Nod appears.
  3. Glanceable progress.
  4. Approve with ⌥↵ without leaving the editor.
  5. The risk read-out, ending on high risk with hold-to-allow.
  6. Many agents at once.
  7. Close: "Nod. Approve your agents from the notch."
- On-screen captions, and a voiceover script in `video/script.md`. Use a placeholder `say` voiceover for timing; the final voiceover gets swapped in later.

## Repo layout

```
Package.swift              # NodCore (library), Nod (executable), NodCoreTests
Sources/NodCore/...        # models, RiskEngine, SessionStore, RulesStore, HookServer
Sources/Nod/...            # app, notch window, island views, hotkeys, demo
Tests/NodCoreTests/...
hooks/nod-hook.sh
scripts/{bundle.sh,install-hooks.sh,uninstall-hooks.sh,simulate.sh}
video/                     # Remotion project
docs/                      # ideas, design, plans, pitch
```
`scripts/bundle.sh` builds in release and wraps the binary into `build/Nod.app` (an `Info.plist` with `LSUIElement`, ad-hoc codesign). `scripts/simulate.sh` POSTs recorded or sample payloads with curl, for end-to-end tests without Claude Code.

## Calls made by Claude (correct me if wrong)

- The name **Nod**, port 47474, and macOS 26 as the minimum.
- SwiftPM plus a bundle script, not an Xcode project, because it's easier for parallel agents to build and test.
- Risk rules are heuristics from templates. Using an LLM for titles was rejected because of latency and an extra dependency.
- The nod-to-approve camera gesture is a stretch goal only.

## Left to the builder

Exact SwiftUI view structure, file split inside each module, the hook payload fixtures, and the details of the HTTP parsing.
