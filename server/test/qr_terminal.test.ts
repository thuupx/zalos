import { test, expect } from "bun:test";
import { PNG } from "pngjs";
import QRCode from "qrcode";
import qrcodeTerminal from "qrcode-terminal";
import {
  renderQrTerminal,
  renderImageFallback,
} from "../src/qr_terminal.ts";

const PAYLOAD = "zlp-qr-test-payload-0123456789";

// Parses our half-block ANSI output back into a boolean matrix.
function parseHalfBlock(text: string): boolean[][] {
  const rows: boolean[][] = [];
  for (const line of text.replace(/\n$/, "").split("\n")) {
    const upper: boolean[] = [];
    const lower: boolean[] = [];
    const re = /\x1b\[(\d+);(\d+)m▀/g;
    let m;
    while ((m = re.exec(line)) !== null) {
      upper.push(m[1] === "30");
      lower.push(m[2] === "40");
    }
    rows.push(upper, lower);
  }
  return rows;
}

async function qrPng(payload: string): Promise<Buffer> {
  return QRCode.toBuffer(payload, {
    errorCorrectionLevel: "M",
    scale: 4,
    margin: 4,
  }) as Promise<Buffer>;
}

test("decodes the payload and re-renders it via qrcode-terminal", async () => {
  const png = await qrPng(PAYLOAD);
  const out = renderQrTerminal(new Uint8Array(png));
  let expected = "";
  qrcodeTerminal.generate(PAYLOAD, { small: true }, (s: string) => {
    expected = s;
  });
  expect(out).toBe(expected);
});

test("fallback renders the image itself and the matrix survives", async () => {
  // Source module matrix straight from the QR encoder.
  const code = QRCode.create(PAYLOAD, { errorCorrectionLevel: "M" });
  const size = code.modules.size;
  const src: boolean[][] = [];
  for (let r = 0; r < size; r++) {
    const row: boolean[] = [];
    for (let c = 0; c < size; c++) row.push(!!code.modules.get(r, c));
    src.push(row);
  }

  // Rasterise it into a PNG with a quiet zone, module scale 3.
  const scale = 3;
  const margin = 4;
  const dim = (size + margin * 2) * scale;
  const png = new PNG({ width: dim, height: dim });
  png.data.fill(255);
  for (let y = 0; y < dim; y++) {
    for (let x = 0; x < dim; x++) {
      const r = Math.floor(y / scale) - margin;
      const c = Math.floor(x / scale) - margin;
      const i = (y * dim + x) * 4;
      const d = r >= 0 && c >= 0 && r < size && c < size && src[r][c];
      png.data[i] = png.data[i + 1] = png.data[i + 2] = d ? 0 : 255;
      png.data[i + 3] = 255;
    }
  }

  const out = renderImageFallback(png.data, dim, dim);
  const matrix = parseHalfBlock(out);
  const quiet = 2;
  // Odd totals pair the last row with a virtual light row.
  const evenTotal = size + quiet * 2 + ((size + quiet * 2) % 2);
  expect(matrix.length).toBe(evenTotal);
  expect(matrix[0].length).toBe(size + quiet * 2);
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      expect(matrix[r + quiet][c + quiet]).toBe(src[r][c]);
    }
  }
  // Quiet zone all light.
  for (let r = 0; r < matrix.length; r++) {
    for (let c = 0; c < matrix[r].length; c++) {
      const inQuiet =
        r < quiet || c < quiet || r >= quiet + size || c >= quiet + size;
      if (inQuiet) expect(matrix[r][c]).toBe(false);
    }
  }
});
