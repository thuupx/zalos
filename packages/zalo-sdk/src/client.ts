import { BoardApi } from "./apis/board.ts";
import { BusinessApi, type QuickMessageWritePayload } from "./apis/business.ts";
import { CallApi } from "./apis/call.ts";
import { ConversationsApi } from "./apis/conversations.ts";
import { E2eeApi } from "./apis/e2ee.ts";
import { ExtrasApi } from "./apis/extras.ts";
import { FriendsApi } from "./apis/friends.ts";
import { GroupsApi } from "./apis/groups.ts";
import { MessagingApi } from "./apis/messaging.ts";
import { ProfileApi } from "./apis/profile.ts";
import { StickersApi } from "./apis/stickers.ts";
import { ZCallV2Bridge } from "./apis/zcall-bridge.ts";
import { getListDevice, keepAlive, loginWithCookie, loginWithPassword, logoutSession, type PasswordLoginOptions } from "./auth/login.ts";
import { loginQRPc, loginQRWeb, type LoginQRCallbacks, type LoginQROptions } from "./auth/login-qr.ts";
import { CLIENT_PROFILES } from "./core/constants.ts";
import type { ServiceMap, ZaloContext, ZaloCredentials, ZaloOptions } from "./core/context.ts";
import { ZaloCookieJar } from "./core/cookies.ts";
import { decodeAES, encodeAES, generateImei } from "./core/crypto.ts";
import { ZaloHttpClient } from "./core/http.ts";
import { ZaloListener, type ListenerOptions } from "./ws/listener.ts";

export interface CustomApiCallbackProps<P = Record<string, unknown>> {
  ctx: ZaloContext;
  utils: {
    makeURL: ZaloHttpClient["makeURL"];
    encodeAES: (data: string) => string;
    decodeAES: (data: string) => string;
    request: ZaloHttpClient["requestRaw"];
    resolve: <T = unknown>(response: Response, decryptData?: boolean) => Promise<T>;
  };
  props: P;
}

export class ZaloApi {
  readonly ctx: ZaloContext;
  readonly http: ZaloHttpClient;
  readonly listener: ZaloListener;

  readonly messaging: MessagingApi;
  readonly groups: GroupsApi;
  readonly board: BoardApi;
  readonly friends: FriendsApi;
  readonly conversations: ConversationsApi;
  readonly stickers: StickersApi;
  readonly profile: ProfileApi;
  readonly business: BusinessApi;
  readonly call: CallApi;
  readonly e2ee: E2eeApi;
  readonly extras: ExtrasApi;

  private readonly customMethods = new Map<string, (props: Record<string, unknown>) => Promise<unknown>>();

  constructor(ctx: ZaloContext, http: ZaloHttpClient, listenerOptions?: ListenerOptions) {
    this.ctx = ctx;
    this.http = http;
    this.listener = new ZaloListener(ctx, listenerOptions);

    this.messaging = new MessagingApi(http, ctx, () => this.listener);
    this.groups = new GroupsApi(http, ctx);
    this.board = new BoardApi(http, ctx);
    this.friends = new FriendsApi(http, ctx);
    this.conversations = new ConversationsApi(http, ctx);
    this.stickers = new StickersApi(http, ctx);
    this.profile = new ProfileApi(http, ctx);
    this.business = new BusinessApi(http, ctx);
    this.call = new CallApi(http, ctx);
    this.e2ee = new E2eeApi(http, ctx, () => this.listener);
    this.extras = new ExtrasApi(http, ctx, () => this.listener);
  }

  get zpwServiceMap(): ServiceMap {
    return this.ctx.zpwServiceMap;
  }

  getOwnId(): string {
    return this.ctx.uid;
  }

  getCookie(): ZaloCookieJar {
    return this.ctx.cookie;
  }

  getContext(): ZaloContext {
    return this.ctx;
  }

  createZCallBridge(paths?: { recvPath: string; sendPath: string }): ZCallV2Bridge {
    return new ZCallV2Bridge(paths);
  }

