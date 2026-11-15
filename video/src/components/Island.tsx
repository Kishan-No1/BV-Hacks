import React from "react";
import { Easing, interpolate, spring } from "remotion";
import { SESS, SessionStatus } from "../data/sessions";
import { Clawd, IDoc, IList, IPlay, IShield, ICheck, Ok } from "./Icons";

/* ------------------------------------------------------------------ */
/* Model                                                               */
/* ------------------------------------------------------------------ */

export type Risk = "low" | "med" | "high";

export type ReqBody =
  | { kind: "cmd"; cmd: string; why?: string; chips?: string[] }
  | { kind: "diff"; file: string; meta: string; del: string; add: string };

export type ReqSpec = {
  ring: number; // which session is asking
  over?: Record<number, SessionStatus>; // avatar status overrides (queue state)
  ask: string;
  risk: Risk;
  body: ReqBody;
  acts: "allow" | "edit" | "high";
  always?: string; // command shown in "Always allow <cmd>"
};

export type View =
  | { k: "idle" }
  | { k: "working" }
  | { k: "attention" }
  | { k: "progress"; s: number }
  | { k: "req"; r: ReqSpec }
  | {
      k: "toast";
      v: "done" | "allowed" | "denied" | "auto" | "rule";
      code?: string;
    };

export type IslandKey = { at: number; view: View };

/** Per-frame decorations driven by the scene (cursor presses, hold progress, emphasis). */
export type IslandFx = {
  press?: "deny" | "allow" | "always" | "hold" | "avatar" | null;
  pressAvatar?: number;
  hoverBtn?: "deny" | "allow" | "always" | "hold" | null;
  holdFill?: number; // 0..1
  pillPop?: number; // 0..1
  chipPop?: number[]; // per chip 0..1
  diffPop?: number; // 0..1
};

type Geo = {
  w: number;
  h: number;
  r: number;
  expanded: boolean;
  risk: "high" | "med" | null;
  glassOver: boolean;
};

// Heights of the fit-to-content request cards, measured from the prototype at 1:1
// (headless Chrome, same fonts): low/cmd 219, high (cmd + chips) 248, edit (diff) 253.
function reqHeight(r: ReqSpec) {
  if (r.body.kind === "diff") return 253;
  return r.body.chips && r.body.chips.length ? 248 : 219;
}

export function geo(v: View): Geo {
  switch (v.k) {
    case "idle":
      return {
        w: 185,
        h: 32,
        r: 10,
        expanded: false,
        risk: null,
        glassOver: false,
      };
    case "working":
    case "attention":
      return {
        w: 272,
        h: 32,
        r: 10,
        expanded: false,
        risk: null,
        glassOver: false,
      };
    case "progress":
      return {
        w: 600,
        h: 256,
        r: 34,
        expanded: true,
        risk: null,
        glassOver: true,
      };
    case "req":
      return {
        w: 560,
        h: reqHeight(v.r),
        r: 34,
        expanded: true,
        risk: v.r.risk === "high" ? "high" : v.r.risk === "med" ? "med" : null,
        glassOver: false,
      };
    case "toast": {
      const w =
        v.v === "done"
          ? 310
          : v.v === "auto"
            ? 420
            : v.v === "rule"
              ? 400
              : 290;
      return { w, h: 32, r: 10, expanded: false, risk: null, glassOver: false };
    }
  }
}

/* ------------------------------------------------------------------ */
/* Motion                                                              */
/* ------------------------------------------------------------------ */

// SwiftUI .spring(response, dampingFraction) -> mass/stiffness/damping (mass 1):
// stiffness = (2π / response)^2, damping = 2 · dampingFraction · (2π / response)
const springCfg = (response: number, dampingFraction: number) => {
  const w = (2 * Math.PI) / response;
  return {
    mass: 1,
    stiffness: w * w,
    damping: 2 * dampingFraction * w,
    overshootClamping: false,
  };
};
export const OPEN = springCfg(0.5, 0.8); // open: a little bounce
export const CLOSE = springCfg(0.38, 1.0); // close: critically damped
export const NUDGE = springCfg(0.42, 0.7); // compact grows (e.g. toast)

