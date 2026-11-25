export type ClientProfileName = "web" | "pc_macos" | "pc_windows";

export interface ClientProfile {
  readonly name: ClientProfileName;
  readonly apiType: number;
  readonly apiVersion: number;
  readonly computerName: string;
  readonly userAgent: string;
  readonly authDomain: string;
  readonly origin?: string;
  readonly referer?: string;
  readonly wsOrigin: string;
  readonly secChUa?: string;
  readonly secChUaPlatform?: string;
}

export const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0";

export const CLIENT_PROFILES: Record<ClientProfileName, ClientProfile> = {
  web: {
    name: "web",
    apiType: 30,
    apiVersion: 685,
    computerName: "Web",
    userAgent: DEFAULT_USER_AGENT,
    authDomain: "https://wpa.chat.zalo.me",
    origin: "https://chat.zalo.me",
    referer: "https://chat.zalo.me/",
    wsOrigin: "https://chat.zalo.me",
  },
  pc_macos: {
    name: "pc_macos",
    apiType: 23,
    apiVersion: 694,
    computerName: "MacBook",
    userAgent: "ZaloPC-darwin-23v694",
    authDomain: "https://wpa.zaloapp.com",
    wsOrigin: "file://",
    secChUa: '"Not?A_Brand";v="8", "Chromium";v="108"',
    secChUaPlatform: '"macOS"',
  },
  pc_windows: {
    name: "pc_windows",
    apiType: 23,
    apiVersion: 694,
    computerName: "Desktop",
    userAgent: "ZaloPC-win32-23v694",
    authDomain: "https://wpa.zaloapp.com",
    wsOrigin: "file://",
    secChUa: '"Not?A_Brand";v="8", "Chromium";v="108"',
    secChUaPlatform: '"Windows"',
  },
};

export const PARAM_CIPHER_KEY = "3FC4F0D2AB50057BCE0D90D9187A22B1";
export const PASSWORD_CIPHER_KEY = "9fc5vEW3";
export const ZCALL_V2_IPC_AES_KEY_B64 = "yjAF9oqMWl6XfXYJn9mA7w==";

export const SERVICE_MAP_KEYS = [
  "aext",
  "ai_features",
  "alias",
  "auto_reply",
  "backuppcmobile",
  "banner",
  "boards",
  "catalog",
  "chat",
  "chat_e2e",
  "consent",
  "conversation",
  "emoji_stt",
  "fallback_LP",
  "file",
  "friend",
  "friendLan",
  "friend_board",
  "group",
  "group_board",
  "group_cloud_message",
  "group_e2e",
  "group_poll",
  "label",
  "maintenance",
  "media_store",
  "media_store_send2me",
  "other_contact",
  "profile",
  "push_act",
  "qr_code",
  "quick_message",
  "reaction",
  "recent_search",
  "sp_contact",
  "sticker",
  "sync_action",
  "up_file",
  "voice_call",
  "zalo_dev",
  "zalo_dev_v2",
  "zalo_dev_v3",
  "zcloud",
  "zcloud_up_file",
  "zfamily",
  "zimsg",
] as const;

export type ServiceMapKey = (typeof SERVICE_MAP_KEYS)[number] | (string & {});

export const DEFAULT_SERVICE_DOMAINS: Readonly<Record<string, readonly string[]>> = {
  aext: ["https://aextra-wpa.chat.zalo.me"],
  backuppcmobile: ["https://bkpc2mb.zaloapp.com"],
  consent: ["https://consent.zalo.me"],
  maintenance: ["https://maint.chat.zalo.me"],
  profile: ["https://profile-wpa.zaloapp.com"],
  voice_call: ["https://voicecall-wpa.zaloapp.com"],
  zalo_dev: ["https://dev-wpa.chat.zalo.me"],
  zalo_dev_v2: ["https://staging-pcweb-wpa.chat.zalo.me"],
  zalo_dev_v3: ["https://stg-wpa.chat.zalo.me"],
  zcloud: ["https://zcld.chat.zalo.me"],
  zfamily: ["https://zfml.chat.zalo.me"],
  zimsg: ["https://zimsg.chat.zalo.me"],
};

export const QOS_UPLOAD_CALL_LOG_URL = "https://qos.talk.zing.vn/api/qos/uploadcalllog";

/**
 * Complete table of Zalo WebSocket binary protocol commands.
 */