  /**
   * Registers an extension RPC helper compatible with `zca-js` `api.custom()`.
   */
  custom<P = Record<string, unknown>, R = unknown>(
    name: string,
    handler: (tools: CustomApiCallbackProps<P>) => Promise<R>,
  ): (props: P) => Promise<R> {
    const fn = (props: P) =>
      handler({
        ctx: this.ctx,
        utils: {
          makeURL: this.http.makeURL.bind(this.http),
          encodeAES: (data: string) => encodeAES(this.ctx.secretKey, data, "base64"),
          decodeAES: (data: string) => decodeAES(this.ctx.secretKey, data, "base64"),
          request: this.http.requestRaw.bind(this.http),
          resolve: this.http.resolveEnvelope.bind(this.http),
        },
        props,
      });
    this.customMethods.set(name, fn as (props: Record<string, unknown>) => Promise<unknown>);
    (this as unknown as Record<string, unknown>)[name] = fn;
    return fn;
  }

  // ---- Session & Account Aliases ----
  keepAlive = () => keepAlive(this.http, this.ctx);
  logout = () => logoutSession(this.http, this.listener);
  getListDevice = () => getListDevice(this.http, this.ctx);

  // ---- Messaging Aliases ----
  sendMessage = (...args: Parameters<MessagingApi["sendMessage"]>) => this.messaging.sendMessage(...args);
  uploadAttachment = (...args: Parameters<MessagingApi["uploadAttachment"]>) => this.messaging.uploadAttachment(...args);
  sendVideo = (...args: Parameters<MessagingApi["sendVideo"]>) => this.messaging.sendVideo(...args);
  sendVoice = (...args: Parameters<MessagingApi["sendVoice"]>) => this.messaging.sendVoice(...args);
  sendCard = (...args: Parameters<MessagingApi["sendCard"]>) => this.messaging.sendCard(...args);
  sendLink = (...args: Parameters<MessagingApi["sendLink"]>) => this.messaging.sendLink(...args);
  parseLink = (...args: Parameters<MessagingApi["parseLink"]>) => this.messaging.parseLink(...args);
  scanURL = (...args: Parameters<MessagingApi["scanURL"]>) => this.messaging.scanURL(...args);
  sendSticker = (...args: Parameters<MessagingApi["sendSticker"]>) => this.messaging.sendSticker(...args);
  sendBankCard = (...args: Parameters<MessagingApi["sendBankCard"]>) => this.messaging.sendBankCard(...args);
  forwardMessage = (...args: Parameters<MessagingApi["forwardMessage"]>) => this.messaging.forwardMessage(...args);
  undo = (...args: Parameters<MessagingApi["undo"]>) => this.messaging.undo(...args);
  deleteMessage = (...args: Parameters<MessagingApi["deleteMessage"]>) => this.messaging.deleteMessage(...args);
  sendSeenEvent = (...args: Parameters<MessagingApi["sendSeenEvent"]>) => this.messaging.sendSeenEvent(...args);
  sendDeliveredEvent = (...args: Parameters<MessagingApi["sendDeliveredEvent"]>) => this.messaging.sendDeliveredEvent(...args);
  sendTypingEvent = (...args: Parameters<MessagingApi["sendTypingEvent"]>) => this.messaging.sendTypingEvent(...args);
  addReaction = (...args: Parameters<MessagingApi["addReaction"]>) => this.messaging.addReaction(...args);
  getCloudMessage = (...args: Parameters<MessagingApi["getCloudMessage"]>) => this.messaging.getCloudMessage(...args);
  getGroupChatHistory = (...args: Parameters<MessagingApi["getGroupChatHistory"]>) => this.messaging.getGroupChatHistory(...args);

