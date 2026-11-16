import React from "react";
import { Composition, Folder } from "remotion";
import { NotchAgentDemo } from "./NotchAgentDemo";
import { IslandCheck } from "./IslandCheck";
import { FPS, HEIGHT, TOTAL, WIDTH } from "./timeline";

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="NotchAgentDemo"
      component={NotchAgentDemo}
      durationInFrames={TOTAL}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
    />
    <Folder name="Checks">
      <Composition
        id="IslandCheck"
        component={IslandCheck}
        durationInFrames={1}
        fps={FPS}
        width={1512}
        height={640}
        defaultProps={{ state: "low" }}
      />
    </Folder>
  </>
);
