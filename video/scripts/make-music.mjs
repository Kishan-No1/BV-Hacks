#!/usr/bin/env node
// Synthesises a quiet, royalty-free music bed for the demo video:
// a warm sine pad (Am - F - C - G, 4 s per chord) plus a soft plucked
// arpeggio that enters around the "Meet Nod" reveal. No samples, no downloads.
//
//   node scripts/make-music.mjs [seconds=100] [arpEntersAt=16]
//
// Output: public/music/bed.mp3 (48 kHz stereo, 160 kbps, peak about -6 dBFS).
// The WAV is synthesised first, then encoded with ffmpeg so the repo stays small.
import { writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SECONDS = Number(process.argv[2] ?? 100);
const ARP_AT = Number(process.argv[3] ?? 16);
const SR = 48000;
const N = Math.floor(SECONDS * SR);
const BAR = 4; // seconds per chord

const hz = (midi) => 440 * Math.pow(2, (midi - 69) / 12);
// voicings (MIDI): Am(add9), Fmaj7, Cadd9, G6 - all soft, no thirds in the bass
const CHORDS = [
  [45, 52, 59, 60, 64],
  [41, 48, 57, 60, 64],
  [36, 43, 55, 62, 64],
  [43, 50, 59, 62, 64],
];
const ARP = [
  [69, 72, 76, 71],
  [69, 72, 77, 76],
  [67, 72, 74, 76],
  [67, 71, 74, 76],
];

const L = new Float32Array(N);
const R = new Float32Array(N);

// --- pad: per-chord windows with raised-cosine crossfades ---
const XF = 1.2; // crossfade seconds
function chordWeight(t, c) {
  const cyc = CHORDS.length * BAR;
  let u = ((t % cyc) + cyc) % cyc; // 0..16
  const start = c * BAR;
  // distance into this chord's slot, wrapping around the loop
  let d = u - start;
  if (d < -XF) d += cyc;
  if (d > cyc - XF) d -= cyc;
  if (d < -XF / 2 || d > BAR + XF / 2) return 0;
  const fadeIn = Math.min(1, Math.max(0, (d + XF / 2) / XF));
  const fadeOut = Math.min(1, Math.max(0, (BAR + XF / 2 - d) / XF));
  const w = Math.min(fadeIn, fadeOut);
  return 0.5 - 0.5 * Math.cos(Math.PI * w);
}

for (let c = 0; c < CHORDS.length; c++) {
  const notes = CHORDS[c].map(hz);
  for (let i = 0; i < N; i++) {
    const t = i / SR;
    const w = chordWeight(t, c);
    if (w === 0) continue;
    let sL = 0;
    let sR = 0;
    notes.forEach((f, k) => {
      const amp = k === 0 ? 0.55 : 0.32;
      const a = Math.sin(2 * Math.PI * f * 1.0018 * t + k);
      const b = Math.sin(2 * Math.PI * f * 0.9982 * t + 2 * k);
      const h = 0.18 * Math.sin(2 * Math.PI * f * 2 * t + k * 0.7);
      sL += amp * (0.62 * a + 0.38 * b + h);
      sR += amp * (0.38 * a + 0.62 * b + h);
    });
    const breathe = 0.85 + 0.15 * Math.sin(2 * Math.PI * t / 8);
    L[i] += sL * w * breathe * 0.11;
    R[i] += sR * w * breathe * 0.11;
  }
}

// one-pole low-pass on the pad for warmth
function lowpass(buf, cutoff) {
  const a = Math.exp(-2 * Math.PI * cutoff / SR);
  let y = 0;
  for (let i = 0; i < buf.length; i++) {
    y = (1 - a) * buf[i] + a * y;
    buf[i] = y;
  }
}
lowpass(L, 1400);
lowpass(R, 1400);

// --- arpeggio: 8th notes at 120 bpm, enters with a 2 s fade at ARP_AT ---
const STEP = 0.25;
for (let n = 0; n * STEP < SECONDS; n++) {
  const t0 = n * STEP;
  if (t0 < ARP_AT - 0.01) continue;
  const chord = Math.floor(t0 / BAR) % ARP.length;
  const note = ARP[chord][n % 4];
  const f = hz(note);
  const enter = Math.min(1, (t0 - ARP_AT) / 2);
  const accent = n % 4 === 0 ? 1 : 0.72;
  const pan = n % 2 === 0 ? 0.35 : 0.65;
  const len = Math.floor(0.9 * SR);
  const i0 = Math.floor(t0 * SR);
  for (let j = 0; j < len && i0 + j < N; j++) {
    const t = j / SR;
    const env = Math.min(1, t / 0.006) * Math.exp(-t * 7.5);
    const s = (Math.sin(2 * Math.PI * f * t) + 0.22 * Math.sin(2 * Math.PI * f * 3 * t) * Math.exp(-t * 18)) * env;
    const v = s * 0.075 * enter * accent;
    L[i0 + j] += v * (1 - pan) * 2;
    R[i0 + j] += v * pan * 2;
  }
}

// --- small Schroeder-style reverb ---
function reverb(buf, mix) {
  const out = new Float32Array(buf.length);
  const combs = [1557, 1617, 1491, 1422].map((d) => ({ d, b: new Float32Array(d), i: 0, fb: 0.78 }));
  for (let n = 0; n < buf.length; n++) {
    let s = 0;
    for (const c of combs) {
      const y = c.b[c.i];
      c.b[c.i] = buf[n] + y * c.fb;
      c.i = (c.i + 1) % c.d;
      s += y;
    }
    out[n] = buf[n] * (1 - mix) + (s / combs.length) * mix;
  }
  return out;
}
const L2 = reverb(L, 0.28);
const R2 = reverb(R, 0.28);

// gentle fade in/out, normalise to about -6 dBFS
let peak = 0;
for (let i = 0; i < N; i++) {
  const t = i / SR;
  const fade = Math.min(1, t / 1.5, (SECONDS - t) / 3);
  L2[i] *= fade;
  R2[i] *= fade;
  peak = Math.max(peak, Math.abs(L2[i]), Math.abs(R2[i]));
}
const gain = 0.5 / (peak || 1);

const data = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
  data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L2[i] * gain)) * 32767), i * 4);
  data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R2[i] * gain)) * 32767), i * 4 + 2);
}
const header = Buffer.alloc(44);
header.write('RIFF', 0);
header.writeUInt32LE(36 + data.length, 4);
header.write('WAVE', 8);
header.write('fmt ', 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(2, 22);
header.writeUInt32LE(SR, 24);
header.writeUInt32LE(SR * 4, 28);
header.writeUInt16LE(4, 32);
header.writeUInt16LE(16, 34);
header.write('data', 36);
header.writeUInt32LE(data.length, 40);

const wav = join(ROOT, 'public/music/bed.wav');
const out = join(ROOT, 'public/music/bed.mp3');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(wav, Buffer.concat([header, data]));
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'libmp3lame', '-b:a', '160k', out]);
rmSync(wav);
console.log(`wrote ${out} (${SECONDS}s, arp at ${ARP_AT}s)`);