  // ---- Groups Aliases ----
  getAllGroups = () => this.groups.getAllGroups();
  createGroup = (...args: Parameters<GroupsApi["createGroup"]>) => this.groups.createGroup(...args);
  getGroupInfo = (...args: Parameters<GroupsApi["getGroupInfo"]>) => this.groups.getGroupInfo(...args);
  getGroupMembersInfo = (...args: Parameters<GroupsApi["getGroupMembersInfo"]>) => this.groups.getGroupMembersInfo(...args);
  addUserToGroup = (...args: Parameters<GroupsApi["addUserToGroup"]>) => this.groups.addUserToGroup(...args);
  inviteUserToGroups = (...args: Parameters<GroupsApi["inviteUserToGroups"]>) => this.groups.inviteUserToGroups(...args);
  removeUserFromGroup = (...args: Parameters<GroupsApi["removeUserFromGroup"]>) => this.groups.removeUserFromGroup(...args);
  leaveGroup = (...args: Parameters<GroupsApi["leaveGroup"]>) => this.groups.leaveGroup(...args);
  disperseGroup = (...args: Parameters<GroupsApi["disperseGroup"]>) => this.groups.disperseGroup(...args);
  changeGroupName = (...args: Parameters<GroupsApi["changeGroupName"]>) => this.groups.changeGroupName(...args);
  changeGroupAvatar = (...args: Parameters<GroupsApi["changeGroupAvatar"]>) => this.groups.changeGroupAvatar(...args);
  changeGroupOwner = (...args: Parameters<GroupsApi["changeGroupOwner"]>) => this.groups.changeGroupOwner(...args);
  addGroupDeputy = (...args: Parameters<GroupsApi["addGroupDeputy"]>) => this.groups.addGroupDeputy(...args);
  removeGroupDeputy = (...args: Parameters<GroupsApi["removeGroupDeputy"]>) => this.groups.removeGroupDeputy(...args);
  updateGroupSettings = (...args: Parameters<GroupsApi["updateGroupSettings"]>) => this.groups.updateGroupSettings(...args);
  getPendingGroupMembers = (...args: Parameters<GroupsApi["getPendingGroupMembers"]>) => this.groups.getPendingGroupMembers(...args);
  reviewPendingMemberRequest = (...args: Parameters<GroupsApi["reviewPendingMemberRequest"]>) => this.groups.reviewPendingMemberRequest(...args);
  getGroupBlockedMember = (...args: Parameters<GroupsApi["getGroupBlockedMember"]>) => this.groups.getGroupBlockedMember(...args);
  addGroupBlockedMember = (...args: Parameters<GroupsApi["addGroupBlockedMember"]>) => this.groups.addGroupBlockedMember(...args);
  removeGroupBlockedMember = (...args: Parameters<GroupsApi["removeGroupBlockedMember"]>) => this.groups.removeGroupBlockedMember(...args);
  getGroupLinkDetail = (...args: Parameters<GroupsApi["getGroupLinkDetail"]>) => this.groups.getGroupLinkDetail(...args);
  enableGroupLink = (...args: Parameters<GroupsApi["enableGroupLink"]>) => this.groups.enableGroupLink(...args);
  disableGroupLink = (...args: Parameters<GroupsApi["disableGroupLink"]>) => this.groups.disableGroupLink(...args);
  getGroupLinkInfo = (...args: Parameters<GroupsApi["getGroupLinkInfo"]>) => this.groups.getGroupLinkInfo(...args);
  joinGroupLink = (...args: Parameters<GroupsApi["joinGroupLink"]>) => this.groups.joinGroupLink(...args);
  getGroupInviteBoxList = (...args: Parameters<GroupsApi["getGroupInviteBoxList"]>) => this.groups.getGroupInviteBoxList(...args);
  getGroupInviteBoxInfo = (...args: Parameters<GroupsApi["getGroupInviteBoxInfo"]>) => this.groups.getGroupInviteBoxInfo(...args);
  joinGroupInviteBox = (...args: Parameters<GroupsApi["joinGroupInviteBox"]>) => this.groups.joinGroupInviteBox(...args);
  deleteGroupInviteBox = (...args: Parameters<GroupsApi["deleteGroupInviteBox"]>) => this.groups.deleteGroupInviteBox(...args);
  upgradeGroupToCommunity = (...args: Parameters<GroupsApi["upgradeGroupToCommunity"]>) => this.groups.upgradeGroupToCommunity(...args);
  getRelatedFriendGroup = (...args: Parameters<GroupsApi["getRelatedFriendGroup"]>) => this.groups.getRelatedFriendGroup(...args);

