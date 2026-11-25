import type { FriendEventType, GroupEventType, LoginQRCallbackEventType, ThreadType } from "./enums.ts";

export interface TAttachmentContent {
  title?: string;
  description?: string;
  href?: string;
  thumb?: string;
  params?: string;
  type?: string;
  id?: string;
  catId?: string;
  action?: string;
  [key: string]: unknown;
}

export interface TMention {
  uid: string;
  pos: number;
  len: number;
  type: 0 | 1;
}

export interface TQuote {
  ownerId: string;
  cliMsgId: string | number;
  globalMsgId: string | number;
  cliMsgType: number;
  ts: string | number;
  msg: string;
  attach: string;
  fromD: string;
  ttl: number;
}

export interface TMessage {
  actionId?: string;
  msgId: string;
  cliMsgId: string;
  msgType: string;
  uidFrom: string;
  idTo: string;
  dName?: string;
  ts: string;
  status?: number;
  content: string | TAttachmentContent;
  notify?: string;
  ttl?: number;
  uin?: string;
  userId?: string;
  cmd?: number;
  st?: number;
  at?: number;
  realMsgId?: string;
  quote?: TQuote;
  mentions?: TMention[];
  propertyExt?: Record<string, unknown>;
  paramsExt?: Record<string, unknown>;
  logSrcType?: number;
  fwLvl?: number;
  [key: string]: unknown;
}

export interface UserMessage {
  type: ThreadType.User;
  threadId: string;
  isSelf: boolean;
  data: TMessage;
}

export interface GroupMessage {
  type: ThreadType.Group;
  threadId: string;
  isSelf: boolean;
  data: TMessage;
}

export type ZaloMessage = UserMessage | GroupMessage;

export interface TReaction {
  actionId: string;
  msgId: string;
  cliMsgId: string;
  msgType: string;
  uidFrom: string;
  idTo: string;
  dName?: string;
  content: {
    rMsg: Array<{ gMsgID: string; cMsgID: string; msgType: number }>;
    rIcon: string;
    rType: number;
    source: number;
  };
  ts: string;
  msgSender: string;
  [key: string]: unknown;
}

export interface ZaloReaction {
  type: ThreadType;
  threadId: string;
  isSelf: boolean;
  isGroup: boolean;
  data: TReaction;
}

export interface SeenMessage {
  type: ThreadType;
  threadId: string;
  isSelf: boolean;
  data: {
    idTo: string;
    msgSender: string;
    msgId?: string;
    cliMsgId?: string;
    seenUids?: string[];
    realMsgId?: string;
    lastSeenTime?: number;
    [key: string]: unknown;
  };
}

export interface DeliveredMessage {
  type: ThreadType;
  threadId: string;
  isSelf: boolean;
  data: {
    deliveredUids: string[];
    seenUids?: string[];
    mIds?: string[];
    realMsgId?: string;
    groupId?: string;
    idTo?: string;
    [key: string]: unknown;
  };
}

export interface TypingEvent {
  type: ThreadType;
  threadId: string;
  isSelf: boolean;
  data: {
    uid: string;
    gid?: string;
    ts: string;
    isPC?: number;
    [key: string]: unknown;
  };
}

export interface UndoEvent {
  type: ThreadType;
  threadId: string;
  isSelf: boolean;
  isGroup: boolean;
  data: TMessage & {
    content: {
      globalMsgId: string | number;
      cliMsgId: string | number;
      deleteMsg: number;
      srcId?: string;
      destId?: string;
      [key: string]: unknown;
    };
  };
}

export interface GroupEvent {
  type: GroupEventType;
  threadId: string;
  act?: string;
  data: Record<string, unknown>;
  isSelf?: boolean;
}

export interface FriendEvent {
  type: FriendEventType;
  threadId: string;
  act?: string;
  data: unknown;
  isSelf?: boolean;
}

export interface ControlItem {
  controlId?: string;
  content: {
    act_type: string;
    act?: string;
    data?: unknown;
    fileId?: string;
    ts?: string | number;
    action?: string;
    [key: string]: unknown;
  };
}

export interface ActionItem {
  act_type: string;
  act: string;
  data: unknown;
  [key: string]: unknown;
}

export interface VoipControlEvent {
  actType: "voip";
  act: string;
  ts: number;
  conversationId?: string;
  callerId?: string;
  groupId?: string;
  inCallStatus: "zalo" | null;
  data: Record<string, unknown>;
  raw: ControlItem["content"];
}

export interface E2eeEvent {
  cmd: number;
  subCmd: number;
  data: unknown;
}

export interface CallLogPayload {
  isEnableCallback?: number;
  calltype: 0 | 1;
  isCaller: 0 | 1;
  duration: number;
  reason?: number;
}

export interface ZCallServerEndpoint {
  rtpaddr: string;
  rtcpaddr: string;
}

export interface ZCallServerConfig {
  fromId?: number | string;
  toId?: number | string;
  protocol?: number;
  status?: number;
  sessId?: string;
  rtpIP?: string;
  rtcpIP?: string;
  servers?: ZCallServerEndpoint[];
  changeZRTP?: { enable: number; threshold: number };
  fec?: { enable: number; tableLookup: number[][] };
  settings?: Record<string, unknown>;
  nativeCallPopup?: Record<string, unknown>;
  zrtc_config?: Record<string, unknown>;
  [key: string]: unknown;
}

export type LoginQRCallbackEvent =
  | {
      type: LoginQRCallbackEventType.QRCodeGenerated;
      data: { code: string; image: string; options: Record<string, unknown>; tokenId?: string };
      actions: { saveToFile: (path?: string) => Promise<void>; retry: () => void; abort: () => void };
    }
  | {
      type: LoginQRCallbackEventType.QRCodeExpired;
      data: null;
      actions: { retry: () => void; abort: () => void };
    }
  | {
      type: LoginQRCallbackEventType.QRCodeScanned;
      data: { avatar: string; display_name: string; [key: string]: unknown };
      actions: { retry: () => void; abort: () => void };
    }
  | {
      type: LoginQRCallbackEventType.QRCodeDeclined;
      data: { code: string; [key: string]: unknown };
      actions: { retry: () => void; abort: () => void };
    }
  | {
      type: LoginQRCallbackEventType.GotLoginInfo;
      data: {
        cookie: unknown;
        imei: string;
        userAgent: string;
        uid?: string;
        zpw_kt?: string;
      };
      actions: null;
    };
