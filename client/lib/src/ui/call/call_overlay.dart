import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/services.dart';
import '../components/avatar.dart';
import '../l10n/strings.dart';
import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import 'call_media_controller.dart';

class CallOverlay extends StatefulWidget {
  const CallOverlay({
    super.key,
    required this.session,
    this.mediaControllerFactory,
  });

  final AccountSession session;
  final CallMediaControllerFactory? mediaControllerFactory;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  late CallMediaController _media;
  bool _minimized = false;
  bool _held = false;
  bool _busy = false;
  Timer? _ticker;
  int _elapsedSec = 0;
  String? _lastCallId;
  String? _startedMediaCallId;

  @override
  void initState() {
    super.initState();
    _initMediaController();
    widget.session.activeCall.addListener(_onCallChanged);
    _syncCallState(widget.session.activeCall.value);
  }

  void _initMediaController() {
    _media = (widget.mediaControllerFactory ?? _defaultMediaFactory)(widget.session);
    _media.addListener(_onMediaChanged);
  }

  static CallMediaController _defaultMediaFactory(AccountSession session) =>
      WebRtcCallMediaController(session);

  @override
  void didUpdateWidget(CallOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.activeCall.removeListener(_onCallChanged);
      _media.removeListener(_onMediaChanged);
      _media.dispose();
      _startedMediaCallId = null;
      _initMediaController();
      widget.session.activeCall.addListener(_onCallChanged);
      _syncCallState(widget.session.activeCall.value);
    }
  }

  @override
  void dispose() {
    widget.session.activeCall.removeListener(_onCallChanged);
    _media.removeListener(_onMediaChanged);
    _media.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  void _onMediaChanged() {
    if (mounted) setState(() {});
  }

  void _onCallChanged() {
    if (!mounted) return;
    _syncCallState(widget.session.activeCall.value);
    setState(() {});
  }

  void _syncCallState(ActiveCall? call) {
    if (call == null) {
      _ticker?.cancel();
      _ticker = null;
      _elapsedSec = 0;
      _minimized = false;
      _held = false;
      _busy = false;
      _lastCallId = null;
      if (_startedMediaCallId != null) {
        _startedMediaCallId = null;
        unawaited(_media.stop());
      }
      return;
    }
    if (_lastCallId != call.callId) {
      _lastCallId = call.callId;
      _minimized = false;
      _held = false;
      if (_startedMediaCallId != null && _startedMediaCallId != call.callId) {
        _startedMediaCallId = null;
        unawaited(_media.stop());
      }
    }
    final shouldStartMedia =
        call.direction == CallDirection.outgoing ||
        call.status == CallStatus.connecting ||
        call.status == CallStatus.active;
    if (shouldStartMedia && _startedMediaCallId != call.callId) {
      _startedMediaCallId = call.callId;
      unawaited(_media.start(callId: call.callId, media: call.media));
    }

    if (call.status == CallStatus.active && _ticker == null) {
      _updateElapsed(call);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final current = widget.session.activeCall.value;
        if (current != null) {
          setState(() => _updateElapsed(current));
        }
      });
    } else if (call.status != CallStatus.active && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
      _elapsedSec = 0;
    }
  }

  void _updateElapsed(ActiveCall call) {
    final start = call.answeredAt ?? call.startedAt;
    _elapsedSec = ((DateTime.now().millisecondsSinceEpoch - start) / 1000).floor().clamp(0, 86400);
  }

  String _formatDuration(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _statusLabel(BuildContext context, ActiveCall call) {
    switch (call.status) {
      case CallStatus.ringing:
        return call.direction == CallDirection.incoming
            ? context.tr('callIncoming')
            : context.tr('callRinging');
      case CallStatus.connecting:
        return context.tr('callConnecting');
      case CallStatus.active:
        return '${context.tr('callActive')} · ${_formatDuration(_elapsedSec)}';
      case CallStatus.ended:
        return context.tr('callHangup');
    }
  }

  String? _mediaHint(BuildContext context) {
    switch (_media.state) {
      case CallMediaState.idle:
        return null;
      case CallMediaState.connecting:
        return context.tr('callMediaConnecting');
      case CallMediaState.connected:
        return context.tr('callMediaConnected');
      case CallMediaState.failed:
        return _media.errorMessage?.isNotEmpty == true
            ? '${context.tr('callMediaFailed')}: ${_media.errorMessage}'
            : context.tr('callMediaFailed');
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.session.activeCall.value;
    if (call == null) return const SizedBox.shrink();

    final z = context.z;
    final darkBg = ZalosTokens.darkTokens.layerSubtle;
    final fg = z.textOnBrand;
    if (_minimized) {
      return Positioned(
        top: MediaQuery.paddingOf(context).top + ZSpace.s8,
        left: ZSpace.s16,
        right: ZSpace.s16,
        child: Material(
          color: z.success,
          borderRadius: BorderRadius.circular(ZRadius.input),
          elevation: 6,
          child: InkWell(
            key: const Key('callMinimizedBanner'),
            borderRadius: BorderRadius.circular(ZRadius.input),
            onTap: () => setState(() => _minimized = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: ZSpace.s8),
              child: Row(
                children: [
                  Icon(
                    call.media == CallMediaKind.video ? ZIcons.video : ZIcons.call,
                    color: fg,
                    size: 18,
                  ),
                  const SizedBox(width: ZSpace.s8),
                  Expanded(
                    child: Text(
                      '${call.peerName} · ${_statusLabel(context, call)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: z.text.body.copyWith(color: fg, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: ZSpace.s8),
                  Text(
                    context.tr('callReturn'),
                    style: z.text.caption.copyWith(color: fg.withValues(alpha: 0.9)),
                  ),
                  const SizedBox(width: ZSpace.s4),
                  IconButton(
                    key: const Key('callBannerHangup'),
                    icon: Icon(Icons.call_end, color: fg, size: 18),
                    tooltip: context.tr('callHangup'),
                    onPressed: _busy ? null : () => _runAction(() => widget.session.hangupCall(call.callId)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final isIncomingRinging =
        call.direction == CallDirection.incoming && call.status == CallStatus.ringing;
    final muted = _media.muted;
    final speaker = _media.speakerOn;
    final cameraOn = _media.cameraEnabled;
    final remoteRenderer = _media.remoteRenderer;
    final localRenderer = _media.localRenderer;
    final showRemoteVideo =
        call.media == CallMediaKind.video && _media.hasRemoteVideo && remoteRenderer != null;
    final showLocalPip =
        call.media == CallMediaKind.video &&
        _media.hasLocalVideo &&
        cameraOn &&
        localRenderer != null;
    final hint = _mediaHint(context);

    return Positioned.fill(
      child: Material(
        key: const Key('callOverlay'),
        color: darkBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showRemoteVideo)
              RTCVideoView(
                remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            if (showRemoteVideo)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      darkBg.withValues(alpha: 0.65),
                      darkBg.withValues(alpha: 0.15),
                      darkBg.withValues(alpha: 0.75),
                    ],
                  ),
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(ZSpace.s24),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 6),
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(ZRadius.pill),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                call.media == CallMediaKind.video ? ZIcons.video : ZIcons.call,
                                color: fg,
                                size: 14,
                              ),
                              const SizedBox(width: ZSpace.s4),
                              Text(
                                call.media == CallMediaKind.video
                                    ? context.tr('callVideo')
                                    : context.tr('callVoice'),
                                style: z.text.caption.copyWith(color: fg),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        if (showLocalPip)
                          Padding(
                            padding: const EdgeInsets.only(right: ZSpace.s8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(ZRadius.input),
                              child: SizedBox(
                                width: 88,
                                height: 124,
                                child: RTCVideoView(
                                  localRenderer,
                                  mirror: true,
                                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                                ),
                              ),
                            ),
                          ),
                        if (call.media == CallMediaKind.video && _media.hasLocalVideo)
                          IconButton(
                            key: const Key('callSwitchCameraButton'),
                            onPressed: () => unawaited(_media.switchCamera()),
                            tooltip: context.tr('callSwitchCamera'),
                            icon: Icon(Icons.cameraswitch, color: fg),
                          ),
                        IconButton(
                          key: const Key('callMinimizeButton'),
                          onPressed: () => setState(() => _minimized = true),
                          tooltip: context.tr('callMinimize'),
                          icon: Icon(ZIcons.chevronDown, color: fg),
                        ),
                      ],
                    ),
                    const Spacer(),
                    if (!showRemoteVideo) ...[
                      ZAvatar(
                        session: widget.session,
                        id: call.peerId,
                        name: call.peerName,
                        url: call.peerAvatarUrl ?? '',
                        size: 96,
                        group: call.isGroup,
                      ),
                      const SizedBox(height: ZSpace.s16),
                    ],
                    Text(
                      call.peerName,
                      key: const Key('callPeerName'),
                      textAlign: TextAlign.center,
                      style: z.text.display.copyWith(color: fg),
                    ),
                    const SizedBox(height: ZSpace.s8),
                    Text(
                      _statusLabel(context, call),
                      key: const Key('callStatusText'),
                      style: z.text.body.copyWith(color: fg.withValues(alpha: 0.85)),
                    ),
                    if (hint != null) ...[
                      const SizedBox(height: ZSpace.s12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: 6),
                        decoration: BoxDecoration(
                          color: (_media.state == CallMediaState.failed ? z.danger : fg)
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(ZRadius.row),
                        ),
                        child: Text(
                          hint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: z.text.caption.copyWith(color: fg.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (isIncomingRinging)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _CallCircleButton(
                                key: const Key('callDeclineButton'),
                                icon: Icons.call_end,
                                label: context.tr('callDecline'),
                                background: z.danger,
                                onTap: _busy
                                    ? null
                                    : () => _runAction(() => widget.session.rejectCall(call.callId)),
                              ),
                              _CallCircleButton(
                                key: const Key('callAcceptButton'),
                                icon: call.media == CallMediaKind.video ? ZIcons.video : ZIcons.call,
                                label: context.tr('callAccept'),
                                background: z.success,
                                onTap: _busy
                                    ? null
                                    : () => _runAction(() => widget.session.acceptCall(call.callId)),
                              ),
                            ],
                          ),
                          const SizedBox(height: ZSpace.s16),
                          TextButton.icon(
                            key: const Key('callSilenceButton'),
                            onPressed: _busy
                                ? null
                                : () => _runAction(
                                      () => widget.session.rejectCall(call.callId, localOnly: true),
                                    ),
                            icon: Icon(ZIcons.bellOff, color: fg.withValues(alpha: 0.85), size: 18),
                            label: Text(
                              context.tr('callSilence'),
                              style: z.text.body.copyWith(color: fg.withValues(alpha: 0.85)),
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceEvenly,
                            spacing: ZSpace.s16,
                            runSpacing: ZSpace.s12,
                            children: [
                              _CallCircleButton(
                                key: const Key('callMuteButton'),
                                icon: muted ? Icons.mic_off : ZIcons.mic,
                                label: muted ? context.tr('callUnmute') : context.tr('callMute'),
                                background: muted ? fg : fg.withValues(alpha: 0.16),
                                iconColor: muted ? darkBg : fg,
                                onTap: () => unawaited(_media.setMuted(!muted)),
                              ),
                              if (call.media == CallMediaKind.video)
                                _CallCircleButton(
                                  key: const Key('callCameraButton'),
                                  icon: cameraOn ? ZIcons.video : ZIcons.cameraOff,
                                  label: cameraOn
                                      ? context.tr('callCameraOn')
                                      : context.tr('callCameraOff'),
                                  background: !cameraOn ? fg : fg.withValues(alpha: 0.16),
                                  iconColor: !cameraOn ? darkBg : fg,
                                  onTap: () => unawaited(_media.setCameraEnabled(!cameraOn)),
                                ),
                              _CallCircleButton(
                                key: const Key('callSpeakerButton'),
                                icon: Icons.volume_up,
                                label: context.tr('callSpeaker'),
                                background: speaker ? fg : fg.withValues(alpha: 0.16),
                                iconColor: speaker ? darkBg : fg,
                                onTap: () => unawaited(_media.setSpeaker(!speaker)),
                              ),
                              _CallCircleButton(
                                key: const Key('callHoldButton'),
                                icon: _held ? ZIcons.play : ZIcons.pause,
                                label: _held ? context.tr('callResume') : context.tr('callHold'),
                                background: _held ? fg : fg.withValues(alpha: 0.16),
                                iconColor: _held ? darkBg : fg,
                                onTap: () => _runAction(() async {
                                  final next = !_held;
                                  await widget.session.callHold(
                                    call.callId,
                                    peerId: call.peerId,
                                    hold: next,
                                  );
                                  if (mounted) setState(() => _held = next);
                                }),
                              ),
                              if (call.media == CallMediaKind.voice)
                                _CallCircleButton(
                                  key: const Key('callSwitchVideoButton'),
                                  icon: ZIcons.video,
                                  label: context.tr('callSwitchVideo'),
                                  background: fg.withValues(alpha: 0.16),
                                  onTap: () => _runAction(
                                    () => widget.session.callSwitchMedia(
                                      call.callId,
                                      peerId: call.peerId,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: ZSpace.s24),
                          _CallCircleButton(
                            key: const Key('callHangupButton'),
                            icon: Icons.call_end,
                            label: context.tr('callHangup'),
                            background: z.danger,
                            onTap: _busy
                                ? null
                                : () => _runAction(() => widget.session.hangupCall(call.callId)),
                          ),
                        ],
                      ),
                    const SizedBox(height: ZSpace.s16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallCircleButton extends StatelessWidget {
  const _CallCircleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.background,
    this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final effectiveIconColor = iconColor ?? z.textOnBrand;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(icon, color: effectiveIconColor, size: 26),
            ),
          ),
        ),
        const SizedBox(height: ZSpace.s8),
        Text(
          label,
          style: z.text.caption.copyWith(color: z.textOnBrand.withValues(alpha: 0.9)),
        ),
      ],
    );
  }
}