  // ---- Board, Pins, Polls, Notes & Reminders Aliases ----
  createPoll = (...args: Parameters<BoardApi["createPoll"]>) => this.board.createPoll(...args);
  getPollDetail = (...args: Parameters<BoardApi["getPollDetail"]>) => this.board.getPollDetail(...args);
  votePoll = (...args: Parameters<BoardApi["votePoll"]>) => this.board.votePoll(...args);
  addPollOptions = (...args: Parameters<BoardApi["addPollOptions"]>) => this.board.addPollOptions(...args);
  lockPoll = (...args: Parameters<BoardApi["lockPoll"]>) => this.board.lockPoll(...args);
  sharePoll = (...args: Parameters<BoardApi["sharePoll"]>) => this.board.sharePoll(...args);
  getListBoard = (...args: Parameters<BoardApi["getListBoard"]>) => this.board.getListBoard(...args);
  createNote = (...args: Parameters<BoardApi["createNote"]>) => this.board.createNote(...args);
  editNote = (...args: Parameters<BoardApi["editNote"]>) => this.board.editNote(...args);
  createReminder = (...args: Parameters<BoardApi["createReminder"]>) => this.board.createReminder(...args);
  editReminder = (...args: Parameters<BoardApi["editReminder"]>) => this.board.editReminder(...args);
  removeReminder = (...args: Parameters<BoardApi["removeReminder"]>) => this.board.removeReminder(...args);
  getListReminder = (...args: Parameters<BoardApi["getListReminder"]>) => this.board.getListReminder(...args);
  getReminder = (...args: Parameters<BoardApi["getReminder"]>) => this.board.getReminder(...args);
  getReminderResponses = (...args: Parameters<BoardApi["getReminderResponses"]>) => this.board.getReminderResponses(...args);
  getFriendBoardList = (...args: Parameters<BoardApi["getFriendBoardList"]>) => this.board.getFriendBoardList(...args);

  // ---- Friends Aliases ----
  getAllFriends = (...args: Parameters<FriendsApi["getAllFriends"]>) => this.friends.getAllFriends(...args);
  getFriendOnlines = () => this.friends.getFriendOnlines();
  lastOnline = (...args: Parameters<FriendsApi["lastOnline"]>) => this.friends.lastOnline(...args);
  getCloseFriends = () => this.friends.getCloseFriends();
  getUserInfo = (...args: Parameters<FriendsApi["getUserInfo"]>) => this.friends.getUserInfo(...args);
  getAvatarUrlProfile = (...args: Parameters<FriendsApi["getAvatarUrlProfile"]>) => this.friends.getAvatarUrlProfile(...args);
  findUser = (...args: Parameters<FriendsApi["findUser"]>) => this.friends.findUser(...args);
  findUserByUsername = (...args: Parameters<FriendsApi["findUserByUsername"]>) => this.friends.findUserByUsername(...args);
  getMultiUsersByPhones = (...args: Parameters<FriendsApi["getMultiUsersByPhones"]>) => this.friends.getMultiUsersByPhones(...args);
  sendFriendRequest = (...args: Parameters<FriendsApi["sendFriendRequest"]>) => this.friends.sendFriendRequest(...args);
  acceptFriendRequest = (...args: Parameters<FriendsApi["acceptFriendRequest"]>) => this.friends.acceptFriendRequest(...args);
  rejectFriendRequest = (...args: Parameters<FriendsApi["rejectFriendRequest"]>) => this.friends.rejectFriendRequest(...args);
  undoFriendRequest = (...args: Parameters<FriendsApi["undoFriendRequest"]>) => this.friends.undoFriendRequest(...args);
  getSentFriendRequest = () => this.friends.getSentFriendRequest();
  getFriendRequestStatus = (...args: Parameters<FriendsApi["getFriendRequestStatus"]>) => this.friends.getFriendRequestStatus(...args);
  getFriendRecommendations = () => this.friends.getFriendRecommendations();
  removeFriend = (...args: Parameters<FriendsApi["removeFriend"]>) => this.friends.removeFriend(...args);
  getAliasList = (...args: Parameters<FriendsApi["getAliasList"]>) => this.friends.getAliasList(...args);
  changeFriendAlias = (...args: Parameters<FriendsApi["changeFriendAlias"]>) => this.friends.changeFriendAlias(...args);
  removeFriendAlias = (...args: Parameters<FriendsApi["removeFriendAlias"]>) => this.friends.removeFriendAlias(...args);
  blockUser = (...args: Parameters<FriendsApi["blockUser"]>) => this.friends.blockUser(...args);
  unblockUser = (...args: Parameters<FriendsApi["unblockUser"]>) => this.friends.unblockUser(...args);
  blockViewFeed = (...args: Parameters<FriendsApi["blockViewFeed"]>) => this.friends.blockViewFeed(...args);
  getQR = (...args: Parameters<FriendsApi["getQR"]>) => this.friends.getQR(...args);
  sendReport = (...args: Parameters<FriendsApi["sendReport"]>) => this.friends.sendReport(...args);

