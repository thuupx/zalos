// JSON message shapes on a channel: request / response / event.
export class RpcError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export type JsonRequest = { id: number; method: string; params?: unknown };
export type JsonResponse =
  | { id: number; result: unknown }
  | { id: number; error: { code: string; message: string } };
export type JsonEvent = { event: string; seq?: number; data?: unknown };

export function encode(obj: object): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(obj));
}

export function decode(data: Uint8Array): unknown {
  return JSON.parse(new TextDecoder().decode(data));
}