/** The prototype swaps content 90 ms after a state change; at 30 fps that is 3 frames. */
export const SWAP = 3;

type Shadow = [number, number, number, number, number, number, number, number];
type Anim = {
  w: number;
  h: number;
  r: number;
  glass: number;
  sh: [Shadow, Shadow];
};

const NONE: Shadow = [0, 0, 0, 0, 0, 0, 0, 0];
function shadowFor(g: Geo): [Shadow, Shadow] {
  if (g.risk === "high")
    return [
      [0, 30, 70, -22, 255, 69, 58, 0.75],
      [0, 12, 40, -14, 255, 69, 58, 0.45],
    ];
  if (g.risk === "med")
    return [
      [0, 30, 70, -24, 255, 179, 64, 0.5],
      [0, 12, 36, -16, 255, 179, 64, 0.3],
    ];
  if (g.expanded) return [[0, 22, 50, -18, 0, 0, 0, 0.6], NONE];
  return [NONE, NONE];
}
const target = (v: View): Anim => {
  const g = geo(v);
  return {
    w: g.w,
    h: g.h,
    r: g.r,
    glass: g.expanded ? 1 : 0,
    sh: shadowFor(g),
  };
};
const mix = (a: number, b: number, p: number) => a + (b - a) * p;
const mixSh = (a: Shadow, b: Shadow, p: number) =>
  a.map((x, i) => mix(x, b[i], p)) as Shadow;
const shCss = (s: Shadow) =>
  `${s[0]}px ${s[1]}px ${s[2]}px ${s[3]}px rgba(${Math.round(s[4])},${Math.round(s[5])},${Math.round(s[6])},${s[7].toFixed(3)})`;

const ease = Easing.bezier(0.25, 0.1, 0.25, 1); // CSS "ease"
const easeOutQuint = Easing.bezier(0.2, 0.9, 0.25, 1); // the prototype's content curve

function segValue(
  keys: IslandKey[],
  idx: number,
  from: Anim,
  start: number,
  f: number,
  fps: number,
): Anim {
  const to = target(keys[idx].view);
  if (idx === 0) return to;
  const g = geo(keys[idx].view);
  const cfg = g.expanded ? OPEN : to.w * to.h > from.w * from.h ? NUDGE : CLOSE;
  const t = Math.max(0, f - start);
  const p = spring({ frame: t, fps, config: cfg });
  const ps = ease(Math.min(1, t / (0.5 * fps))); // box-shadow .5s ease
  const pg = ease(Math.min(1, t / (0.3 * fps))); // glass opacity .3s ease
  return {
    w: mix(from.w, to.w, p),
    h: mix(from.h, to.h, p),
    r: mix(from.r, to.r, p),
    glass: mix(from.glass, to.glass, pg),
    sh: [mixSh(from.sh[0], to.sh[0], ps), mixSh(from.sh[1], to.sh[1], ps)],
  };
}

/** Animated geometry at frame f: each key starts a spring from wherever the previous one was. */
export function islandAnim(keys: IslandKey[], f: number, fps: number): Anim {
  let idx = 0;
  let from = target(keys[0].view);
  let start = -Infinity;
  for (let k = 1; k < keys.length; k++) {
    const s = keys[k].at + SWAP;
    if (s > f) break;
    from = segValue(keys, idx, from, start, s, fps);
    idx = k;
    start = s;
  }
  return segValue(keys, idx, from, start, f, fps);
}

const lastKeyAt = (keys: IslandKey[], f: number, offset = 0) => {
  let k = 0;
  for (let i = 0; i < keys.length; i++) if (keys[i].at + offset <= f) k = i;
  return k;
};

/* ------------------------------------------------------------------ */
/* Content (JSX port of the prototype's template strings)             */
/* ------------------------------------------------------------------ */

const Avatars: React.FC<{
  ring: number;
  over?: Record<number, SessionStatus>;
  fx?: IslandFx;
}> = ({ ring, over, fx }) => (
  <div className="avs">
    {SESS.map((s, i) => (
      <button
        key={i}
        className={`av glassy${i === ring ? " on" : ""}`}
        data-st={(over && over[i]) || s.st}
        style={
          fx?.press === "avatar" && fx.pressAvatar === i
            ? { transform: "scale(.92)" }
            : undefined
        }
      >
        <Clawd w={15} />
      </button>
    ))}
  </div>
);

