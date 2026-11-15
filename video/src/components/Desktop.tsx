import React from "react";

/* ------------------------------------------------------------------ */
/* Menu bar, Finder-ish sidebar and the editor window (prototype port) */
/* ------------------------------------------------------------------ */

export const MenuBar: React.FC<{ app?: string; clock?: string }> = ({
  app = "Code",
  clock = "2:41 PM",
}) => (
  <div className="menubar">
    <div className="l">
      <b></b>
      <b>{app}</b>
      {(app === "Terminal"
        ? ["Shell", "Edit", "View", "Window", "Help"]
        : ["File", "Edit", "Selection", "View", "Go", "Run", "Terminal"]
      ).map((m) => (
        <span key={m} className="dim">
          {m}
        </span>
      ))}
    </div>
    <div className="r">
      <span className="dim">100%</span>
      <span className="dim">Sat Nov 15</span>
      <span className="dim">{clock}</span>
    </div>
  </div>
);

export const Sidebar: React.FC<{ opacity?: number }> = ({ opacity = 1 }) => (
  <div className="side" style={opacity < 1 ? { opacity } : undefined}>
    <b>BV-Hacks</b>
    <br />▸ src
    <br />
    &nbsp;&nbsp;▾ auth
    <br />
    &nbsp;&nbsp;&nbsp;&nbsp;session.ts
    <br />
    &nbsp;&nbsp;&nbsp;&nbsp;refresh.ts
    <br />
    &nbsp;&nbsp;▸ app
    <br />▸ tests
    <br />
    package.json
  </div>
);

const TYPED = "export const SESSION_TTL = 15 * 60; // seconds";

/** Syntax-colours the line the user types while the agents work. */
const typedSpans = (n: number) => {
  const s = TYPED.slice(0, n);
  const parts: React.ReactNode[] = [];
  const kw = ["export const"];
  let i = 0;
  if (s.length) {
    const k = kw[0];
    const kwPart = s.slice(0, Math.min(s.length, k.length));
    parts.push(
      <span key="k" className="kw">
        {kwPart}
      </span>,
    );
    i = kwPart.length;
  }
  const rest = s.slice(i);
  const cIdx = rest.indexOf("//");
  const code = cIdx >= 0 ? rest.slice(0, cIdx) : rest;
  const comment = cIdx >= 0 ? rest.slice(cIdx) : "";
  // numbers in orange
  code.split(/(\d[\d_]*)/).forEach((p, j) => {
    parts.push(
      /^\d/.test(p) ? (
        <span key={`n${j}`} className="n">
          {p}
        </span>
      ) : (
        <React.Fragment key={`t${j}`}>{p}</React.Fragment>
      ),
    );
  });
  if (comment)
    parts.push(
      <span key="c" className="c">
        {comment}
      </span>,
    );
  return parts;
};

export const TYPED_LEN = TYPED.length;

/**
 * The prototype's session.ts, as tokens so formatting tools can't touch the
 * indentation. [class, text]; class "" is plain text.
 */
type Tok = [string, string];
const CODE: Tok[][] = [
  [["c", "// you stay in your editor. the agents work in the background."]],
  [
    ["kw", "import"],
    ["", " { SessionError } "],
    ["kw", "from"],
    ["", " "],
    ["s", "'./errors'"],
    ["", ";"],
  ],
  [],
  [
    ["kw", "export async function"],
    ["", " "],
    ["f", "refreshSession"],
    ["", "(token: "],
    ["kw", "string"],
    ["", ") {"],
  ],
  [
    ["", "  "],
    ["kw", "const"],
    ["", " res = "],
    ["kw", "await"],
    ["", " fetch("],
    ["s", "'/api/session'"],
    ["", ", {"],
  ],
  [
    ["", "    method: "],
    ["s", "'POST'"],
    ["", ","],
  ],
  [
    ["", "    headers: { Authorization: "],
    ["s", "`Bearer ${token}`"],
    ["", " },"],
  ],
  [["", "  });"]],
  [
    ["", "  "],
    ["kw", "if"],
    ["", " (!res.ok) "],
    ["kw", "throw new"],
    ["", " "],
    ["f", "SessionError"],
    ["", "(res.status);"],
  ],
  [
    ["", "  "],
    ["kw", "return"],
    ["", " res.json();"],
  ],
  [["", "}"]],
  [],
  [
    ["kw", "export function"],
    ["", " "],
    ["f", "isExpired"],
    ["", "(exp: "],
    ["kw", "number"],
    ["", ") {"],
  ],
  [
    ["", "  "],
    ["kw", "return"],
    ["", " Date.now() > exp * "],
    ["n", "1000"],
    ["", " - "],
    ["n", "30_000"],
    ["", ";"],
  ],
  [["", "}"]],
];

