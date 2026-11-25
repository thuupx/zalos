export enum ThreadType {
  User = 0,
  Group = 1,
}

export enum DestType {
  Group = 1,
  User = 3,
  Page = 5,
}

export enum Gender {
  Male = 0,
  Female = 1,
}

export enum AvatarSize {
  Small = 120,
  Medium = 180,
  Large = 240,
  ExtraLarge = 360,
}

export enum Urgency {
  Default = 0,
  Important = 1,
  Urgent = 2,
}

export enum TextStyle {
  Bold = "b",
  Italic = "i",
  Underline = "u",
  StrikeThrough = "s",
  Red = "c_db342e",
  Orange = "c_f27806",
  Yellow = "c_f7b503",
  Green = "c_15a85f",
  Small = "f_13",
  Big = "f_18",
  UnorderedList = "lst_1",
  OrderedList = "lst_2",
  Indent = "ind_$",
}

export enum Reactions {
  HEART = "/-heart",
  LIKE = "/-strong",
  HAHA = ":>",
  WOW = ":o",
  CRY = ":-((",
  ANGRY = ":-h",
  KISS = ":-*",
  TEARS_OF_JOY = ":')",
  SHIT = "/-shit",
  ROSE = "/-rose",
  BROKEN_HEART = "/-break",
  DISLIKE = "/-weak",
  LOVE = ";xx",
  CONFUSED = ";-/",
  WINK = ";-)",
  FADE = "/-fade",
  SUN = "/-li",
  BIRTHDAY = "/-bd",
  BOMB = "/-bome",
  OK = "/-ok",
  PEACE = "/-v",
  THANKS = "/-thanks",
  PUNCH = "/-punch",
  SHARE = "/-share",
  PRAY = "_()_",
  NO = "/-no",
  BAD = "/-bad",
  LOVE_YOU = "/-loveu",
  SAD = "--b",
  VERY_SAD = ":((",
  COOL = "x-)",
  NERD = "8-)",
  BIG_SMILE = ";-d",
  SUNGLASSES = "b-)",
  NEUTRAL = ":--|",
  SAD_FACE = "p-(",
  BYE = ":-bye",
  SLEEPY = "|-)",
  WIPE = ":wipe",
  DIG = ":-dig",
  ANGUISH = "&-(",
  HANDCLAP = ":handclap",
  ANGRY_FACE = ">-|",
  F_CHAIR = ":-f",
  L_CHAIR = ":-l",
  R_CHAIR = ":-r",
  SILENT = ";-x",
  SURPRISE = ":-o",
  EMBARRASSED = ";-s",
  AFRAID = ";-a",
  SAD2 = ":-<",
  BIG_LAUGH = ":))",
  RICH = "$-)",
  BEER = "/-beer",
  NONE = "",
}

export enum ChatTTL {
  NO_DELETE = 0,
  ONE_DAY = 86400000,
  SEVEN_DAYS = 604800000,
  FOURTEEN_DAYS = 1209600000,
}

export enum MuteAction {
  MUTE = 1,
  UNMUTE = 3,
}

export enum MuteDuration {
  ONE_HOUR = 3600,
  FOUR_HOURS = 14400,
  FOREVER = -1,
  UNTIL_8AM = "until8AM",
}

export enum ReportReason {
  Sensitive = 1,
  Annoy = 2,
  Fraud = 3,
  Other = 0,
}

export enum BinBankCard {
  VietinBank = 970415,
  Vietcombank = 970436,
  BIDV = 970418,
  Agribank = 970405,
  OCB = 970448,
  MBBank = 970422,
  Techcombank = 970407,
  ACB = 970416,
  VPBank = 970432,
  TPBank = 970423,
  Sacombank = 970403,
  HDBank = 970437,
  VietCapitalBank = 970454,
  SCB = 970429,
  VIB = 970441,
  SHB = 970443,
  Eximbank = 970431,
  MSB = 970426,
  CAKE = 546034,
  Ubank = 546035,
  Timo = 963388,
  ViettelMoney = 971005,
  VNPTMoney = 971011,
  SaigonBank = 970400,
  BacABank = 970409,
  PVcomBank = 970412,
  Oceanbank = 970414,
  NCB = 970419,
  ShinhanBank = 970424,
  ABBANK = 970425,
  VietABank = 970427,
  NamABank = 970428,
  PGBank = 970430,
  VietBank = 970433,
  BaoVietBank = 970438,
  SeABank = 970440,
  COOPBANK = 970446,
  LPBank = 970449,
  KienLongBank = 970452,
  KBank = 668888,
  KookminHN = 970462,
  KEBHanaHCM = 970466,
  KEBHANAHN = 970467,
  MAFC = 977777,
  Citibank = 533948,
  KookminHCM = 970463,
  VBSP = 999888,
  Woori = 970457,
  VRB = 970421,
  UnitedOverseas = 970458,
  StandardChartered = 970410,
  PublicBank = 970439,
  Nonghyup = 801011,
  IndovinaBank = 970434,
  IBKHCM = 970456,
  IBKHN = 970455,
  HSBC = 458761,
  HongLeong = 970442,
  GPBank = 970408,
  DongABank = 970406,
  DBSBank = 796500,
  CIMB = 422589,
  CBBank = 970444,
}

