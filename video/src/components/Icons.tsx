import React from "react";

/** The pixel Claude Code mascot, exactly as drawn in the prototype (18x13 grid). */
export const Clawd: React.FC<{
  w?: number;
  style?: React.CSSProperties;
  color?: string;
}> = ({ w = 20, style, color }) => (
  <svg
    className="clawd"
    width={w}
    height={Math.round((w * 13) / 18)}
    viewBox="0 0 18 13"
    fill="currentColor"
    shapeRendering="crispEdges"
    aria-label="Claude Code"
    style={{ ...(color ? { color } : {}), ...style }}
  >
    <rect x="3" y="0" width="12" height="2.5" />
    <rect x="3" y="2.5" width="2" height="2.5" />
    <rect x="6" y="2.5" width="6" height="2.5" />
    <rect x="13" y="2.5" width="2" height="2.5" />
    <rect x="1" y="5" width="16" height="2.5" />
    <rect x="3" y="7.5" width="12" height="2.5" />
    <rect x="4" y="10" width="1" height="3" />
    <rect x="6" y="10" width="1" height="3" />
    <rect x="11" y="10" width="1" height="3" />
    <rect x="13" y="10" width="1" height="3" />
  </svg>
);

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

export const IList = () => (
  <svg viewBox="0 0 24 24" {...stroke} strokeWidth={2}>
    <rect x="3" y="4" width="6" height="6" rx="1.6" />
    <path d="M4.6 7l1.1 1.1L7.6 6" />
    <circle cx="6" cy="17" r="3" />
    <path d="M13 7h8M13 17h8" />
  </svg>
);
export const IShield = () => (
  <svg viewBox="0 0 24 24" {...stroke} strokeWidth={2}>
    <path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.3-7.5 9.5-4.3-1.2-7.5-4.9-7.5-9.5V6L12 3z" />
    <path d="M9 12l2 2 4-4" />
  </svg>
);
export const ICheck = () => (
  <svg viewBox="0 0 24 24" {...stroke} strokeWidth={3}>
    <path d="M4.5 12.5l5 5L19.5 6.5" />
  </svg>
);
export const IPlay = () => (
  <svg viewBox="0 0 24 24" fill="currentColor">
    <path d="M7 4.8v14.4c0 .8.9 1.3 1.6.8l11-7.2c.6-.4.6-1.2 0-1.6l-11-7.2C7.9 3.5 7 4 7 4.8z" />
  </svg>
);
export const IDoc = () => (
  <svg viewBox="0 0 24 24" fill="currentColor">
    <path d="M6 2h8l6 6v12a2 2 0 01-2 2H6a2 2 0 01-2-2V4a2 2 0 012-2zm7 1.5V9h5.5L13 3.5zM8 13h8v1.6H8V13zm0 4h8v1.6H8V17z" />
  </svg>
);
export const Ok = () => (
  <svg className="ok" viewBox="0 0 24 24" {...stroke} strokeWidth={3}>
    <path d="M4.5 12.5l5 5L19.5 6.5" />
  </svg>
);

/** Liquid-glass refraction filter used by `.glass` (backdrop-filter: url(#lg)). Render once per screen. */
export const GlassFilter = () => (
  <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true">
    <filter
      id="lg"
      x="0%"
      y="0%"
      width="100%"
      height="100%"
      colorInterpolationFilters="sRGB"
    >
      <feTurbulence
        type="fractalNoise"
        baseFrequency="0.004 0.03"
        numOctaves={2}
        seed={11}
        result="noise"
      />
      <feGaussianBlur in="noise" stdDeviation="2.5" result="soft" />
      <feDisplacementMap
        in="SourceGraphic"
        in2="soft"
        scale={26}
        xChannelSelector="R"
        yChannelSelector="G"
      />
    </filter>
  </svg>
);
