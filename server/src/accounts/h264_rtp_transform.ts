export const ZALO_H264_DELTA_PT = 97;
export const ZALO_H264_KEYFRAME_PT = 98;

const START_CODE = Buffer.from([0, 0, 0, 1]);
const ZALO_MAX_PAYLOAD_SIZE = 1000;
const WEBRTC_MAX_PAYLOAD_SIZE = 1000;

interface ParsedRtpPacket {
  marker: boolean;
  payloadType: number;
  sequenceNumber: number;
  timestamp: number;
  ssrc: number;
  payload: Buffer;
}

function parseRtpPacket(rawRtp: Uint8Array): ParsedRtpPacket | null {
  if (rawRtp.length < 12) return null;
  const first = rawRtp[0]!;
  if ((first & 0xc0) !== 0x80) return null;
  const view = new DataView(rawRtp.buffer, rawRtp.byteOffset, rawRtp.byteLength);
  const csrcCount = first & 0x0f;
  const hasPadding = (first & 0x20) !== 0;
  const hasExtension = (first & 0x10) !== 0;
  let payloadOffset = 12 + csrcCount * 4;
  if (payloadOffset > rawRtp.length) return null;
  if (hasExtension) {
    if (payloadOffset + 4 > rawRtp.length) return null;
    const extensionLengthWords = view.getUint16(payloadOffset + 2, false);
    payloadOffset += 4 + extensionLengthWords * 4;
    if (payloadOffset > rawRtp.length) return null;
  }
  let payloadEnd = rawRtp.length;
  if (hasPadding) {
    const paddingLength = rawRtp[rawRtp.length - 1]!;
    if (paddingLength === 0 || paddingLength > payloadEnd - payloadOffset) return null;
    payloadEnd -= paddingLength;
  }
  return {
    marker: (rawRtp[1]! & 0x80) !== 0,
    payloadType: rawRtp[1]! & 0x7f,
    sequenceNumber: view.getUint16(2, false),
    timestamp: view.getUint32(4, false),
    ssrc: view.getUint32(8, false),
    payload: Buffer.from(rawRtp.subarray(payloadOffset, payloadEnd)),
  };
}

function buildRtpPacket(opts: {
  payloadType: number;
  sequenceNumber: number;
  timestamp: number;
  ssrc: number;
  marker: boolean;
  payload: Buffer;
}): Buffer {
  const out = Buffer.alloc(12 + opts.payload.length);
  out[0] = 0x80;
  out[1] = (opts.marker ? 0x80 : 0) | (opts.payloadType & 0x7f);
  out.writeUInt16BE(opts.sequenceNumber & 0xffff, 2);
  out.writeUInt32BE(opts.timestamp >>> 0, 4);
  out.writeUInt32BE(opts.ssrc >>> 0, 8);
  opts.payload.copy(out, 12);
  return out;
}

function annexBStartCodeLengthAt(data: Buffer, index: number): number {
  if (
    index + 4 <= data.length &&
    data[index] === 0 &&
    data[index + 1] === 0 &&
    data[index + 2] === 0 &&
    data[index + 3] === 1
  ) {
    return 4;
  }
  if (
    index + 3 <= data.length &&
    data[index] === 0 &&
    data[index + 1] === 0 &&
    data[index + 2] === 1
  ) {
    return 3;
  }
  return 0;
}

export function startsWithAnnexBStartCode(data: Buffer): boolean {
  return annexBStartCodeLengthAt(data, 0) !== 0;
}

export function stripLeadingAnnexBStartCode(data: Buffer): Buffer {
  const len = annexBStartCodeLengthAt(data, 0);
  return len === 0 ? data : data.subarray(len);
}