const Who: React.FC<{ s: number; big?: number }> = ({ s, big = 24 }) => (
  <div className="who">
    <Clawd w={big} />
    <span className="nm">Claude</span>
    <span className="sep" />
    <span className="pr">{SESS[s].prompt}</span>
  </div>
);

/** `.wave i` keyframes: 4px -> 13px -> 4px over 1s, cubic-bezier(.45,0,.55,1), staggered by negative delays. */
const waveEase = Easing.bezier(0.45, 0, 0.55, 1);
const WAVE_DELAYS = [-0.15, -0.55, -0.3, -0.75];
export const Wave: React.FC<{ tSec: number }> = ({ tSec }) => (
  <div className="wave">
    {WAVE_DELAYS.map((d, i) => {
      const p = (((tSec - d) % 1) + 1) % 1;
      const h =
        p < 0.5
          ? 4 + 9 * waveEase(p / 0.5)
          : 13 - 9 * waveEase((p - 0.5) / 0.5);
      return <i key={i} style={{ height: h }} />;
    })}
  </div>
);

const Ears: React.FC<{ view: View; tSec: number }> = ({ view, tSec }) => {
  if (view.k === "working")
    return (
      <div className="ears">
        <div className="ear">
          <Clawd w={19} />
        </div>
        <div className="ear">
          <Wave tSec={tSec} />
        </div>
      </div>
    );
  if (view.k === "attention") {
    // .pulse: opacity 1 -> .35 -> 1 over 1.3s ease-in-out
    const p = (((tSec % 1.3) + 1.3) % 1.3) / 1.3;
    const op =
      1 - 0.65 * Easing.inOut(Easing.ease)(p < 0.5 ? p * 2 : 2 - p * 2);
    return (
      <div className="ears">
        <div className="ear">
          <span className="badge-dot">
            <Clawd w={19} />
          </span>
        </div>
        <div className="ear">
          <span style={{ color: "var(--amber)", fontSize: 11, opacity: op }}>
            ●
          </span>
        </div>
      </div>
    );
  }
  if (view.k === "toast") {
    const right =
      view.v === "done" ? (
        <>
          <span className="muted">Done</span>
          <Ok />
        </>
      ) : view.v === "allowed" ? (
        <>
          <span className="muted">Allowed</span>
          <Ok />
        </>
      ) : view.v === "denied" ? (
        <>
          <span className="muted">Denied</span>
          <span style={{ color: "var(--red)", fontWeight: 800, fontSize: 13 }}>
            ✕
          </span>
        </>
      ) : view.v === "rule" ? (
        <>
          <span className="muted">Always allow</span>
          <code>{view.code}</code>
          <Ok />
        </>
      ) : (
        <>
          <span className="muted">Auto-allowed</span>
          <code>{view.code}</code>
          <Ok />
        </>
      );
    return (
      <div className="ears">
        <div className="ear">
          <Clawd w={19} />
        </div>
        <div className="ear">{right}</div>
      </div>
    );
  }
  return null;
};

const riseEase = Easing.bezier(0.2, 0.9, 0.25, 1);
const rise = (tMs: number, delayMs: number): React.CSSProperties => {
  const p = Math.max(0, Math.min(1, (tMs - delayMs) / 450));
  const e = riseEase(p);
  return e >= 1
    ? {}
    : { opacity: e, transform: `translateY(${4 * (1 - e)}px)` };
};

