import { describe, expect, test } from "bun:test";
import {
  WebrtcH264ToZaloRepacketizer,
  ZaloH264ToWebrtcRepacketizer,
} from "../src/accounts/h264_rtp_transform.ts";

function rtpPacket(opts: {
  pt: number;
  seq: number;
  ts: number;
  ssrc?: number;
  marker?: boolean;
  payload: Buffer;
}): Buffer {
  const out = Buffer.alloc(12 + opts.payload.length);
  out[0] = 0x80;
  out[1] = ((opts.marker ?? false) ? 0x80 : 0) | (opts.pt & 0x7f);
  out.writeUInt16BE(opts.seq & 0xffff, 2);
  out.writeUInt32BE(opts.ts >>> 0, 4);
  out.writeUInt32BE((opts.ssrc ?? 123456) >>> 0, 8);
  opts.payload.copy(out, 12);
  return out;
}

function rtpPayload(packet: Buffer): Buffer {
  return packet.subarray(12);
}

describe("H264 RTP repacketizers", () => {
  test("converts outbound single-NAL delta frame to Zalo Annex-B PT 97", () => {
    const repacketizer = new WebrtcH264ToZaloRepacketizer();
    const nal = Buffer.from([0x41, 1, 2, 3]);
    const output = repacketizer.processRtp(rtpPacket({
      pt: 102,
      seq: 10,
      ts: 9000,
      marker: true,
      payload: nal,
    }));
    expect(output).toHaveLength(1);
    expect(output[0]![1]! & 0x7f).toBe(97);
    expect(output[0]!.readUInt32BE(4)).toBe(9000);
    expect(rtpPayload(output[0]!)).toEqual(Buffer.concat([Buffer.from([0, 0, 0, 1]), nal]));
    expect((output[0]![1]! & 0x80) !== 0).toBe(true);
  });

  test("converts outbound IDR frame to Zalo PT 98", () => {
    const repacketizer = new WebrtcH264ToZaloRepacketizer();
    const output = repacketizer.processRtp(rtpPacket({
      pt: 102,
      seq: 20,
      ts: 12000,
      marker: true,
      payload: Buffer.from([0x65, 5, 6, 7]),
    }));
    expect(output).toHaveLength(1);
    expect(output[0]![1]! & 0x7f).toBe(98);
  });

  test("reassembles outbound standard FU-A and emits Zalo fragmented Annex-B", () => {
    const repacketizer = new WebrtcH264ToZaloRepacketizer();
    const nalBody = Buffer.alloc(1400, 7);
    const firstBody = nalBody.subarray(0, 700);
    const secondBody = nalBody.subarray(700);
    const first = Buffer.concat([Buffer.from([0x7c, 0x81]), firstBody]);
    const second = Buffer.concat([Buffer.from([0x7c, 0x41]), secondBody]);
    expect(repacketizer.processRtp(rtpPacket({
      pt: 102,
      seq: 30,
      ts: 15000,
      marker: false,
      payload: first,
    }))).toHaveLength(0);
    const output = repacketizer.processRtp(rtpPacket({
      pt: 102,
      seq: 31,
      ts: 15000,
      marker: true,
      payload: second,
    }));
    expect(output.length).toBeGreaterThan(1);
    expect(output[0]![1]! & 0x7f).toBe(97);
    expect(rtpPayload(output[0]!)[0]).toBe(0x1c);
    expect((rtpPayload(output[0]!)[1]! & 0x80) !== 0).toBe(true);
    expect((rtpPayload(output[0]!)[1]! & 0x40) === 0).toBe(true);
    expect((rtpPayload(output[output.length - 1]!)[1]! & 0x40) !== 0).toBe(true);
    expect((output[0]![1]! & 0x80) === 0).toBe(true);
    expect((output[output.length - 1]![1]! & 0x80) !== 0).toBe(true);
  });

  test("converts inbound complete Zalo Annex-B frame to standard H264 RTP", () => {
    const repacketizer = new ZaloH264ToWebrtcRepacketizer();
    const annexB = Buffer.concat([
      Buffer.from([0, 0, 0, 1, 0x67, 1]),
      Buffer.from([0, 0, 0, 1, 0x68, 2]),
      Buffer.from([0, 0, 0, 1, 0x65, 3, 4]),
    ]);
    const output = repacketizer.processRtp(rtpPacket({
      pt: 98,
      seq: 40,
      ts: 18000,
      marker: true,
      payload: annexB,
    }), 102);
    expect(output).toHaveLength(3);
    expect(output.every((packet) => (packet[1]! & 0x7f) === 102)).toBe(true);
    expect(rtpPayload(output[0]!)).toEqual(Buffer.from([0x67, 1]));
    expect(rtpPayload(output[1]!)).toEqual(Buffer.from([0x68, 2]));
    expect(rtpPayload(output[2]!)).toEqual(Buffer.from([0x65, 3, 4]));
    expect((output[0]![1]! & 0x80) === 0).toBe(true);
    expect((output[2]![1]! & 0x80) !== 0).toBe(true);
  });

  test("reassembles inbound Zalo custom fragments and emits standard FU-A", () => {
    const repacketizer = new ZaloH264ToWebrtcRepacketizer();
    const largeNal = Buffer.concat([Buffer.from([0x41]), Buffer.alloc(1300, 9)]);
    const annexB = Buffer.concat([Buffer.from([0, 0, 0, 1]), largeNal]);
    const firstChunk = annexB.subarray(0, 700);
    const secondChunk = annexB.subarray(700);
    const firstPayload = Buffer.concat([Buffer.from([0x1c, 0x80]), firstChunk]);
    const secondPayload = Buffer.concat([Buffer.from([0x1c, 0x40]), secondChunk]);
    expect(repacketizer.processRtp(rtpPacket({
      pt: 97,
      seq: 50,
      ts: 21000,
      marker: false,
      payload: firstPayload,
    }), 102)).toHaveLength(0);
    const output = repacketizer.processRtp(rtpPacket({
      pt: 97,
      seq: 51,
      ts: 21000,
      marker: true,
      payload: secondPayload,
    }), 102);
    expect(output.length).toBeGreaterThan(1);
    const firstOutPayload = rtpPayload(output[0]!);
    expect(firstOutPayload[0]! & 0x1f).toBe(28);
    expect(firstOutPayload[1]! & 0x1f).toBe(1);
    expect((firstOutPayload[1]! & 0x80) !== 0).toBe(true);
    const lastOutPayload = rtpPayload(output[output.length - 1]!);
    expect((lastOutPayload[1]! & 0x40) !== 0).toBe(true);
    expect((output[output.length - 1]![1]! & 0x80) !== 0).toBe(true);
  });
});