  // ---- Conversations Aliases ----
  setPinnedConversations = (...args: Parameters<ConversationsApi["setPinnedConversations"]>) => this.conversations.setPinnedConversations(...args);
  getPinConversations = () => this.conversations.getPinConversations();
  setMute = (...args: Parameters<ConversationsApi["setMute"]>) => this.conversations.setMute(...args);
  getMute = () => this.conversations.getMute();
  getHiddenConversations = () => this.conversations.getHiddenConversations();
  setHiddenConversations = (...args: Parameters<ConversationsApi["setHiddenConversations"]>) => this.conversations.setHiddenConversations(...args);
  updateHiddenConversPin = (...args: Parameters<ConversationsApi["updateHiddenConversPin"]>) => this.conversations.updateHiddenConversPin(...args);
  resetHiddenConversPin = () => this.conversations.resetHiddenConversPin();
  getArchivedChatList = () => this.conversations.getArchivedChatList();
  updateArchivedChatList = (...args: Parameters<ConversationsApi["updateArchivedChatList"]>) => this.conversations.updateArchivedChatList(...args);
  addUnreadMark = (...args: Parameters<ConversationsApi["addUnreadMark"]>) => this.conversations.addUnreadMark(...args);
  removeUnreadMark = (...args: Parameters<ConversationsApi["removeUnreadMark"]>) => this.conversations.removeUnreadMark(...args);
  getUnreadMark = () => this.conversations.getUnreadMark();
  getAutoDeleteChat = () => this.conversations.getAutoDeleteChat();
  updateAutoDeleteChat = (...args: Parameters<ConversationsApi["updateAutoDeleteChat"]>) => this.conversations.updateAutoDeleteChat(...args);
  getLabels = () => this.conversations.getLabels();
  updateLabels = (...args: Parameters<ConversationsApi["updateLabels"]>) => this.conversations.updateLabels(...args);
  deleteChat = (...args: Parameters<ConversationsApi["deleteChat"]>) => this.conversations.deleteChat(...args);

  // ---- Stickers Aliases ----
  getStickers = (...args: Parameters<StickersApi["getStickers"]>) => this.stickers.getStickers(...args);
  getStickersDetail = (...args: Parameters<StickersApi["getStickersDetail"]>) => this.stickers.getStickersDetail(...args);
  getStickerCategoryDetail = (...args: Parameters<StickersApi["getStickerCategoryDetail"]>) => this.stickers.getStickerCategoryDetail(...args);
  searchSticker = (...args: Parameters<StickersApi["searchSticker"]>) => this.stickers.searchSticker(...args);