export function splitAnnexBNals(data: Buffer): Buffer[] {
  const starts: Array<{ index: number; length: number }> = [];
  for (let i = 0; i + 3 <= data.length; i++) {
    const len = annexBStartCodeLengthAt(data, i);
    if (len !== 0) {
      starts.push({ index: i, length: len });
      i += len - 1;
    }
  }
  if (starts.length === 0) {
    return data.length > 0 ? [Buffer.from(data)] : [];
  }
  const out: Buffer[] = [];
  for (let i = 0; i < starts.length; i++) {
    const start = starts[i]!;
    const nalStart = start.index + start.length;
    const nalEnd = i + 1 < starts.length ? starts[i + 1]!.index : data.length;
    if (nalEnd > nalStart) {
      out.push(Buffer.from(data.subarray(nalStart, nalEnd)));
    }
  }
  return out;
}

function parseStapA(payload: Buffer): Buffer[] {
  const nals: Buffer[] = [];
  let offset = 1;
  while (offset + 2 <= payload.length) {
    const nalSize = payload.readUInt16BE(offset);
    offset += 2;
    if (nalSize <= 0 || offset + nalSize > payload.length) break;
    nals.push(Buffer.from(payload.subarray(offset, offset + nalSize)));
    offset += nalSize;
  }
  return nals;
}

function makeEvenChunks(data: Buffer, maxChunkSize: number): Buffer[] {
  if (data.length <= maxChunkSize) return [Buffer.from(data)];
  const count = Math.ceil(data.length / maxChunkSize);
  const chunks: Buffer[] = [];
  let offset = 0;
  for (let i = 0; i < count; i++) {
    const remainingBytes = data.length - offset;
    const remainingPackets = count - i;
    const chunkLength = Math.ceil(remainingBytes / remainingPackets);
    chunks.push(Buffer.from(data.subarray(offset, offset + chunkLength)));
    offset += chunkLength;
  }
  return chunks;
}

function nextSequence(current: number | null, initial?: number): number {
  if (current === null) {
    return (initial ?? 0) & 0xffff;
  }
  return (current + 1) & 0xffff;
}

export class WebrtcH264ToZaloRepacketizer {
  private outputSequence: number | null = null;
  private currentTimestamp: number | null = null;
  private accessUnitNals: Buffer[] = [];
  private fuNalHeader = 0;
  private fuFragments: Buffer[] = [];
  private spsNal: Buffer | null = null;
  private ppsNal: Buffer | null = null;

  processRtp(rawRtp: Uint8Array): Buffer[] {
    const pkt = parseRtpPacket(rawRtp);
    if (!pkt || pkt.payload.length === 0) return [];
    if (this.currentTimestamp !== null && pkt.timestamp !== this.currentTimestamp) {
      this.resetAccessUnit();
    }
    this.currentTimestamp = pkt.timestamp;
    this.ingestWebrtcPayload(pkt.payload);
    if (!pkt.marker) return [];
    return this.flushAccessUnit(pkt);
  }

  private resetAccessUnit(): void {
    this.currentTimestamp = null;
    this.accessUnitNals = [];
    this.fuNalHeader = 0;
    this.fuFragments = [];
  }

  private ingestWebrtcPayload(payload: Buffer): void {
    const nalType = payload[0]! & 0x1f;
    if (nalType >= 1 && nalType <= 23) {
      this.addNal(payload);
      return;
    }
    if (nalType === 24) {
      for (const nal of parseStapA(payload)) this.addNal(nal);
      return;
    }
    if (nalType !== 28 || payload.length < 2) return;

    const fuIndicator = payload[0]!;
    const fuHeader = payload[1]!;
    const isStart = (fuHeader & 0x80) !== 0;
    const isEnd = (fuHeader & 0x40) !== 0;
    const originalNalType = fuHeader & 0x1f;
    const body = payload.subarray(2);
    if (isStart) {
      this.fuNalHeader = (fuIndicator & 0xe0) | originalNalType;
      this.fuFragments = [Buffer.from(body)];
    } else if (this.fuFragments.length > 0 && this.fuFragments.length < 512) {
      this.fuFragments.push(Buffer.from(body));
    }
    if (isEnd && this.fuFragments.length > 0) {
      const nal = Buffer.concat([Buffer.from([this.fuNalHeader]), ...this.fuFragments]);
      this.fuNalHeader = 0;
      this.fuFragments = [];
      this.addNal(nal);
    }
  }