export enum CloseReason {
  Normal = 1000,
  ServerShutdown = 1001,
  Abnormal = 1006,
  DuplicateConnection = 3000,
  ReadMaxConnection = 3001,
  NotFoundWorker = 3002,
  KickConnection = 3003,
}

export enum LoginQRCallbackEventType {
  QRCodeGenerated = 0,
  QRCodeExpired = 1,
  QRCodeScanned = 2,
  QRCodeDeclined = 3,
  GotLoginInfo = 4,
}

export enum FriendRecommendationsType {
  RecommendedFriend = 1,
  ReceivedFriendRequest = 2,
}

export enum GroupEventType {
  JOIN_REQUEST = "join_request",
  JOIN = "join",
  LEAVE = "leave",
  REMOVE_MEMBER = "remove_member",
  BLOCK_MEMBER = "block_member",
  UPDATE_SETTING = "update_setting",
  UPDATE = "update",
  NEW_LINK = "new_link",
  ADD_ADMIN = "add_admin",
  REMOVE_ADMIN = "remove_admin",
  NEW_PIN_TOPIC = "new_pin_topic",
  UPDATE_PIN_TOPIC = "update_pin_topic",
  UNPIN_TOPIC = "unpin_topic",
  REORDER_PIN_TOPIC = "reorder_pin_topic",
  UPDATE_BOARD = "update_board",
  REMOVE_BOARD = "remove_board",
  UPDATE_TOPIC = "update_topic",
  REMOVE_TOPIC = "remove_topic",
  REMIND_TOPIC = "remind_topic",
  ACCEPT_REMIND = "accept_remind",
  REJECT_REMIND = "reject_remind",
  UPDATE_AVATAR = "update_avatar",
  GROUP_TYPE = "group_type",
  UNKNOWN = "unknown",
}

export enum FriendEventType {
  ADD = "add",
  REMOVE = "remove",
  REQUEST = "request",
  UNDO_REQUEST = "undo_request",
  REJECT_REQUEST = "reject_request",
  SEEN_FRIEND_REQUEST = "seen_fr_req",
  BLOCK = "block",
  UNBLOCK = "unblock",
  BLOCK_CALL = "block_call",
  UNBLOCK_CALL = "unblock_call",
  PIN_UNPIN = "pin_unpin",
  PIN_CREATE = "pin_create",
  UNKNOWN = "unknown",
}

export enum BoardType {
  Note = 1,
  PinnedMessage = 2,
  Poll = 3,
}

export enum ReminderRepeatMode {
  None = 0,
  Daily = 1,
  Weekly = 2,
  Monthly = 3,
}

export enum CallMakeType {
  AudioOneOne = 1,
  VideoOneOne = 3,
  AudioGroup = 5,
  VideoGroup = 6,
}

export enum CallLogReason {
  Default = 0,
  CalleeBusy = 1,
  TimeoutHaveRinging = 2,
  CalleeReject = 3,
  CallerRejectHaveRinging = 4,
  CallerRejectNotRinging = 5,
}

export enum E2eeDeviceId {
  Mobile = 0,
  Web = 1,
  Pc = 2,
  System = 3,
  Unknown = 6,
}

export enum CloudMessageSource {
  Overflow = 1,
  LoadMore = 3,
}

export enum UpdateSettingsType {
  ViewBirthday = "view_birthday",
  ShowOnlineStatus = "show_online_status",
  DisplaySeenStatus = "display_seen_status",
  ReceiveMessage = "receive_message",
  AcceptCall = "accept_stranger_call",
  AddFriendViaPhone = "add_friend_via_phone",
  AddFriendViaQR = "add_friend_via_qr",
  AddFriendViaGroup = "add_friend_via_group",
  AddFriendViaContact = "add_friend_via_contact",
  DisplayOnRecommendFriend = "display_on_recommend_friend",
  ArchivedChat = "archivedChatStatus",
  QuickMessage = "quickMessageStatus",
}