  // ---- Profile Aliases ----
  fetchAccountInfo = () => this.profile.fetchAccountInfo();
  updateProfile = (...args: Parameters<ProfileApi["updateProfile"]>) => this.profile.updateProfile(...args);
  updateProfileBio = (...args: Parameters<ProfileApi["updateProfileBio"]>) => this.profile.updateProfileBio(...args);
  changeAccountAvatar = (...args: Parameters<ProfileApi["changeAccountAvatar"]>) => this.profile.changeAccountAvatar(...args);
  deleteAvatar = (...args: Parameters<ProfileApi["deleteAvatar"]>) => this.profile.deleteAvatar(...args);
  getAvatarList = (...args: Parameters<ProfileApi["getAvatarList"]>) => this.profile.getAvatarList(...args);
  reuseAvatar = (...args: Parameters<ProfileApi["reuseAvatar"]>) => this.profile.reuseAvatar(...args);
  getFullAvatar = (...args: Parameters<ProfileApi["getFullAvatar"]>) => this.profile.getFullAvatar(...args);
  getSettings = () => this.profile.getSettings();
  updateSettings = (...args: Parameters<ProfileApi["updateSettings"]>) => this.profile.updateSettings(...args);
  updateActiveStatus = (...args: Parameters<ProfileApi["updateActiveStatus"]>) => this.profile.updateActiveStatus(...args);
  updateLang = (...args: Parameters<ProfileApi["updateLang"]>) => this.profile.updateLang(...args);
  lostFocus = () => this.profile.lostFocus();

  // ---- Business Aliases ----
  getBizAccount = (...args: Parameters<BusinessApi["getBizAccount"]>) => this.business.getBizAccount(...args);
  getCatalogList = (...args: Parameters<BusinessApi["getCatalogList"]>) => this.business.getCatalogList(...args);
  createCatalog = (...args: Parameters<BusinessApi["createCatalog"]>) => this.business.createCatalog(...args);
  updateCatalog = (...args: Parameters<BusinessApi["updateCatalog"]>) => this.business.updateCatalog(...args);
  deleteCatalog = (...args: Parameters<BusinessApi["deleteCatalog"]>) => this.business.deleteCatalog(...args);
  registerCatalog = (...args: Parameters<BusinessApi["registerCatalog"]>) => this.business.registerCatalog(...args);
  getProductCatalogList = (...args: Parameters<BusinessApi["getProductCatalogList"]>) => this.business.getProductCatalogList(...args);
  createProductCatalog = (...args: Parameters<BusinessApi["createProductCatalog"]>) => this.business.createProductCatalog(...args);
  updateProductCatalog = (...args: Parameters<BusinessApi["updateProductCatalog"]>) => this.business.updateProductCatalog(...args);
  deleteProductCatalog = (...args: Parameters<BusinessApi["deleteProductCatalog"]>) => this.business.deleteProductCatalog(...args);
  uploadProductPhoto = (...args: Parameters<BusinessApi["uploadProductPhoto"]>) => this.business.uploadProductPhoto(...args);
  getQuickMessageList = (...args: Parameters<BusinessApi["getQuickMessageList"]>) => this.business.getQuickMessageList(...args);
  addQuickMessage = (...args: Parameters<BusinessApi["addQuickMessage"]>) => this.business.addQuickMessage(...args);
  updateQuickMessage(
    itemId: number,
    payload: QuickMessageWritePayload,
  ): Promise<{ item?: unknown; version?: number }>;
  updateQuickMessage(
    payload: QuickMessageWritePayload,
    itemId: number,
  ): Promise<{ item?: unknown; version?: number }>;
  updateQuickMessage(
    idOrPayload: number | QuickMessageWritePayload,
    payloadOrId: QuickMessageWritePayload | number,
  ): Promise<{ item?: unknown; version?: number }> {
    return typeof idOrPayload === "number"
      ? this.business.updateQuickMessage(idOrPayload, payloadOrId as QuickMessageWritePayload)
      : this.business.updateQuickMessage(idOrPayload, payloadOrId as number);
  }
  removeQuickMessage = (...args: Parameters<BusinessApi["removeQuickMessage"]>) => this.business.removeQuickMessage(...args);
  getAutoReplyList = () => this.business.getAutoReplyList();
  createAutoReply = (...args: Parameters<BusinessApi["createAutoReply"]>) => this.business.createAutoReply(...args);
  updateAutoReply = (...args: Parameters<BusinessApi["updateAutoReply"]>) => this.business.updateAutoReply(...args);
  deleteAutoReply = (...args: Parameters<BusinessApi["deleteAutoReply"]>) => this.business.deleteAutoReply(...args);
  getListBank = () => this.business.getListBank();
  getListBankAccount = (...args: Parameters<BusinessApi["getListBankAccount"]>) => this.business.getListBankAccount(...args);
  createBankAccount = (...args: Parameters<BusinessApi["createBankAccount"]>) => this.business.createBankAccount(...args);
  updateBankAccount = (...args: Parameters<BusinessApi["updateBankAccount"]>) => this.business.updateBankAccount(...args);
  deleteBankAccount = (...args: Parameters<BusinessApi["deleteBankAccount"]>) => this.business.deleteBankAccount(...args);
}