export const EditorWindow: React.FC<{
  typed?: number;
  caretOn?: boolean;
  opacity?: number;
}> = ({ typed = 0, caretOn = false, opacity = 1 }) => (
  <div className="win" style={opacity < 1 ? { opacity } : undefined}>
    <div className="bar">
      <i style={{ background: "#ff5f57" }} />
      <i style={{ background: "#febc2e" }} />
      <i style={{ background: "#28c840" }} />
      <span className="t">session.ts — BV-Hacks</span>
    </div>
    <pre>
      {CODE.map((line, i) => (
        <React.Fragment key={i}>
          {i > 0 ? "\n" : null}
          {line.map(([cls, text], j) =>
            cls ? (
              <span key={j} className={cls}>
                {text}
              </span>
            ) : (
              <React.Fragment key={j}>{text}</React.Fragment>
            ),
          )}
        </React.Fragment>
      ))}
      {typed > 0 || caretOn ? (
        <>
          {"\n"}
          {"\n"}
          {typedSpans(typed)}
          <span
            style={{
              display: "inline-block",
              width: 2,
              height: 20,
              marginLeft: 1,
              verticalAlign: -4,
              background: caretOn ? "#82aaff" : "transparent",
            }}
          />
        </>
      ) : null}
    </pre>
  </div>
);

/* ------------------------------------------------------------------ */
/* Four Claude Code terminals (the "before" picture)                   */
/* ------------------------------------------------------------------ */

export type Perm = { head: string; cmd: string; opt2: string };
export type TermSpec = {
  title: string;
  prompt: string;
  tool: [string, string];
  perms: Perm[];
};

export const TERMS: TermSpec[] = [
  {
    title: "token-refresh — claude",
    prompt: "add token refresh to auth",
    tool: ["Read(src/auth/session.ts)", "Read 84 lines"],
    perms: [
      {
        head: "Bash command",
        cmd: "npm test -- src/auth",
        opt2: "Yes, and don't ask again for npm test",
      },
      {
        head: "Edit file",
        cmd: "src/auth/session.ts",
        opt2: "Yes, allow all edits this session",
      },
    ],
  },
  {
    title: "hero-copy — claude",
    prompt: "rewrite the hero copy for launch",
    tool: ["Read(app/page.tsx)", "Read 212 lines"],
    perms: [
      {
        head: "Edit file",
        cmd: "app/page.tsx",
        opt2: "Yes, allow all edits this session",
      },
      {
        head: "Bash command",
        cmd: "npm run build",
        opt2: "Yes, and don't ask again for npm run",
      },
    ],
  },
  {
    title: "ci-cache — claude",
    prompt: "fix the flaky CI cache",
    tool: ["Read(.github/workflows/ci.yml)", "Read 58 lines"],
    perms: [
      {
        head: "Bash command",
        cmd: "gh run list --limit 5",
        opt2: "Yes, and don't ask again for gh run",
      },
      {
        head: "Bash command",
        cmd: "npm ci",
        opt2: "Yes, and don't ask again for npm ci",
      },
    ],
  },
  {
    title: "api-docs — claude",
    prompt: "write the API docs",
    tool: ['Search(pattern: "router\\.")', "Found 14 files"],
    perms: [
      {
        head: "Fetch",
        cmd: "https://docs.example.com/api",
        opt2: "Yes, and don't ask again for this domain",
      },
      {
        head: "Write file",
        cmd: "docs/api.md",
        opt2: "Yes, allow all edits this session",
      },
    ],
  },
];

// grid inside the 1512 x 851 screen
export const TERM_W = 708;
export const TERM_H = 383;
export const termPos = (i: number) => ({
  x: 40 + (i % 2) * (TERM_W + 16),
  y: 52 + Math.floor(i / 2) * (TERM_H + 16),
});
/** Where the "❯ 1. Yes" line sits, for the cursor. */
export const termYesPoint = (i: number) => {
  const p = termPos(i);
  return { x: p.x + 120, y: p.y + 32 + 12 + 5 * 20.8 + 8 + 9 + 4 * 20.8 + 10 };
};

const SPIN = ["✻", "✳", "✢", "·", "✢", "✳"];

