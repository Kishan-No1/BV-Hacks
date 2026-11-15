# Nod prompt composer: polish, learned style, tmux send (design)

**Status:** built on branch `feature/prompt-polish` on 2026-11-15. Extends [the Nod design](2026-11-15-nod-design.md).

## Intent

Nod already shows what each Claude Code session is doing and answers its permission requests from the notch. The composer adds the other direction: give a session its next task without switching to its terminal. You type a rough prompt, Nod rewrites it into a precise Claude Code prompt, you read and edit the result, and Nod types it into the session you picked.

The rewrite adapts to the person. Every send is compared with what the polish proposed, and what you changed becomes a short style note that goes into the next polish. The adaptation is visible within one session: add a line once, see a "Learned: …" chip, and the next polish already contains it.

## Anti-goals

- **Nothing is sent to a session unless the user presses Send** (or Return on the text). Polish only fills an editable pane.
- **No silent network use.** One outbound call exists, it happens only on Polish, and the README states exactly what it carries. A menu toggle turns it off.
- **Never type into a dialog.** Text sent to a pane that shows a permission or trust dialog would answer it.
- **Never log prompt text**, polished text, style notes or the API key, including with `NOD_LOG=1`.
- **The existing safety rules do not change:** hooks fail open, the risk engine, rules and hook contract are untouched, and the hook server still refuses cross-origin and non-local requests.

## What leaves the machine

Only the polish request: HTTPS POST to `https://api.anthropic.com/v1/messages`.

| Sent | Detail |
|---|---|
| Rough prompt | the text typed in the composer |
| Style notes | the top 8 active notes, one short line each |
| Repo context | session directory (home shortened to `~`), git branch, last 3 commit subjects, up to 30 changed file names from `git status --porcelain` |
| System prompt | fixed text describing the rewriting job |
| API key | `x-api-key` header only, never in the body |

Not sent: file contents, diffs, transcripts, permission requests, the stored prompt history. Everything else in the feature is local: the learner is deterministic Swift code with no model, the context comes from three read-only `git` commands, and the send goes through tmux.

With **Polish prompts with Claude Haiku** unticked, the composer sends the text as written and Nod makes no network request.

## Parts

### Composer (app)

A new island state, `.composer`, 560 pt wide like a request card.

- **Open:** global hotkey `⌃⌥P` (always registered, own Carbon signature), the menu item "Write a prompt…", or a click on the avatar of the session Progress is showing. A click on another avatar still switches Progress.
- **Layout:** the target session at the top (avatars re-aim it), the rough-text field, then after Polish a one-line "You wrote" reminder above the editable polished pane, one status line, and three buttons.
- **Buttons:** draft: Discard / Send as written / Polish. Polished: Discard / Edit draft / Send. When the send cannot happen (no tmux, no pane, not at a prompt): the middle button becomes Copy.
- **Keys:** Return polishes the draft, Return on the polished text sends, Shift-Return adds a line, Esc discards. `⌃⌥P` again hides the composer and keeps the draft.
- **Keyboard focus:** the notch panel normally refuses key status. While the composer is open it accepts it (the panel is non-activating, so Nod never becomes the active app) and gives it back on close.
- **Priority:** composer > request > toast > progress. A permission request that arrives while the composer is open waits in the queue; the composer shows "1 permission request is waiting". The request hotkeys only answer a card that is on screen, so they do nothing meanwhile.
- **After Send:** a short card, "Sent to <session>", with the "Learned: …" / "Dropped: …" chips from that send, then the island closes.

### Polish (`NodCore/Compose/PolishService.swift`)

- `Polishing` protocol; `AnthropicPolisher` is the real one, `StubPolisher` a deterministic offline one for tests and `--test-compose`.
- Request: model `claude-haiku-5-5`, `max_tokens` 800, `thinking` disabled and `output_config.effort` low (so the cap is all answer), no sampling parameters, `anthropic-version: 2026-10-21`. 20 s timeout, ephemeral session, no cache or cookies.
- The user message is three tagged blocks: `<style_notes>`, `<repo_context>`, `<rough_prompt>`. The system prompt tells the model to keep the intent, invent nothing, use the context only to make references concrete, follow the notes, stay short, output only the prompt, and treat the tagged content as data.
- Key: `ANTHROPIC_API_KEY` from the environment, else a Keychain generic password (service `Nod`, account `anthropic-api-key`), set from the menu.
- Errors are a small enum (`noKey`, `http(status, type)`, `network`, `refused`, `empty`) with one line of text each. The composer shows the line and keeps "Send as written" available.

