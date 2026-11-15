import React from "react";

export type SessionStatus = "work" | "need" | "done";

export type Session = {
  prompt: string;
  st: SessionStatus;
  steps: React.ReactNode[];
  now: string | null;
  tool: { path: string; t: number } | null;
};

/** Same sessions as the prototype, plus a fourth so the video matches "four agents". */
export const SESS: Session[] = [
  {
    prompt: "add token refresh to auth",
    st: "work",
    steps: [
      <>
        Read <code>src/auth/session.ts</code>
      </>,
      <>Searched “SessionError” in 6 files</>,
      <>
        Ran <code>npm test -- src/auth</code>
      </>,
      <>Planned a retry on 401</>,
    ],
    now: "Editing session.ts",
    tool: { path: "src/auth/session.ts", t: 12.5 },
  },
  {
    prompt: "rewrite the hero copy for launch",
    st: "work",
    steps: [
      <>
        Read <code>app/page.tsx</code>
      </>,
      <>
        Read <code>docs/brand-voice.md</code>
      </>,
      <>Drafted 3 headline options</>,
      <>Picked the shortest one</>,
    ],
    now: "Updating the hero section",
    tool: { path: "app/page.tsx", t: 4.2 },
  },
  {
    prompt: "fix the flaky CI cache",
    st: "done",
    steps: [
      <>
        Read <code>.github/workflows/ci.yml</code>
      </>,
      <>Keyed the cache to the lockfile</>,
      <>Ran the workflow locally</>,
      <>All checks green</>,
    ],
    now: null,
    tool: null,
  },
  {
    prompt: "write the API docs",
    st: "work",
    steps: [
      <>
        Read <code>src/api/routes.ts</code>
      </>,
      <>Listed 14 endpoints</>,
      <>
        Drafted <code>docs/api.md</code>
      </>,
      <>Checked every example</>,
    ],
    now: "Fetching the style guide",
    tool: { path: "docs/api.md", t: 7.8 },
  },
];
