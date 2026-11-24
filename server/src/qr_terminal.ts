// Renders a Zalo login QR PNG in the terminal. Primary path decodes the
// QR payload and re-renders it with qrcode-terminal so it is crisp at
// terminal size. If the payload cannot be decoded the PNG itself is
// rendered: the bounding box and module size come from the image, and two
// module rows are drawn per character row using the upper-half block with
// explicit black/white ANSI colors so it is scannable on any theme.
import { PNG } from "pngjs";
import jsQR from "jsqr";
import qrcode from "qrcode-terminal";

export function renderQrTerminal(pngBytes: Uint8Array): string {
  const png = PNG.sync.read(Buffer.from(pngBytes));
  const code = jsQR(
    new Uint8ClampedArray(png.data),
    png.width,
    png.height,
    { inversionAttempts: "attemptBoth" },
  );
  if (code !== null && code.data !== "") {
    let out = "";
    qrcode.generate(code.data, { small: true }, (s: string) => {
      out = s;
    });
    return out;
  }
  return renderImageFallback(png.data, png.width, png.height);
}

function dark(data: Uint8Array, w: number, x: number, y: number): boolean {
  const i = (y * w + x) * 4;
  if (data[i + 3] < 128) return false;
  return (data[i] * 299 + data[i + 1] * 587 + data[i + 2] * 114) / 1000 < 128;
}

// Exported for tests: renders a QR-like image as a half-block matrix with
// a 2-module quiet zone. Detects the module grid by scanning for a row
// whose first five runs match the finder's 1:1:3:1:1 ratio.
export function renderImageFallback(
  data: Uint8Array,
  w: number,
  h: number,
): string {
  let left = w, top = h, right = -1, bottom = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (dark(data, w, x, y)) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  if (right < 0) return "(unreadable QR image)\n";

  const bw = right - left + 1;
  const bh = bottom - top + 1;
  const dim = Math.min(bw, bh);

  // First five dark:light runs on a row, starting at the row's leftmost
  // dark pixel, or null.
  const runs5 = (y: number): number[] | null => {
    let x = left;
    while (x <= right && !dark(data, w, x, y)) x++;
    if (x > right) return null;
    const runs: number[] = [];
    while (x <= right && runs.length < 5) {
      const d = dark(data, w, x, y);
      let len = 0;
      while (x + len <= right && dark(data, w, x + len, y) === d) len++;
      runs.push(len);
      x += len;
    }
    return runs.length === 5 ? runs : null;
  };

  let moduleSize = 0;
  for (let y = top; y <= top + Math.floor(bh / 4) && moduleSize === 0; y++) {
    const runs = runs5(y);
    if (runs === null) continue;
    const base = (runs[0] + runs[1] + runs[3] + runs[4]) / 4;
    if (base <= 0) continue;
    if (Math.abs(runs[2] - 3 * base) > base * 0.6) continue;
    if (runs.some((r, i) => i !== 2 && Math.abs(r - base) > base * 0.4)) {
      continue;
    }
    moduleSize = runs.reduce((a, b) => a + b, 0) / 7;
  }
  if (moduleSize <= 0) moduleSize = dim / 21;

  // QR grids are 21 + 4v modules; snap the measured size to that family.
  let n = Math.round(dim / moduleSize);
  n = 21 + 4 * Math.round((n - 21) / 4);
  if (n < 21) n = 21;

  const cell = (gy: number, gx: number): boolean => {
    if (gy < 0 || gx < 0 || gy >= n || gx >= n) return false;
    const px = Math.min(left + Math.floor((gx + 0.5) * moduleSize), w - 1);
    const py = Math.min(top + Math.floor((gy + 0.5) * moduleSize), h - 1);
    return dark(data, w, px, py);
  };

  const quiet = 2;
  const total = n + quiet * 2;
  const lines: string[] = [];
  for (let r = 0; r < total; r += 2) {
    let line = "";
    for (let c = 0; c < total; c++) {
      const up = cell(r - quiet, c - quiet);
      const dn = cell(r + 1 - quiet, c - quiet);
      line += `\x1b[${up ? 30 : 37};${dn ? 40 : 47}m\u2580`;
    }
    lines.push(line + "\x1b[0m");
  }
  return lines.join("\n") + "\n";
}