export class ZaloClient {
  private readonly options: ZaloOptions;

  constructor(options: ZaloOptions = {}) {
    this.options = options;
  }

  private createContext(userAgentOverride?: string): ZaloContext {
    const profile = CLIENT_PROFILES[this.options.profile ?? "web"];
    const userAgent = userAgentOverride ?? profile.userAgent;
    return {
      uid: "",
      imei: generateImei(userAgent),
      userAgent,
      language: this.options.language ?? "vi",
      secretKey: "",
      cookie: new ZaloCookieJar(),
      profile,
      apiType: this.options.apiType ?? profile.apiType,
      apiVersion: this.options.apiVersion ?? profile.apiVersion,
      computerName: this.options.computerName ?? profile.computerName,
      settings: {},
      extraVer: {},
      zpwServiceMap: {},
      wsUrls: [],
      uploadCallbacks: new Map(),
      options: {
        selfListen: this.options.selfListen ?? true,
        checkUpdate: this.options.checkUpdate ?? false,
        logging: this.options.logging ?? false,
      },
      imageMetadataGetter: this.options.imageMetadataGetter,
    };
  }

  async login(credentials: ZaloCredentials, listenerOptions?: ListenerOptions): Promise<ZaloApi> {
    const ctx = this.createContext(credentials.userAgent);
    const http = new ZaloHttpClient(ctx, this.options.polyfill);
    await loginWithCookie(http, ctx, credentials);
    return new ZaloApi(ctx, http, listenerOptions);
  }

  async loginQR(
    options: LoginQROptions = {},
    callback?: LoginQRCallbacks,
  ): Promise<ZaloApi | null> {
    const ctx = this.createContext(options.userAgent);
    const http = new ZaloHttpClient(ctx, this.options.polyfill);
    const creds = await loginQRWeb(http, ctx, options, callback);
    if (creds === null) return null;
    return new ZaloApi(ctx, http);
  }

  async loginQRPc(
    options: LoginQROptions & { loggedUids?: string[] } = {},
    callback?: LoginQRCallbacks,
  ): Promise<ZaloApi> {
    const ctx = this.createContext(options.userAgent);
    const http = new ZaloHttpClient(ctx, this.options.polyfill);
    await loginQRPc(http, ctx, options, callback);
    return new ZaloApi(ctx, http);
  }

  async loginWithPassword(
    options: PasswordLoginOptions,
    listenerOptions?: ListenerOptions,
  ): Promise<ZaloApi> {
    const ctx = this.createContext();
    const http = new ZaloHttpClient(ctx, this.options.polyfill);
    await loginWithPassword(http, ctx, options);
    const creds: ZaloCredentials = {
      imei: ctx.imei,
      cookie: ctx.cookie.toJSON(),
      userAgent: ctx.userAgent,
      language: ctx.language,
    };
    await loginWithCookie(http, ctx, creds);
    return new ZaloApi(ctx, http, listenerOptions);
  }
}

export { ZaloClient as Zalo };
export type { ZaloApi as API };