  private addNal(rawNal: Buffer): void {
    const nal = stripLeadingAnnexBStartCode(rawNal);
    if (nal.length === 0) return;
    const nalType = nal[0]! & 0x1f;
    if (nalType === 0 || nalType === 9) return;
    if (nalType === 7) this.spsNal = Buffer.from(nal);
    if (nalType === 8) this.ppsNal = Buffer.from(nal);
    if (this.accessUnitNals.length < 256) {
      this.accessUnitNals.push(Buffer.from(nal));
    }
  }

  private flushAccessUnit(pkt: ParsedRtpPacket): Buffer[] {
    const nals = this.accessUnitNals;
    this.resetAccessUnit();
    if (nals.length === 0) return [];
    const types = nals.map((nal) => nal[0]! & 0x1f);
    if (!types.some((type) => type === 1 || type === 5)) return [];
    const hasIdr = types.includes(5);
    const outputNals: Buffer[] = [];
    if (hasIdr) {
      if (!types.includes(7) && this.spsNal) outputNals.push(this.spsNal);
      if (!types.includes(8) && this.ppsNal) outputNals.push(this.ppsNal);
    }
    outputNals.push(...nals);

    const annexBParts: Buffer[] = [];
    for (const nal of outputNals) {
      annexBParts.push(START_CODE, nal);
    }
    const annexB = Buffer.concat(annexBParts);
    const payloads: Buffer[] = [];
    if (annexB.length <= ZALO_MAX_PAYLOAD_SIZE) {
      payloads.push(annexB);
    } else {
      for (const [index, chunk] of makeEvenChunks(annexB, ZALO_MAX_PAYLOAD_SIZE).entries()) {
        const payload = Buffer.alloc(2 + chunk.length);
        payload[0] = 0x1c;
        payload[1] = (index === 0 ? 0x80 : 0) | (index === Math.ceil(annexB.length / ZALO_MAX_PAYLOAD_SIZE) - 1 ? 0x40 : 0);
        chunk.copy(payload, 2);
        payloads.push(payload);
      }
    }

    const payloadType = hasIdr ? ZALO_H264_KEYFRAME_PT : ZALO_H264_DELTA_PT;
    return payloads.map((payload, index) => {
      this.outputSequence = nextSequence(this.outputSequence, pkt.sequenceNumber);
      return buildRtpPacket({
        payloadType,
        sequenceNumber: this.outputSequence,
        timestamp: pkt.timestamp,
        ssrc: pkt.ssrc,
        marker: index === payloads.length - 1,
        payload,
      });
    });
  }
}

export class ZaloH264ToWebrtcRepacketizer {
  private outputSequence: number | null = null;
  private currentTimestamp: number | null = null;
  private accessUnitNals: Buffer[] = [];
  private fuFragments: Buffer[] = [];
  private spsNal: Buffer | null = null;
  private ppsNal: Buffer | null = null;

  processRtp(rawRtp: Uint8Array, targetPayloadType: number): Buffer[] {
    const pkt = parseRtpPacket(rawRtp);
    if (!pkt || pkt.payload.length === 0) return [];
    if (this.currentTimestamp !== null && pkt.timestamp !== this.currentTimestamp) {
      this.resetAccessUnit();
    }
    this.currentTimestamp = pkt.timestamp;
    this.ingestZaloPayload(pkt.payload);
    if (!pkt.marker) return [];
    return this.flushAccessUnit(pkt, targetPayloadType);
  }

  private resetAccessUnit(): void {
    this.currentTimestamp = null;
    this.accessUnitNals = [];
    this.fuFragments = [];
  }