export const WS_CMD = {
  AUTHEN: 1,
  PING: 2,
  PING_ACTIVE: 4,
  MAX_CONNECTION: 3000,

  // Messaging & receipts
  PUSH_MSG_1_1: 501,
  PUSH_STATUS_1_1: 502,
  CLEAR_UNREADS_1_1: 504,
  OFFLINE_MSG_1_1: 510,
  OFFLINE_MSG_GROUP: 511,
  OFFLINE_MSG_E2EE_PC: 513,
  OFFLINE_MSG_E2EE_GROUP: 514,
  OFFLINE_MSG_E2EE_WEB: 515,
  E2EE_SESSION_OFFLINE: 516,
  E2EE_SESSION_OFFLINE_WEB: 517,
  E2EE_OFFLINE_ACK_1_1: 518,
  E2EE_OFFLINE_ACK_GROUP: 519,
  PUSH_MSG_GROUP: 521,
  PUSH_STATUS_GROUP: 522,
  CLEAR_UNREADS_GROUP: 524,
  PUSH_INTERACTIVE_FILE: 530,
  VERIFY_MSG: 532,
  HAS_MSG: 533,
  PUSH_MISS_MSG: 534,
  E2EE_PUSH_MISS: 535,
  SUBMIT_INTERACTIVE_FILE: 536,
  PULL_INTERACTIVE_FILE: 537,

  // Signal E2EE
  E2EE_SUBMIT_BUNDLE: 540,
  E2EE_GET_BUNDLE: 541,
  E2EE_SUBMIT_PREKEYS: 542,
  E2EE_INIT_SESSION: 543,
  E2EE_ACK_INIT_SESSION: 544,
  E2EE_DONE_PROCESS_SESSION: 545,
  E2EE_ACK_GROUP_STALE: 546,
  E2EE_DELETE_KEY: 547,
  E2EE_NOTIFY_DELETE_KEY: 548,
  E2EE_REQUEST_PREKEYS: 549,
  E2EE_SUBDEVICE_UNSUPPORT: 550,
  E2EE_MSG_RECEIVE_1_1: 551,
  E2EE_MSG_RECEIVE_GROUP: 552,
  E2EE_ACK_DELIVER_SEEN_1_1: 553,
  E2EE_ACK_DELIVER_SEEN_GROUP: 554,
  E2EE_DELETE_QUEUE_ACK_1_1: 557,
  E2EE_DELETE_QUEUE_ACK_GROUP: 558,
  E2EE_ACK_GROUP_INIT_FAILED: 559,
  E2EE_CHECK_COMPATIBLE: 560,
  E2EE_INIT_SESSION_GROUP: 561,
  E2EE_CHECK_COMPATIBLE_GROUP: 562,
  E2EE_GET_LIST_USER: 563,
  E2EE_GET_KEY_ID: 564,
  E2EE_DISABLE: 580,
  E2EE_ENABLE: 581,
  E2EE_DOWNGRADE_GROUP: 582,

  // Missed messages & status queries
  GET_MSG: 570,
  PRELOAD: 571,
  GET_STATUS_MSG: 575,
  GET_STATUS_MSG_GROUP: 576,
  GET_LAST_DELIVER_SEEN: 577,
  GET_LAST_SEEN_CONTAINER: 578,

  // Mobile sync & backup
  SYNC_REQUEST: 590,
  SYNC_ACK_DELETE: 591,
  SYNC_WAKE_MOBILE: 592,
  BACKUP_INIT: 630,
  BACKUP_CREATE_SESSION: 631,
  BACKUP_GET_METADATA: 632,
  BACKUP_SIGNAL_RESTORE: 633,
  BACKUP_GET_CONFIGS: 634,

  // Controls, actions & reactions
  CTRL_TESTING: 600,
  CTRL_PUSH_CTRL: 601,
  CTRL_ACTION: 602,
  CTRL_PULL_CTRL: 603,
  CTRL_PULL_VOIP: 604,
  CTRL_PULL_REACT: 610,
  CTRL_PULL_REACT_GROUP: 611,
  CTRL_PUSH_REACT: 612,
  CTRL_PUSH_CLEAR_REACT: 613,
  CTRL_GET_LAST_SEEN_REACT: 614,

  // ZCloud & auxiliary
  CLOUD_PUSH: 620,
  CLOUD_NEED_VERIFY: 621,
  CLOUD_DONE_MIGRATE: 623,
  GET_IN_APP_PAYMENT_LINK: 701,
  OFFLINE_MSG_1_1_IDZ3: 710,
  OFFLINE_MSG_GROUP_IDZ3: 711,
  OFFLINE_MSG_E2EE_PC_IDZ3: 713,
  OFFLINE_MSG_E2EE_WEB_IDZ3: 715,
  GET_MEDIA_UPLOAD_URL: 800,
} as const;

export const WS_SUB_CMD = {
  DEFAULT: 0,
  AUTHEN: 1,
  PING_CONNECTION: 1,
  PING_ACTIVE: 2,
  OFFLINE_V1: 0,
  OFFLINE_V2: 1,
  E2EE_REQUEST: 0,
  E2EE_PUSH: 1,
} as const;

/**
 * Numeric signaling commands routed between native ZaloCall (`sendSignal`)
 * and `voicecall-wpa.zaloapp.com`.
 */
export const CALL_SIGNAL_CMD = {
  REQUEST_CALL: 401,
  ANSWER: 402,
  CANCEL: 405,
  LOG_END_CALL: 406,
  RING_RING: 407,
  ANSWER_ACK: 408,
  END_CALL: 409,
  HOLD_REQ: 411,
  HOLD_RESP: 412,
  UNHOLD_REQ: 413,
  UNHOLD_RESP: 414,
  REQUEST_INVITE: 416,
  CONF: 12006,
  GROUP_JOIN: 12043,
  GROUP_SHARE_SCREEN: 12044,
  REQUEST_AUDIO_TO_VIDEO: 12056,
  REQUEST_SHARE_SCREEN: 12064,
  GROUP_PING: 12097,
  GROUP_BROADCAST: 12098,
  GROUP_REQUEST_CALL: 12433,
  GROUP_REQUEST_INVITE: 12434,
  GROUP_ADD_USER: 12435,
  GROUP_ANSWER: 12436,
  GROUP_CANCEL: 12437,
  GROUP_END_CALL: 12438,
  GROUP_RING_RING: 12439,
  GROUP_STATE: 12445,
  GROUP_FINISH: 12446,
  GROUP_NOTIFY: 12447,
} as const;

export type CallSignalCommandId = (typeof CALL_SIGNAL_CMD)[keyof typeof CALL_SIGNAL_CMD];
