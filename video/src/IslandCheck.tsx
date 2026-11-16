import React from "react";
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import "./notch-agent.css";
import { EditorWindow, MenuBar, Sidebar } from "./components/Desktop";
import { GlassFilter } from "./components/Icons";
import { Island, View } from "./components/Island";
import { REQ_HIGH, REQ_LOW, REQ_MED } from "./story";

/**
 * Fidelity check: the prototype's 1512 x 640 screen at 1:1 with the island
 * settled in one state, to diff against screenshots of docs/design/prototype.html.
 *   npx remotion still IslandCheck out/checks/check-low.png --props='{"state":"low"}'
 */
const VIEWS: Record<string, View> = {
  working: { k: "working" },
  progress: { k: "progress", s: 0 },
  low: { k: "req", r: REQ_LOW },
  med: { k: "req", r: REQ_MED },
  high: { k: "req", r: REQ_HIGH },
  done: { k: "toast", v: "done" },
};

export const IslandCheck: React.FC<{ state: string }> = ({ state }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const view = VIEWS[state] ?? VIEWS.low;
  return (
    <AbsoluteFill style={{ background: "#1d1d1f" }}>
      <div className="nd">
        <div className="screen" style={{ height: 640 }}>
          <GlassFilter />
          <MenuBar />
          <Sidebar />
          <EditorWindow />
          <Island
            keys={[
              { at: -200, view: { k: "working" } },
              { at: -45, view },
            ]}
            frame={frame}
            fps={fps}
          />
        </div>
      </div>
    </AbsoluteFill>
  );
};
