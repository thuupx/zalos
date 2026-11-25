import type { SendMessageQuote } from "./compat.ts";

export interface StyleRun {
  start: number;
  len: number;
  st: string;
  indentSize?: number;
}

export interface MentionInput {
  pos: number;
  uid: string;
  len: number;
}

export interface AttachmentSourceBuffer {
  data: Buffer | Uint8Array;
  filename: string;
  metadata?: {
    totalSize: number;
    width?: number;
    height?: number;
  };
}

export type AttachmentSource = string | AttachmentSourceBuffer;

export interface MessageContentInput {
  msg: string;
  styles?: StyleRun[];
  urgency?: number;
  quote?: SendMessageQuote | Record<string, unknown>;
  mentions?: MentionInput[];
  attachments?: AttachmentSource | AttachmentSource[];
  ttl?: number;
}

export type AttachmentUploadResult =
  | {
      fileType: "image";
      photoId: string;
      normalUrl?: string;
      hdUrl?: string;
      thumbUrl?: string;
      finished?: number;
      width: number;
      height: number;
      totalSize: number;
      fileName: string;
      checksum?: string;
      clientFileId: number;
    }
  | {
      fileType: "video" | "others";
      fileId: string;
      fileUrl: string;
      totalSize: number;
      fileName: string;
      checksum?: string;
      clientFileId: number;
    };

export interface UserInfo {
  userId: string;
  username?: string;
  displayName: string;
  zaloName?: string;
  avatar: string;
  bgavatar?: string;
  cover?: string;
  gender?: number;
  dob?: number;
  sdob?: string;
  status?: string;
  phoneNumber?: string;
  isFr?: number;
  isBlocked?: number;
  lastActionTime?: number;
  lastUpdateTime?: number;
  isActive?: number;
  key?: number;
  type?: number;
  isActivePC?: number;
  isActiveWeb?: number;
  isValid?: number;
  userKey?: string;
  accountStatus?: number;
  bizPkg?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface GroupInfo {
  groupId: string;
  name: string;
  desc?: string;
  type?: number;
  creatorId: string;
  version?: string;
  avt: string;
  fullAvt?: string;
  memberIds?: string[];
  adminIds?: string[];
  currentMems?: Array<Record<string, unknown>>;
  updateMems?: Array<Record<string, unknown>>;
  memVerList?: string[];
  admins?: string[];
  hasMoreMember?: number;
  subType?: number;
  totalMember?: number;
  maxMember?: number;
  setting?: Record<string, unknown>;
  createdTime?: number;
  visibility?: number;
  globalId?: string;
  pendingApprove?: {
    time: number;
    uids: string[] | null;
  };
  [key: string]: unknown;
}

export interface PollOption {
  content: string;
  votes: number;
  voted: boolean;
  option_id: number;
}

export interface PollDetail {
  creator: string;
  question: string;
  options: PollOption[];
  joined: boolean;
  closed: boolean;
  poll_id: number;
  allow_multi_choices: boolean;
  allow_add_new_option: boolean;
  is_anonymous: boolean;
  is_hide_vote_preview: boolean;
  poll_type: number;
  created_time: number;
  updated_time: number;
  expired_time: number;
  [key: string]: unknown;
}

export interface PinTopic {
  topicId: string | number;
  topicType?: number;
  creatorId?: string;
  createTime?: number;
  editorId?: string;
  editTime?: number;
  color?: number;
  emoji?: string;
  duration?: number;
  startTime?: number;
  repeat?: number;
  params?: string | Record<string, unknown>;
  [key: string]: unknown;
}

export interface StickerDetail {
  id: number;
  cateId: number;
  type: number;
  text?: string;
  uri?: string;
  fkey?: number;
  status?: number;
  stickerUrl?: string;
  stickerSpriteUrl?: string;
  stickerWebpUrl?: string | null;
  totalFrames?: number;
  duration?: number;
  effectId?: number;
  checksum?: string;
  ext?: number;
  source?: number;
  [key: string]: unknown;
}

export interface LabelData {
  id: number;
  text: string;
  textKey: string;
  conversations: string[];
  color: string;
  offset: number;
  emoji: string;
  createTime: number;
}

export interface QuickMessage {
  id: number;
  keyword: string;
  message: {
    title: string;
    params: string | null;
  };
  type: number;
  createdTime?: number;
  lastModified?: number;
  isEnable?: boolean;
  media?: unknown;
}

export interface AutoReplyItem {
  id: number;
  weight?: number;
  enable: boolean;
  modifiedTime?: number;
  startTime: number;
  endTime: number;
  content: string;
  scope: number;
  uids: string[] | null;
  recurrence: string[];
}

export interface BankInfo {
  bin: string;
  name: string;
  shortName: string;
  vnName?: string;
  enName?: string;
  logo?: string;
  [key: string]: unknown;
}

export interface BankAccount {
  id?: string | number;
  bin: string;
  bank_number: string;
  holder_name: string;
  is_default?: number | boolean;
  [key: string]: unknown;
}

export interface LinkedDevice {
  deviceId?: string;
  deviceName?: string;
  deviceType?: number;
  os?: string;
  lastActiveTime?: number;
  [key: string]: unknown;
}

export interface MediaStoreItem {
  msgId?: string;
  cliMsgId?: string;
  url?: string;
  thumbUrl?: string;
  type?: string;
  title?: string;
  fileSize?: number;
  createdTime?: number;
  [key: string]: unknown;
}