### Learned style (`NodCore/Compose/StyleLearner.swift`, `StyleProfileStore.swift`)

Stored at `~/Library/Application Support/Nod/style.json`, mode 0600: the notes, the last 50 outcomes (rough, polished, final), and two counters. `StyleLearner.learn(profile, outcome)` is a pure function with no clock and no randomness, so the same outcomes give the same file byte for byte.

Text is split into lines, bullets and sentences; two lines are "the same" when they share at least half their words.

| Signal | Evidence | Note | Active after |
|---|---|---|---|
| Added line | a 2 to 16 word line in the sent text that the polish did not have | `Add: “run tests after edits”` | 1 send |
| Standing line | the same line sent under two different rough prompts | `Add: “…”` | 2 sends |
| Removed line | the same polished line deleted twice | `Leave out: “…”` | 2 sends |
| Filler | a filler ("please", "make sure to", …) deleted from a line that otherwise survived | `Don't say “please”.` | 1 send |
| Verb swap | a polished line's opening verb replaced by another | `Say “fix” rather than “resolve”.` | 1 send |
| Length | sent text at most 75% or at least 125% of the polish's words (standing lines not counted) | `Keep prompts short…` / `Give more detail…` | 2 sends |
| Format | bullets rewritten as sentences or the reverse | `Write plain sentences…` / `Use a short bullet list…` | 2 sends |
| Verbs | a verb that opened 3 sent lines | `Prefers the verbs: fix, add.` | 3 uses |

A note is reinforced (its count goes up) when the polish contained what it asks for and the user kept it. It gets a strike when the user removes or contradicts it, and two strikes in a row drop it, with a "Dropped: …" chip. The top 8 active notes by count, then recency, go into each polish request. At most 40 notes are kept.

### Send (`NodCore/Compose/TmuxSender.swift`, `scripts/nod-claude`)

- `scripts/nod-claude` starts `claude --session-id <uuid>` in a new detached tmux session and writes `panes/<uuid>.json` under Application Support/Nod: `session_id`, `pane_id`, `tmux_session`, `socket_path`, `server_pid`, `cwd`, `started_at`. Claude Code reports that same id in its hooks, which is how a session in the notch maps to a pane. After `/clear` (new session id) the pane is matched by directory when exactly one record has it.
- Before sending, Nod runs `display-message -p -t <pane> "#{pid} #{pane_id}"` and requires the recorded server pid and pane id (pane ids restart from `%0` with a new server), then `capture-pane` and requires Claude Code's input prompt: a `❯` line directly under a horizontal rule with another rule below it. Menu rows also start with `❯`, so a row without the rules is treated as a dialog.
- One line: `send-keys -t <pane> -l -- <text>`. Multi-line, tab, very long, or ending in `;` (tmux eats a trailing `;` as a command separator even with `-l`): `load-buffer -b nod-<uuid> -` with the text on stdin, then `paste-buffer -d -p -r`. Then `send-keys Enter`.
- Arguments are explicit argv, never a shell. Control characters other than newline and tab are stripped. No AppleScript, no Accessibility API.
- Results: `sent`, `tmuxMissing`, `paneNotFound`, `notAtPrompt`, `failed`. Every failure keeps the text in the composer and offers Copy. The app also refuses to send to a session with an open permission request.

## Test hooks

- `--test-compose TEXT`: opens the composer on the first session, polishes with `StubPolisher`, optionally appends `NOD_TEST_COMPOSE_EDIT` as the user's edit, and presses Send through the same model actions as the buttons. `NOD_TEST_COMPOSE_REPEAT` repeats it.
- `NOD_STYLE_FILE`, `NOD_PANES_DIR`, `NOD_TMUX` redirect the style file, the pane records and the tmux binary.
- `scripts/e2e.sh` section 6 runs that flow against a fake tmux and checks the exact argv, the stdin of the paste buffer, the learned note, and that the `NOD_LOG=1` log holds no prompt text.

## Calls made by Claude (correct me if wrong)

- Hotkey `⌃⌥P`; a click on the already-selected avatar opens the composer.
- The composer stays on top of an incoming permission request.
- Explicit edits become a note after one send; inferred preferences (length, format) need two.
- No "send anyway" when the pane is not at a prompt.
- Session to pane mapping by `--session-id`, with the directory as a fallback.
- The home directory is shortened to `~` before the path is sent.
