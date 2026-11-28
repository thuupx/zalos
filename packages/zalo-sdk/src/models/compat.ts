import type { ZaloCredentials } from "../core/context.ts";
import type { StickerDetail, UserInfo } from "./entities.ts";
import { FriendRecommendationsType, Gender, ReportReason } from "./enums.ts";
import type {
  TMessage,
  TypingEvent,
  UndoEvent,
  ZaloMessage,
  ZaloReaction,
} from "./events.ts";

// Event / listener aliases used by the server gateway
export type Message = ZaloMessage;
export type Reaction = ZaloReaction;
export type Typing = TypingEvent;
export type Undo = UndoEvent;

// SendMessage & report param aliases used by the server gateway
export interface SendMessageQuote {
  content: TMessage["content"];
  msgType: TMessage["msgType"];
  propertyExt?: TMessage["propertyExt"];
  uidFrom: TMessage["uidFrom"];
  msgId: TMessage["msgId"];
  cliMsgId: TMessage["cliMsgId"];
  ts: TMessage["ts"];
  ttl: TMessage["ttl"];
}

export type SendReportOptions =
  | { reason: ReportReason.Other; content: string }
  | { reason: Exclude<ReportReason, ReportReason.Other>; content?: string };

export interface SendSeenEventMessageParams {
  msgId: string;
  cliMsgId: string;
  uidFrom: string;
  idTo: string;
  msgType: string;
  st: number;
  at: number;
  cmd: number;
  ts: string | number;
}

export type StickerDetailResponse = StickerDetail;

export interface GetAliasListResponse {
  items: Array<{ userId: string; alias: string }>;
  updateTime?: string;
}

export type GetCloseFriendsResponse = UserInfo[];

export interface GetFriendOnlinesStatus {
  userId: string;
  status: string;
}

export interface GetFriendOnlinesResponse {
  predefine?: string[];
  ownerStatus?: string;
  onlines: GetFriendOnlinesStatus[];
}

export interface FriendRecommendationsDataInfo {
  userId: string;
  zaloName: string;
  displayName: string;
  avatar: string;
  phoneNumber?: string;
  status?: string;
  gender?: Gender;
  dob?: number;
  type?: number;
  recommType?: FriendRecommendationsType;
  recommSrc?: number;
  recommTime?: number;
  recommInfo?: {
    suggestWay?: number;
    source?: number;
    message?: string;
    customText?: string | null;
  };
  bizPkg?: Record<string, unknown>;
  isSeenFriendReq?: boolean;
  [key: string]: unknown;
}

export interface FriendRecommendationsRecommItem {
  recommItemType: number;
  dataInfo: FriendRecommendationsDataInfo;
}

export interface GetFriendRecommendationsResponse {
  expiredDuration?: number;
  collapseMsgListConfig?: Record<string, number>;
  recommItems: FriendRecommendationsRecommItem[];
}

export interface GetFriendRequestStatusResponse {
  addFriendPrivacy?: number;
  isSeenFriendReq?: boolean;
  is_friend: number;
  is_requested: number;
  is_requesting: number;
}

export interface GetGroupLinkInfoResponse {
  groupId: string;
  name: string;
  desc?: string;
  type?: number;
  creatorId: string;
  avt?: string;
  fullAvt?: string;
  adminIds?: string[];
  currentMems?: Array<{
    id: string;
    dName: string;
    zaloName?: string;
    avatar?: string;
    avatar_25?: string;
    accountStatus?: number;
    type?: number;
    [key: string]: unknown;
  }>;
  admins?: unknown[];
  hasMoreMember?: number;
  subType?: number;
  totalMember?: number;
  setting?: Record<string, unknown>;
  globalId?: string;
  [key: string]: unknown;
}

export interface SentFriendRequestInfo {
  userId: string;
  zaloName?: string;
  displayName?: string;
  avatar?: string;
  globalId?: string;
  bizPkg?: Record<string, unknown>;
  fReqInfo?: {
    message?: string;
    src?: number;
    time?: number;
  };
  [key: string]: unknown;
}

export type GetSentFriendRequestResponse = Record<string, SentFriendRequestInfo>;

export interface LastOnlineResponse {
  settings?: {
    show_online_status?: boolean;
    [key: string]: unknown;
  };
  lastOnline: number;
}

export type Credentials = ZaloCredentials;
