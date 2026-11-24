import 'package:flutter/widgets.dart';

/// Unified Phosphor icon set across the app.
///
/// Regular weight provides crisp, thin-stroke outlines; Fill weight provides
/// solid active/selected states.
@staticIconProvider
abstract final class ZIcons {
  static const String _regular = 'PhosphorRegular';
  static const String _fill = 'PhosphorFill';

  // Navigation
  static const IconData chat = IconData(0xe16c, fontFamily: _regular);
  static const IconData chatFill = IconData(0xe16c, fontFamily: _fill);
  static const IconData forum = IconData(0xe17e, fontFamily: _regular);
  static const IconData contacts = IconData(0xe6f8, fontFamily: _regular);
  static const IconData contactsFill = IconData(0xe6f8, fontFamily: _fill);
  static const IconData user = IconData(0xe4c4, fontFamily: _regular);
  static const IconData userFill = IconData(0xe4c4, fontFamily: _fill);
  static const IconData settings = IconData(0xe272, fontFamily: _regular);
  static const IconData settingsFill = IconData(0xe272, fontFamily: _fill);

  // Common actions & chevrons
  static const IconData close = IconData(0xe4f6, fontFamily: _regular);
  static const IconData back = IconData(0xe058, fontFamily: _regular);
  static const IconData chevronLeft = IconData(0xe138, fontFamily: _regular);
  static const IconData chevronRight = IconData(0xe13a, fontFamily: _regular);
  static const IconData chevronDown = IconData(0xe136, fontFamily: _regular);
  static const IconData chevronUp = IconData(0xe13c, fontFamily: _regular);
  static const IconData moreHoriz = IconData(0xe1fe, fontFamily: _regular);
  static const IconData moreVert = IconData(0xe208, fontFamily: _regular);
  static const IconData plus = IconData(0xe3d4, fontFamily: _regular);
  static const IconData search = IconData(0xe30c, fontFamily: _regular);
  static const IconData searchOff = IconData(0xe30e, fontFamily: _regular);
  static const IconData refresh = IconData(0xe094, fontFamily: _regular);
  static const IconData check = IconData(0xe182, fontFamily: _regular);
  static const IconData checkCircle = IconData(0xe184, fontFamily: _fill);
  static const IconData checkBox = IconData(0xe186, fontFamily: _fill);
  static const IconData checkBoxBlank = IconData(0xe45e, fontFamily: _regular);
  static const IconData radioChecked = IconData(0xeb08, fontFamily: _fill);
  static const IconData radioUnchecked = IconData(0xe18a, fontFamily: _regular);

  // Messaging & composer
  static const IconData send = IconData(0xe396, fontFamily: _fill);
  static const IconData reply = IconData(0xe024, fontFamily: _regular);
  static const IconData forward = IconData(0xed52, fontFamily: _regular);
  static const IconData copy = IconData(0xe1ca, fontFamily: _regular);
  static const IconData paste = IconData(0xe198, fontFamily: _regular);
  static const IconData undo = IconData(0xe08a, fontFamily: _regular);
  static const IconData delete = IconData(0xe4a6, fontFamily: _regular);
  static const IconData deleteForever = IconData(0xe4a6, fontFamily: _fill);
  static const IconData download = IconData(0xe20c, fontFamily: _regular);
  static const IconData upload = IconData(0xe4c0, fontFamily: _regular);
  static const IconData share = IconData(0xe408, fontFamily: _regular);
  static const IconData openInNew = IconData(0xe5de, fontFamily: _regular);
  static const IconData edit = IconData(0xe3b4, fontFamily: _regular);
  static const IconData info = IconData(0xe2ce, fontFamily: _regular);
  static const IconData flag = IconData(0xe244, fontFamily: _regular);
  static const IconData attach = IconData(0xe39a, fontFamily: _regular);
  static const IconData image = IconData(0xe2ca, fontFamily: _regular);
  static const IconData brokenImage = IconData(0xe7a8, fontFamily: _regular);
  static const IconData video = IconData(0xe4da, fontFamily: _regular);
  static const IconData mic = IconData(0xe326, fontFamily: _regular);
  static const IconData play = IconData(0xe3d0, fontFamily: _fill);
  static const IconData pause = IconData(0xe39e, fontFamily: _fill);
  static const IconData mood = IconData(0xe436, fontFamily: _regular);
  static const IconData addReaction = IconData(0xe666, fontFamily: _regular);
  static const IconData sticker = IconData(0xe5ac, fontFamily: _regular);
  static const IconData at = IconData(0xe0ac, fontFamily: _regular);
  static const IconData tune = IconData(0xe432, fontFamily: _regular);
  static const IconData bolt = IconData(0xe2de, fontFamily: _regular);
  static const IconData boltFill = IconData(0xe2de, fontFamily: _fill);
  static const IconData priorityHigh = IconData(0xee44, fontFamily: _fill);

  // Reactions
  static const IconData heart = IconData(0xe2a8, fontFamily: _regular);
  static const IconData heartFill = IconData(0xe2a8, fontFamily: _fill);
  static const IconData thumbUp = IconData(0xe48e, fontFamily: _fill);
  static const IconData reactHaha = IconData(0xe666, fontFamily: _fill);
  static const IconData reactWow = IconData(0xe43c, fontFamily: _fill);
  static const IconData reactSad = IconData(0xe43e, fontFamily: _fill);
  static const IconData reactAngry = IconData(0xec62, fontFamily: _fill);