export type TermState = {
  appear: number; // 0..1
  perm: number | null; // which permission prompt is showing
  permIn: number; // 0..1 pop-in of the prompt
  answering: number; // 0..1 flash on "1. Yes"
  focus: number; // 0..1 highlight of the focused window
  dim: number; // 0..1 dimming of unfocused windows
  minimize: number; // 0..1 shrink into the dock
  tSec: number;
};

export const Terminal: React.FC<{ i: number; st: TermState }> = ({ i, st }) => {
  const spec = TERMS[i];
  const p = termPos(i);
  const perm = st.perm !== null ? spec.perms[st.perm] : null;
  const spin = SPIN[Math.floor(st.tSec * 8 + i * 2) % SPIN.length];
  const needs = perm !== null;
  const m = st.minimize;
  const tx = (756 - (p.x + TERM_W / 2)) * m;
  const ty = (930 - (p.y + TERM_H / 2)) * m;
  const border = needs
    ? `rgba(255,179,64,${0.35 + 0.45 * st.permIn})`
    : "rgba(255,255,255,.08)";
  return (
    <div
      className="term"
      style={{
        left: p.x,
        top: p.y,
        width: TERM_W,
        height: TERM_H,
        opacity: st.appear * (1 - m),
        filter: st.dim > 0.01 ? `brightness(${1 - 0.45 * st.dim})` : undefined,
        transform: `translate(${tx}px, ${ty}px) scale(${(0.96 + 0.04 * st.appear) * (1 - 0.8 * m) * (1 + 0.012 * st.focus)})`,
        borderColor:
          st.focus > 0.01
            ? `rgba(255,255,255,${0.08 + 0.5 * st.focus})`
            : border,
        boxShadow: `0 20px 50px rgba(0,0,0,.45)${st.focus > 0.01 ? `, 0 0 0 ${2 * st.focus}px rgba(255,255,255,${0.35 * st.focus})` : ""}${needs ? `, 0 0 40px -6px rgba(255,179,64,${0.35 * st.permIn})` : ""}`,
        zIndex: st.focus > 0.5 ? 2 : 1,
      }}
    >
      <div className="bar">
        <i style={{ background: "#ff5f57" }} />
        <i style={{ background: "#febc2e" }} />
        <i style={{ background: "#28c840" }} />
        <span className="t">{spec.title}</span>
        {needs ? (
          <span
            style={{
              marginLeft: "auto",
              font: "700 11px system-ui",
              color: "#FFB340",
              display: "flex",
              alignItems: "center",
              gap: 6,
              opacity: st.permIn,
            }}
          >
            <span
              style={{
                width: 7,
                height: 7,
                borderRadius: 4,
                background: "#FFB340",
                display: "inline-block",
              }}
            />
            Waiting for you
          </span>
        ) : null}
      </div>
      <div className="body">
        <span className="usr">
          {"> "}
          {spec.prompt}
        </span>
        {"\n\n"}
        <span className="or">⏺</span> {spec.tool[0]}
        {"\n"}
        <span className="dim">
          {"  ⎿  "}
          {spec.tool[1]}
        </span>
        {"\n"}
        {perm ? (
          <>
            <span className="or">⏺</span>{" "}
            {perm.head === "Bash command"
              ? `Bash(${perm.cmd})`
              : perm.head === "Fetch"
                ? `Fetch(${perm.cmd})`
                : `Update(${perm.cmd})`}
            <div
              className="perm"
              style={{
                opacity: st.permIn,
                transform: `translateY(${(1 - st.permIn) * 10}px)`,
              }}
            >
              <span className="h">{perm.head}</span>
              {"\n"}
              {"  "}
              {perm.cmd}
              {"\n\n"}
              Do you want to proceed?
              {"\n"}
              <span
                className="sel"
                style={{
                  background: `rgba(217,119,87,${0.28 + 0.5 * st.answering})`,
                }}
              >
                ❯ 1. Yes
              </span>
              {"\n"}
              <span className="dim">
                {"  2. "}
                {perm.opt2}
              </span>
              {"\n"}
              <span className="dim">
                {"  3. No, and tell Claude what to do differently"}
              </span>
            </div>
          </>
        ) : (
          <span className="or">
            {spin} Thinking…{" "}
            <span className="dim">
              ({Math.floor(8 + st.tSec)}s · esc to interrupt)
            </span>
          </span>
        )}
      </div>
    </div>
  );
};
