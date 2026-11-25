export class ZaloApiError extends Error {
  readonly code: number | null;
  readonly raw?: unknown;

  constructor(message: string, code: number | null = null, raw?: unknown) {
    super(message);
    this.name = "ZaloApiError";
    this.code = code;
    this.raw = raw;
  }
}

export class ZaloNetworkError extends ZaloApiError {
  constructor(message: string, raw?: unknown) {
    super(message, null, raw);
    this.name = "ZaloNetworkError";
  }
}

export class ZaloProtocolError extends ZaloApiError {
  constructor(message: string, code: number | null = null, raw?: unknown) {
    super(message, code, raw);
    this.name = "ZaloProtocolError";
  }
}

export class ZaloCryptoError extends ZaloApiError {
  constructor(message: string, code: number | null = 18060, raw?: unknown) {
    super(message, code, raw);
    this.name = "ZaloCryptoError";
  }
}

export class ZaloCallError extends ZaloApiError {
  constructor(message: string, code: number | null = null, raw?: unknown) {
    super(message, code, raw);
    this.name = "ZaloCallError";
  }
}