  // Text formatting
  static const IconData formatBold = IconData(0xe5be, fontFamily: _regular);
  static const IconData formatItalic = IconData(0xe5c0, fontFamily: _regular);
  static const IconData formatUnderline = IconData(0xe5c4, fontFamily: _regular);
  static const IconData formatStrike = IconData(0xe5c2, fontFamily: _regular);

  // Thread & conversation state
  static const IconData pin = IconData(0xe3e2, fontFamily: _regular);
  static const IconData pinFill = IconData(0xe3e2, fontFamily: _fill);
  static const IconData archive = IconData(0xe00c, fontFamily: _regular);
  static const IconData unarchive = IconData(0xe4aa, fontFamily: _regular);
  static const IconData timer = IconData(0xe492, fontFamily: _regular);
  static const IconData timerOff = IconData(0xe19a, fontFamily: _regular);
  static const IconData schedule = IconData(0xe19a, fontFamily: _regular);
  static const IconData bell = IconData(0xe0ce, fontFamily: _regular);
  static const IconData bellOff = IconData(0xe0d4, fontFamily: _regular);
  static const IconData markRead = IconData(0xe21a, fontFamily: _regular);
  static const IconData markUnread = IconData(0xe218, fontFamily: _regular);
  static const IconData eye = IconData(0xe220, fontFamily: _regular);
  static const IconData eyeOff = IconData(0xe224, fontFamily: _regular);
  static const IconData label = IconData(0xe478, fontFamily: _regular);
  static const IconData labelOff = IconData(0xe3de, fontFamily: _regular);
  static const IconData star = IconData(0xe46a, fontFamily: _regular);
  static const IconData starFill = IconData(0xe46a, fontFamily: _fill);

  // People & groups
  static const IconData group = IconData(0xe4d6, fontFamily: _regular);
  static const IconData groupFill = IconData(0xe4d6, fontFamily: _fill);
  static const IconData groups = IconData(0xe68e, fontFamily: _regular);
  static const IconData groupAdd = IconData(0xe4d0, fontFamily: _regular);
  static const IconData personAdd = IconData(0xe4d0, fontFamily: _regular);
  static const IconData personRemove = IconData(0xe4ce, fontFamily: _regular);
  static const IconData personCheck = IconData(0xeafa, fontFamily: _regular);
  static const IconData manageAccounts = IconData(0xe4cc, fontFamily: _regular);
  static const IconData contactCard = IconData(0xe2c8, fontFamily: _regular);
  static const IconData block = IconData(0xe3de, fontFamily: _regular);
  static const IconData storefront = IconData(0xe470, fontFamily: _regular);

  // Rich message attachments
  static const IconData link = IconData(0xe2e2, fontFamily: _regular);
  static const IconData linkOff = IconData(0xe2e4, fontFamily: _regular);
  static const IconData bank = IconData(0xe0b4, fontFamily: _regular);
  static const IconData location = IconData(0xe316, fontFamily: _regular);
  static const IconData map = IconData(0xe31a, fontFamily: _regular);
  static const IconData poll = IconData(0xe150, fontFamily: _regular);
  static const IconData note = IconData(0xe348, fontFamily: _regular);
  static const IconData alarm = IconData(0xe006, fontFamily: _regular);
  static const IconData call = IconData(0xe3b8, fontFamily: _regular);
  static const IconData callVoice = IconData(0xe3ba, fontFamily: _regular);
  static const IconData doodle = IconData(0xe662, fontFamily: _regular);
  static const IconData checklist = IconData(0xeadc, fontFamily: _regular);
  static const IconData filePdf = IconData(0xe702, fontFamily: _regular);
  static const IconData fileZip = IconData(0xe958, fontFamily: _regular);
  static const IconData fileAudio = IconData(0xea20, fontFamily: _regular);
  static const IconData fileVideo = IconData(0xea22, fontFamily: _regular);
  static const IconData fileDoc = IconData(0xe23a, fontFamily: _regular);
  static const IconData fileSheet = IconData(0xe476, fontFamily: _regular);
  static const IconData fileSlides = IconData(0xe654, fontFamily: _regular);

  // Security, devices & status
  static const IconData devices = IconData(0xeba4, fontFamily: _regular);
  static const IconData smartphone = IconData(0xe1e0, fontFamily: _regular);
  static const IconData tablet = IconData(0xe1e6, fontFamily: _regular);
  static const IconData laptop = IconData(0xe586, fontFamily: _regular);
  static const IconData desktop = IconData(0xe560, fontFamily: _regular);
  static const IconData globe = IconData(0xe288, fontFamily: _regular);
  static const IconData server = IconData(0xe2a0, fontFamily: _regular);
  static const IconData fingerprint = IconData(0xe23e, fontFamily: _regular);
  static const IconData encrypted = IconData(0xe40c, fontFamily: _regular);
  static const IconData lock = IconData(0xe2fa, fontFamily: _regular);
  static const IconData key = IconData(0xe2d6, fontFamily: _regular);
  static const IconData qrCode = IconData(0xe3e6, fontFamily: _regular);
  static const IconData qrScanner = IconData(0xebb6, fontFamily: _regular);
  static const IconData cameraOff = IconData(0xe110, fontFamily: _regular);
  static const IconData flashOn = IconData(0xe246, fontFamily: _fill);
  static const IconData flashOff = IconData(0xe246, fontFamily: _regular);
  static const IconData sync = IconData(0xe094, fontFamily: _regular);
  static const IconData cloudOff = IconData(0xe1b6, fontFamily: _regular);
  static const IconData warning = IconData(0xe4e0, fontFamily: _fill);
  static const IconData error = IconData(0xe4e2, fontFamily: _fill);
  static const IconData haptics = IconData(0xe4d8, fontFamily: _regular);
}
