# Idea generation: a MacBook notch app

**Brief:** build a macOS app that uses the notch for something new and useful. One-day hackathon (BV Hacks, due end of day 2026-11-15). We need a working product and a demo video.

## 1. What's already taken (landscape check, 2026-11-15)

The obvious notch ideas are crowded. Judges will likely have seen these:

| Niche | Existing apps |
|---|---|
| Media controls, file shelf, calendar, timers | NotchNook, Boring Notch, Alcove, Notchable, Notchly |
| AI coding-agent status | Notch Agents, AgentValley, Notchy, Notchcode, Chimlo, Vibe Notch |
| Approve/deny agent permissions | Coucou, ClaudePeek |
| Teleprompter beside the camera | Notchie, CueNotch, NotchPrompter, Snotch |
| Live captions and translation | NotchLive, Celyn |

Sources: [notchly roundup](https://notchly.vercel.app/blog/best-macbook-notch-apps), [vibeisland agent notch apps](https://vibeisland.app/best-ai-agent-notch-apps/), [dev.to: notch as agent control center](https://dev.to/krisying/i-turned-my-macbooks-notch-into-a-control-center-for-ai-coding-agents-2o57), [heise: notch teleprompters](https://heise.de/-11225629), [NotchLive](https://www.capterra.com/p/10050552/NotchLive/).

## 2. Shortlist we considered

Most of these ideas use the fact that the notch is where the camera lives.

1. **Shoulder-surfing guard.** The camera spots a second face behind you, so the notch flashes and the screen blurs. *For:* very reliable to build, instant demo. *Against:* the camera light stays on.
2. **Speaking coach at eye level.** Shows pace, filler words and talk time while you present. *Against:* Apple's speech recognition drops "um"/"uh", so filler counts would be shaky.
3. **Live updates for anything.** A local endpoint and CLI push progress cards into the notch. *Against:* weaker demo, and it overlaps the agent apps.
4. **Approve your coding agents from the notch.** The team's own pain: running several Claude Code sessions in parallel means constantly switching windows to answer permission prompts.

## 3. Decision: #4, with an angle the existing apps don't have

Approving agent requests from the notch exists already, so we compete on **judgment, not relocation**:

- **Plain-English risk before you approve.** Every request is read out in a sentence ("Delete 14 files outside this repo") with a risk level: green (read-only, inside the repo), amber (code edits, which git can undo), red (irreversible or outside the project).
- **Calm by default.** Requests you've ruled safe pass through on their own. Red requests make Deny the default and need a press-and-hold to allow.
- **Many agents at once.** One avatar per running session. Approvals form a queue, and **⌥↵** answers the top one from any app.

Working name: **Nod**. You approve with a nod.

Stretch idea, if time allows: nod or shake your head at the camera to approve or deny.

## 4. Design iterations

The clickable prototype lives in [`design/prototype.html`](design/prototype.html), at version 3.

- **v1:** generic black island, states laid out as tabs.
- **v2:** restyled to match a user reference: a "Progress" header, session avatars, a **Claude ● task** title row, a step checklist, and a live tool card. The Claude Code mascot appears when collapsed, next to an audio-wave activity indicator.
- **v3:** true-scale sizing (about 600×256pt on a 14" display), a liquid-glass bottom edge, the risk glow reduced to a soft fade with no outline, and liquid-glass buttons.