  private ingestZaloPayload(payload: Buffer): void {
    if (startsWithAnnexBStartCode(payload)) {
      for (const nal of splitAnnexBNals(payload)) this.addNal(nal);
      return;
    }
    const nalType = payload[0]! & 0x1f;
    if (nalType >= 1 && nalType <= 23) {
      for (const nal of splitAnnexBNals(payload)) this.addNal(nal);
      return;
    }
    if (nalType === 24) {
      for (const nal of parseStapA(payload)) this.addNal(nal);
      return;
    }
    if ((nalType !== 28 && nalType !== 29) || payload.length < 2) return;

    const fuIndicator = payload[0]!;
    const fuHeader = payload[1]!;
    const isStart = (fuHeader & 0x80) !== 0;
    const isEnd = (fuHeader & 0x40) !== 0;
    const originalNalType = fuHeader & 0x1f;
    const headerSize = nalType === 29 ? 4 : 2;
    if (payload.length <= headerSize) return;
    const body = payload.subarray(headerSize);
    if (isStart) {
      if (originalNalType === 0 || startsWithAnnexBStartCode(body)) {
        this.fuFragments = [Buffer.from(body)];
      } else {
        const reconstructedNalHeader = (fuIndicator & 0xe0) | originalNalType;
        this.fuFragments = [Buffer.from([reconstructedNalHeader]), Buffer.from(body)];
      }
    } else if (this.fuFragments.length > 0 && this.fuFragments.length < 512) {
      this.fuFragments.push(Buffer.from(body));
    }
    if (isEnd && this.fuFragments.length > 0) {
      const fullNalOrAnnexB = Buffer.concat(this.fuFragments);
      this.fuFragments = [];
      for (const nal of splitAnnexBNals(fullNalOrAnnexB)) this.addNal(nal);
    }
  }

  private addNal(rawNal: Buffer): void {
    const nal = stripLeadingAnnexBStartCode(rawNal);
    if (nal.length === 0) return;
    const nalType = nal[0]! & 0x1f;
    if (nalType === 0 || nalType === 9) return;
    if (nalType === 7) this.spsNal = Buffer.from(nal);
    if (nalType === 8) this.ppsNal = Buffer.from(nal);
    if (this.accessUnitNals.length < 256) {
      this.accessUnitNals.push(Buffer.from(nal));
    }
  }

  private flushAccessUnit(pkt: ParsedRtpPacket, targetPayloadType: number): Buffer[] {
    const nals = this.accessUnitNals;
    this.resetAccessUnit();
    if (nals.length === 0) return [];
    const types = nals.map((nal) => nal[0]! & 0x1f);
    if (!types.some((type) => type === 1 || type === 5)) return [];
    const outputNals: Buffer[] = [];
    if (types.includes(5)) {
      if (!types.includes(7) && this.spsNal) outputNals.push(this.spsNal);
      if (!types.includes(8) && this.ppsNal) outputNals.push(this.ppsNal);
    }
    outputNals.push(...nals);

    const payloads: Buffer[] = [];
    for (const nal of outputNals) {
      if (nal.length <= WEBRTC_MAX_PAYLOAD_SIZE) {
        payloads.push(Buffer.from(nal));
        continue;
      }
      const nalHeader = nal[0]!;
      const nalType = nalHeader & 0x1f;
      const fuIndicator = (nalHeader & 0xe0) | 28;
      const maxFragmentBytes = WEBRTC_MAX_PAYLOAD_SIZE - 2;
      const encodedBody = nal.subarray(1);
      const fragments = makeEvenChunks(encodedBody, maxFragmentBytes);
      for (const [index, fragment] of fragments.entries()) {
        const payload = Buffer.alloc(2 + fragment.length);
        payload[0] = fuIndicator;
        payload[1] = (index === 0 ? 0x80 : 0) | (index === fragments.length - 1 ? 0x40 : 0) | nalType;
        fragment.copy(payload, 2);
        payloads.push(payload);
      }
    }

    return payloads.map((payload, index) => {
      this.outputSequence = nextSequence(this.outputSequence, pkt.sequenceNumber);
      return buildRtpPacket({
        payloadType: targetPayloadType,
        sequenceNumber: this.outputSequence,
        timestamp: pkt.timestamp,
        ssrc: pkt.ssrc,
        marker: index === payloads.length - 1,
        payload,
      });
    });
  }
}
