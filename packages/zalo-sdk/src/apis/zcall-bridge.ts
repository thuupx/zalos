import { type ChildProcess, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import net from "node:net";
import { decodeZCallIpc, encodeZCallIpc } from "../core/crypto.ts";
import { ZaloCallError } from "../core/errors.ts";
import { CallMakeType } from "../models/enums.ts";
import type { VoipControlEvent } from "../models/events.ts";
import type { ZaloListener } from "../ws/listener.ts";
import type { CallApi } from "./call.ts";

export interface ZCallBridgePaths {
  recvPath: string;
  sendPath: string;
}

export interface ZCallPartner {
  id: string;
  avatar?: string;
  name?: string;
}

export interface ZCallInitPayload {
  local: ZCallPartner;
  osInfo?: string;
  mainWindowId?: string;
  logPath?: string;
  zrtcLogPath?: string;
  dumpPath?: string;
  clientVersion?: number;
  language?: string;
  timeoutMakeCall2ZRtp?: number;
  enablePreviewDeviceOutgoing?: boolean;
  enablePreviewDeviceIncall?: boolean;
  enableUnstableConnecting?: boolean;
  autoAudioInput?: boolean;
  autoAudioOutput?: boolean;
  receiveCallWhileNoMicrophoneDetected?: boolean;
  receiveCallWhileNoSpeakerDetected?: boolean;
  [key: string]: unknown;
}

export interface ZCallNativeMessage {
  type: "update" | "sendSignal" | "request" | "response" | "recvSignal" | "control";
  command?: string | number;
  data?: unknown;
  [key: string]: unknown;
}

const CHUNK_CHAR_LIMIT = 4000;

/**
 * Splits a hex payload into ZaloCall macOS IPC chunk messages (`<= 4000` chars).
 * Multi-chunk messages use `<slice>#<seq>#<totalCount>#<index>#$`; single chunks use `<hex>$`.
 */
export function buildZCallChunkMessages(
  hexPayload: string,
  prevSeq = 0,
  nowMs = Date.now(),
): { chunks: string[]; lastSeq: number } {
  if (hexPayload.length <= CHUNK_CHAR_LIMIT) {
    return { chunks: [`${hexPayload}$`], lastSeq: prevSeq };
  }
  const totalCount = Math.ceil(hexPayload.length / CHUNK_CHAR_LIMIT);
  let seq = Math.max(prevSeq + 1, nowMs);
  const chunks: string[] = [];
  for (let idx = 0; idx < totalCount; idx++) {
    const slice = hexPayload.slice(idx * CHUNK_CHAR_LIMIT, (idx + 1) * CHUNK_CHAR_LIMIT);
    chunks.push(`${slice}#${seq}#${totalCount}#${idx}#$`);
    seq += 1;
  }
  return { chunks, lastSeq: seq - 1 };
}

/**
 * Dual UNIX-socket / named-pipe IPC bridge for the official native `ZaloCall` (`zcall-v2`) helper.
 * Implements AES-128-CBC hex framing, 4000-char chunked writes with ack flow control,
 * `native-ready` buffering, and direct wiring to `CallApi` + `ZaloListener`.
 */
export class ZCallV2Bridge extends EventEmitter {
  readonly paths: ZCallBridgePaths;
  private recvServer: net.Server | null = null;
  private sendServer: net.Server | null = null;
  private recvSocket: net.Socket | null = null;
  private sendSocket: net.Socket | null = null;
  private helperProc: ChildProcess | null = null;
  private recvBuffer = "";
  private nativeReady = false;
  private lastSeq = 0;
  private sendQueue: Array<{
    msg: ZCallNativeMessage;
    resolve: () => void;
    reject: (err: Error) => void;
  }> = [];
  private sending = false;
  private pendingAck: (() => void) | null = null;

  constructor(paths?: ZCallBridgePaths) {
    super();
    this.paths = paths ?? ZCallV2Bridge.defaultPaths();
  }

  static defaultPaths(): ZCallBridgePaths {
    if (process.platform === "win32") {
      return {
        recvPath: "\\\\.\\pipe\\PipeZCallRecv",
        sendPath: "\\\\.\\pipe\\PipeZCallSend",
      };
    }
    return {
      recvPath: "/tmp/socketzalorecv2021",
      sendPath: "/tmp/socketzalosend2021",
    };
  }

  get isNativeReady(): boolean {
    return this.nativeReady;
  }

  async start(): Promise<void> {
    if (this.recvServer || this.sendServer) return;

    this.recvServer = net.createServer((sock) => {
      this.recvSocket = sock;
      this.recvBuffer = "";
      sock.on("data", (chunk) => this.onRecvData(chunk.toString("utf8")));
      sock.on("error", (err) => this.emit("error", err));
      sock.on("close", () => {
        if (this.recvSocket === sock) this.recvSocket = null;
        this.emit("recv_closed");
      });
    });

    this.sendServer = net.createServer((sock) => {
      this.sendSocket = sock;
      if (this.nativeReady) {
        void this.flushQueue();
      }
      sock.on("data", () => {
        // ZaloCall writes back an ack byte after consuming each chunk.
        const ack = this.pendingAck;
        this.pendingAck = null;
        ack?.();
      });
      sock.on("error", (err) => this.emit("error", err));
      sock.on("close", () => {
        if (this.sendSocket === sock) this.sendSocket = null;
        this.nativeReady = false;
        this.pendingAck = null;
        this.emit("send_closed");
      });
    });

    await Promise.all([
      listenServer(this.recvServer, this.paths.recvPath),
      listenServer(this.sendServer, this.paths.sendPath),
    ]);
  }

  spawnHelper(binaryPath: string, extraArgs: string[] = []): ChildProcess {
    if (this.helperProc) return this.helperProc;
    const proc = spawn(binaryPath, [this.paths.recvPath, this.paths.sendPath, ...extraArgs], {
      stdio: "ignore",
    });
    this.helperProc = proc;
    proc.on("exit", (code, signal) => {
      this.helperProc = null;
      this.nativeReady = false;
      this.emit("helper_exit", { code, signal });
    });
    proc.on("error", (err) => this.emit("error", err));
    return proc;
  }

  async stop(): Promise<void> {
    this.nativeReady = false;
    this.pendingAck?.();
    this.pendingAck = null;
    while (this.sendQueue.length > 0) {
      this.sendQueue.shift()!.reject(new ZaloCallError("ZCallV2Bridge stopped"));
    }
    this.recvSocket?.destroy();
    this.sendSocket?.destroy();
    this.recvSocket = null;
    this.sendSocket = null;

    await Promise.all([
      this.recvServer ? new Promise<void>((r) => this.recvServer!.close(() => r())) : Promise.resolve(),
      this.sendServer ? new Promise<void>((r) => this.sendServer!.close(() => r())) : Promise.resolve(),
    ]);
    this.recvServer = null;
    this.sendServer = null;

    if (this.helperProc && !this.helperProc.killed) {
      this.helperProc.kill("SIGINT");
      this.helperProc = null;
    }
  }

  private onRecvData(text: string): void {
    this.recvBuffer += text;
    let idx: number;
    while ((idx = this.recvBuffer.indexOf("$")) >= 0) {
      const packet = this.recvBuffer.slice(0, idx);
      this.recvBuffer = this.recvBuffer.slice(idx + 1);
      if (!packet.trim()) continue;
      let msg: ZCallNativeMessage;
      try {
        msg = decodeZCallIpc<ZCallNativeMessage>(packet);
      } catch (err) {
        this.emit("error", err);
        continue;
      }
      this.handleNativeMessage(msg);
    }
  }

  private handleNativeMessage(msg: ZCallNativeMessage): void {
    this.emit("message", msg);
    if (msg.type === "update" && msg.command === "native-ready") {
      this.nativeReady = true;
      this.emit("native_ready");
      void this.flushQueue();
      return;
    }
    if (msg.type === "sendSignal") {
      this.emit("send_signal", {
        command: Number(msg.command),
        data: (msg.data ?? {}) as Record<string, unknown>,
      });
      return;
    }
    if (msg.type === "request" && msg.command === "killMe") {
      this.emit("kill_requested");
      if (this.helperProc && !this.helperProc.killed) {
        this.helperProc.kill("SIGINT");
      }
      return;
    }
    this.emit(`${msg.type}:${String(msg.command ?? "")}`, msg.data);
  }

  sendToNative(msg: ZCallNativeMessage): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.sendQueue.push({ msg, resolve, reject });
      if (this.nativeReady && this.sendSocket) {
        void this.flushQueue();
      }
    });
  }

  private async flushQueue(): Promise<void> {
    if (this.sending || !this.nativeReady || !this.sendSocket) return;
    this.sending = true;
    try {
      while (this.sendQueue.length > 0 && this.nativeReady && this.sendSocket) {
        const next = this.sendQueue.shift()!;
        try {
          await this.writeEncryptedMessage(next.msg);
          next.resolve();
        } catch (err) {
          next.reject(err instanceof Error ? err : new ZaloCallError(String(err)));
        }
      }
    } finally {
      this.sending = false;
    }
  }

  private async writeEncryptedMessage(msg: ZCallNativeMessage): Promise<void> {
    const sock = this.sendSocket;
    if (!sock || sock.destroyed) {
      throw new ZaloCallError("ZaloCall send socket is not connected");
    }
    const hex = encodeZCallIpc(msg);
    const { chunks, lastSeq } = buildZCallChunkMessages(hex, this.lastSeq);
    this.lastSeq = lastSeq;

    if (chunks.length === 1) {
      await writeSocket(sock, chunks[0]!);
      return;
    }

    for (let i = 0; i < chunks.length; i++) {
      await writeSocket(sock, chunks[i]!);
      if (i < chunks.length - 1) {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => {
            if (this.pendingAck === onAck) this.pendingAck = null;
            reject(new ZaloCallError("Timed out waiting for ZaloCall chunk ack"));
          }, 5000);
          const onAck = () => {
            clearTimeout(timer);
            resolve();
          };
          this.pendingAck = onAck;
        });
      }
    }
  }

  // ---- High-level helper messages ----

  initLocalUser(payload: ZCallInitPayload): Promise<void> {
    return this.sendToNative({ type: "update", command: "init", data: payload });
  }

  makeCall(
    partner: ZCallPartner[],
    type: CallMakeType,
    groupInfo?: { id: string; name: string; avatar?: string; maxUsers?: number },
    isFirstCall = true,
  ): Promise<void> {
    return this.sendToNative({
      type: "request",
      command: "makeCall",
      data: {
        partner,
        type,
        ...(groupInfo ? { groupInfo } : {}),
        isFirstCall,
      },
    });
  }

  endCall(): Promise<void> {
    return this.sendToNative({ type: "request", command: "endCall", data: null });
  }

  listDevices(): Promise<void> {
    return this.sendToNative({ type: "request", command: "listDevice", data: null });
  }

  updateDevices(data: Record<string, unknown>): Promise<void> {
    return this.sendToNative({ type: "update", command: "listDevice", data });
  }

  forwardVoipControl(event: VoipControlEvent): Promise<void> {
    return this.sendToNative({
      type: "control",
      data: {
        act_type: "voip",
        act: event.act,
        data: event.data,
        inCallStatus: event.inCallStatus,
      },
    });
  }

  sendSignalResponse(command: number, data: unknown): Promise<void> {
    return this.sendToNative({ type: "recvSignal", command, data });
  }

  /**
   * Automatically bridges `listener` (`voip_control`) and `callApi` (`dispatchNativeSignal`)
   * with the native `ZaloCall` helper over IPC. Returns an unbind cleanup function.
   */
  attach(listener: ZaloListener, callApi: CallApi): () => void {
    const onVoip = (event: VoipControlEvent) => {
      void this.forwardVoipControl(event).catch((err) => this.emit("error", err));
    };
    const onSendSignal = async (evt: { command: number; data: Record<string, unknown> }) => {
      try {
        const res = await callApi.dispatchNativeSignal(evt.command, evt.data);
        await this.sendSignalResponse(evt.command, res);
      } catch (err) {
        this.emit("error", err);
      }
    };
    listener.on("voip_control", onVoip);
    this.on("send_signal", onSendSignal);
    return () => {
      listener.off("voip_control", onVoip);
      this.off("send_signal", onSendSignal);
    };
  }
}

function listenServer(server: net.Server, path: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const onErr = (err: Error) => reject(err);
    server.once("error", onErr);
    server.listen(path, () => {
      server.off("error", onErr);
      resolve();
    });
  });
}

function writeSocket(sock: net.Socket, data: string): Promise<void> {
  return new Promise((resolve, reject) => {
    sock.write(data, "utf8", (err) => {
      if (err) reject(err);
      else resolve();
    });
  });
}