const ProgressPanel: React.FC<{ s: number; tInSec: number; fx?: IslandFx }> = ({
  s,
  tInSec,
  fx,
}) => {
  const sess = SESS[s];
  const tMs = tInSec * 1000;
  const secs = sess.tool ? sess.tool.t + Math.max(0, tInSec) : 0;
  return (
    <div className="xp">
      <div className="top">
        <div className="lbl">
          <IList />
          Progress
        </div>
        <div className="rt">
          <Avatars ring={s} fx={fx} />
          <div className="tabs">
            <button className="tab glassy on">
              <IList />
            </button>
            <button className="tab glassy">
              <IShield />
            </button>
          </div>
        </div>
      </div>
      <Who s={s} />
      <div className="pg">
        <ul className="steps">
          {sess.steps.map((x, i) => (
            <li key={i} style={rise(tMs, 60 + i * 45)}>
              <ICheck />
              <span>{x}</span>
            </li>
          ))}
          {sess.now ? (
            <li className="now" style={rise(tMs, 60 + sess.steps.length * 45)}>
              <IPlay />
              <span>{sess.now}</span>
            </li>
          ) : null}
        </ul>
        {sess.tool ? (
          <div className="card tool">
            <div className="p">
              <IDoc />
              <span>{sess.tool.path}</span>
            </div>
            <div className="t">{secs.toFixed(2)} seconds</div>
            <div className="bar2">
              <i style={{ width: `${Math.min(92, 18 + secs * 2.4)}%` }} />
            </div>
          </div>
        ) : (
          <div className="card tool fin">
            <div className="p">
              <Ok />
              <span>Finished</span>
            </div>
            <div className="t">3 files changed · 9m 12s</div>
            <div className="bar2">
              <i />
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

const popStyle = (p?: number): React.CSSProperties | undefined =>
  p
    ? {
        transform: `scale(${1 + 0.12 * p})`,
        filter: `brightness(${1 + 0.35 * p})`,
        transformOrigin: "center",
      }
    : undefined;

const btnStyle = (
  name: IslandFx["press"],
  fx?: IslandFx,
): React.CSSProperties | undefined => {
  const st: React.CSSProperties = {};
  if (fx?.hoverBtn === name) st.filter = "brightness(1.12)";
  if (fx?.press === name) st.transform = "scale(.965)";
  return Object.keys(st).length ? st : undefined;
};

const RequestCard: React.FC<{ r: ReqSpec; fx?: IslandFx }> = ({ r, fx }) => {
  const pill =
    r.risk === "low" ? (
      <span className="pill low" style={popStyle(fx?.pillPop)}>
        Low risk
      </span>
    ) : r.risk === "med" ? (
      <span className="pill med" style={popStyle(fx?.pillPop)}>
        Review
      </span>
    ) : (
      <span className="pill high" style={popStyle(fx?.pillPop)}>
        High risk
      </span>
    );
  const b = r.body;
  const body =
    b.kind === "cmd" ? (
      <>
        <div className="card cmd">
          <span>
            <span className="d">$</span>
            {b.cmd}
          </span>
          {b.why ? <span className="why">{b.why}</span> : null}
        </div>
        {b.chips && b.chips.length ? (
          <div className="chips">
            {b.chips.map((c, i) => (
              <span key={i} className="chip" style={popStyle(fx?.chipPop?.[i])}>
                {c}
              </span>
            ))}
          </div>
        ) : null}
      </>
    ) : (
      <div
        className="card diff"
        style={
          fx?.diffPop
            ? {
                boxShadow: `inset 0 1px 0 rgba(255,255,255,.09), inset 0 0 0 .5px rgba(255,255,255,.10), 0 0 0 ${1.5 * fx.diffPop}px rgba(255,179,64,${0.55 * fx.diffPop})`,
              }
            : undefined
        }
      >
        <div className="fh">
          <b>{b.file}</b>
          <span>{b.meta}</span>
        </div>
        <div className="ln del">{b.del}</div>
        <div className="ln add">{b.add}</div>
      </div>
    );
  const acts =
    r.acts === "high" ? (
      <div className="acts">
        <button className="btn" style={btnStyle("hold", fx)}>
          <span
            className="fill"
            style={{ width: `${(fx?.holdFill ?? 0) * 100}%` }}
          />
          Hold to allow
        </button>
        <button className="btn red wide" style={btnStyle("deny", fx)}>
          Deny<span className="kb">⌥↵</span>
        </button>
      </div>
    ) : (
      <div className="acts">
        <button className="btn" style={btnStyle("deny", fx)}>
          Deny<span className="kb">⌥⌫</span>
        </button>
        {r.acts === "allow" ? (
          <button className="btn ghost wide" style={btnStyle("always", fx)}>
            Always allow <code>{r.always ?? "npm test"}</code>
          </button>
        ) : (
          <button className="btn ghost wide">Open full diff</button>
        )}
        <button className="btn pri" style={btnStyle("allow", fx)}>
          Allow<span className="kb">⌥↵</span>
        </button>
      </div>
    );
  return (
    <div className="xp">
      <div className="rq-top">
        <Who s={r.ring} big={22} />
        <Avatars ring={r.ring} over={r.over} />
      </div>
      <div className="ask">
        <b>{r.ask}</b>
        {pill}
      </div>
      {body}
      {acts}
    </div>
  );
};

const Content: React.FC<{
  view: View;
  tSec: number;
  tInSec: number;
  fx?: IslandFx;
}> = ({ view, tSec, tInSec, fx }) => {
  if (view.k === "idle") return null;
  if (view.k === "progress")
    return <ProgressPanel s={view.s} tInSec={tInSec} fx={fx} />;
  if (view.k === "req") return <RequestCard r={view.r} fx={fx} />;
  return <Ears view={view} tSec={tSec} />;
};

/* ------------------------------------------------------------------ */
/* The island (inside a 1512pt-wide .screen)                           */
/* ------------------------------------------------------------------ */

export const SCREEN_W = 1512;

export const Island: React.FC<{
  keys: IslandKey[];
  frame: number;
  fps: number;
  fx?: IslandFx;
}> = ({ keys, frame, fps, fx }) => {
  const a = islandAnim(keys, frame, fps);

  // classes flip at the swap, like the prototype's setTimeout(…, 90)
  const kc = lastKeyAt(keys, frame, SWAP);
  const g = geo(keys[kc].view);

  // content: old content blurs out for 0.1s, new content blurs/scales in after the swap
  const kGo = lastKeyAt(keys, frame);
  const goAt = keys[kGo].at;
  const beforeSwap = kGo > 0 && frame < goAt + SWAP;
  const contentView = beforeSwap ? keys[kGo - 1].view : keys[kGo].view;
  const cw = geo(contentView).w;
  let op = 1;
  let blur = 0;
  let sc = 1;
  let tIn = 1e6;
  if (beforeSwap) {
    const po = ease(Math.min(1, (frame - goAt) / (0.1 * fps)));
    op = 1 - po;
    blur = 5 * po;
    sc = 1 - 0.06 * po;
  } else if (kGo > 0) {
    tIn = frame - (goAt + SWAP + 1); // + two rAFs
    const pin = ease(
      interpolate(tIn, [0.05 * fps, 0.27 * fps], [0, 1], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      }),
    );
    const psc = easeOutQuint(
      interpolate(tIn, [0.02 * fps, 0.52 * fps], [0, 1], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      }),
    );
    op = pin;
    blur = 5 * (1 - pin);
    sc = 0.94 + 0.06 * psc;
  }
  const tInSec = (beforeSwap ? 1e6 : tIn) / fps;

  const cls = [
    "island",
    g.expanded ? "expanded" : "",
    g.expanded && !g.glassOver ? "glass-under" : "",
    g.risk === "high" ? "risk-high" : "",
    g.risk === "med" ? "risk-med" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <>
      <div className="hw-notch" />
      <div
        className="shoulder l"
        style={{ left: SCREEN_W / 2 - a.w / 2 - 10 }}
      />
      <div className="shoulder r" style={{ left: SCREEN_W / 2 + a.w / 2 }} />
      <div
        className={cls}
        style={{
          width: a.w,
          height: a.h,
          ["--r" as string]: `${a.r}px`,
          boxShadow: `${shCss(a.sh[0])}, ${shCss(a.sh[1])}`,
        }}
      >
        <div className="bgs" />
        <div
          className="ic"
          style={{
            width: cw,
            marginLeft: -cw / 2,
            opacity: op,
            filter: `blur(${blur > 0.01 ? blur : 0}px)`,
            transform: `scale(${sc})`,
          }}
        >
          <Content
            view={contentView}
            tSec={frame / fps}
            tInSec={tInSec}
            fx={fx}
          />
        </div>
        <div className="glass" style={{ opacity: a.glass }} />
      </div>
    </>
  );
};
