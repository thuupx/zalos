import type { ClientProfile, ClientProfileName } from "./constants.ts";
import type { CookieInput, ZaloCookieJar } from "./cookies.ts";

export interface ImageMetadata {
  width: number;
  height: number;
  size?: number;
}

export type ImageMetadataGetter = (
  filePath: string,
) => Promise<ImageMetadata | undefined> | ImageMetadata | undefined;

export type UploadCallback = (data: Record<string, unknown>) => void;

export type FetchLike = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export interface ZaloOptions {
  /** Emit events sent by the logged-in account itself (default true). */
  selfListen?: boolean;
  /** Suppress noisy warnings / check updates (default false). */
  checkUpdate?: boolean;
  /** Console logging toggle (default false). */
  logging?: boolean;
  /** Client wire profile ("web" matches Zalo Web / zca-js, "pc_macos" / "pc_windows" match Zalo PC). */
  profile?: ClientProfileName;
  /** Override fetch implementation (e.g., offline mock router or custom TLS helper). */
  polyfill?: FetchLike;
  /** Custom image dimension/size reader. */
  imageMetadataGetter?: ImageMetadataGetter;
  /** Override computer name sent in login/server info requests. */
  computerName?: string;
  /** API type override (default 30 for web, 23 for PC). */
  apiType?: number;
  /** API version override (default 685 for web, 694 for PC). */
  apiVersion?: number;
  /** Language code (default "vi"). */
  language?: string;
}

export interface ZaloCredentials {
  imei: string;
  cookie: CookieInput;
  userAgent?: string;
  language?: string;
}

export type ServiceMap = Record<string, string[]>;

export interface ZaloContext {
  uid: string;
  imei: string;
  userAgent: string;
  language: string;
  secretKey: string;
  cookie: ZaloCookieJar;
  profile: ClientProfile;
  apiType: number;
  apiVersion: number;
  computerName: string;
  settings: Record<string, unknown>;
  extraVer: Record<string, unknown>;
  zpwServiceMap: ServiceMap;
  wsUrls: string[];
  uploadCallbacks: Map<string, UploadCallback>;
  options: Required<Pick<ZaloOptions, "selfListen" | "checkUpdate" | "logging">>;
  imageMetadataGetter?: ImageMetadataGetter;
}
