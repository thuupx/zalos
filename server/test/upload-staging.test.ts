import { test, expect } from "bun:test";
import {
  copyFileSync,
  existsSync,
  linkSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { stageUploadFile } from "../src/gateway/zca.ts";

// Production staging lives on a volume while tmpdir() is tmpfs in Docker,
// so linkSync fails with EXDEV. These tests inject that error instead of
// requiring a real second mount.
const errno = (code: string) =>
  Object.assign(new Error(`${code}: simulated`), { code });

test("stageUploadFile hard-links when the source shares a device", () => {
  const src = mkdtempSync(join(tmpdir(), "zalos-src-"));
  const path = join(src, "photo.jpg");
  writeFileSync(path, "image-bytes");
  try {
    const staged = stageUploadFile(
      { name: "photo.jpg", path },
      {
        link: linkSync,
        copy: () => {
          throw new Error("copy must not run when the link works");
        },
      },
    );
    try {
      expect(basename(staged.path)).toBe("photo.jpg");
      expect(readFileSync(staged.path, "utf8")).toBe("image-bytes");
      expect(statSync(staged.path).ino).toBe(statSync(path).ino);
    } finally {
      rmSync(staged.dir, { recursive: true, force: true });
    }
  } finally {
    rmSync(src, { recursive: true, force: true });
  }
});

test("stageUploadFile copies bytes and keeps the sanitized name on EXDEV", () => {
  const src = mkdtempSync(join(tmpdir(), "zalos-src-"));
  const path = join(src, "upload.bin");
  writeFileSync(path, "voice-bytes");
  let copiedTo = "";
  try {
    const staged = stageUploadFile(
      { name: "../evil name?.png", path },
      {
        link: () => {
          throw errno("EXDEV");
        },
        copy: (source, target) => {
          copiedTo = target;
          copyFileSync(source, target);
        },
      },
    );
    try {
      expect(copiedTo).toBe(staged.path);
      expect(basename(staged.path)).toBe("evil name_.png");
      expect(readFileSync(staged.path, "utf8")).toBe("voice-bytes");
      // A copy, not a move: the framer's file must survive staging.
      expect(readFileSync(path, "utf8")).toBe("voice-bytes");
      expect(statSync(staged.path).ino).not.toBe(statSync(path).ino);
    } finally {
      rmSync(staged.dir, { recursive: true, force: true });
    }
  } finally {
    rmSync(src, { recursive: true, force: true });
  }
});

test("stageUploadFile propagates non-EXDEV link errors and cleans up", () => {
  const src = mkdtempSync(join(tmpdir(), "zalos-src-"));
  const path = join(src, "upload.bin");
  writeFileSync(path, "bytes");
  let dir = "";
  try {
    expect(() =>
      stageUploadFile(
        { name: "upload.bin", path },
        {
          link: (_source, target) => {
            dir = dirname(target);
            throw errno("EACCES");
          },
          copy: () => {
            throw new Error("copy must not run after a non-EXDEV link error");
          },
        },
      ),
    ).toThrow("EACCES");
    expect(existsSync(dir)).toBe(false);
  } finally {
    rmSync(src, { recursive: true, force: true });
  }
});

test("stageUploadFile propagates copy errors after EXDEV and cleans up", () => {
  const src = mkdtempSync(join(tmpdir(), "zalos-src-"));
  const path = join(src, "upload.bin");
  writeFileSync(path, "bytes");
  let dir = "";
  try {
    expect(() =>
      stageUploadFile(
        { name: "upload.bin", path },
        {
          link: () => {
            throw errno("EXDEV");
          },
          copy: (_source, target) => {
            dir = dirname(target);
            throw errno("ENOSPC");
          },
        },
      ),
    ).toThrow("ENOSPC");
    expect(existsSync(dir)).toBe(false);
  } finally {
    rmSync(src, { recursive: true, force: true });
  }
});
