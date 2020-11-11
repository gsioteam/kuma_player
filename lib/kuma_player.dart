// You have generated a new plugin project without
// specifying the `--platforms` flag. A plugin project supports no platforms is generated.
// To add platforms, run `flutter create -t plugin --platforms <platforms> .` under the same
// directory. You can also find a detailed instruction on how to add platforms in the `pubspec.yaml` at https://flutter.dev/docs/development/packages-and-plugins/developing-packages#plugin-platforms.


import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'proxy_server.dart';

const platform = const MethodChannel('kuma_player');

class KumaPlayerController extends ValueNotifier<VideoPlayerValue> with WidgetsBindingObserver {
  bool _overlay = false;
  VideoPlayerController _playerController;
  ProxyItem _proxyItem;
  Completer<void> _readyCompleter = Completer();
  bool _disposed = false;

  ProxyItem get proxyItem => _proxyItem;

  bool get ready => _readyCompleter.isCompleted;

  KumaPlayerController.asset(String dataSource,
      {String package, Future<ClosedCaptionFile>
      closedCaptionFile, VideoPlayerOptions
      videoPlayerOptions}) : super(VideoPlayerValue(duration: null)) {
    _playerController = VideoPlayerController.asset(
        dataSource,
        package: package,
        closedCaptionFile: closedCaptionFile,
        videoPlayerOptions: videoPlayerOptions
    );
    _playerController.addListener(_updateValue);
    _playerController.initialize().then((value) => _ready());
    WidgetsBinding.instance.addObserver(this);
  }


  KumaPlayerController.file(File file,
      {Future<ClosedCaptionFile> closedCaptionFile,
        VideoPlayerOptions videoPlayerOptions}) : super(VideoPlayerValue(duration: null)) {
    _playerController = VideoPlayerController.file(
        file,
        closedCaptionFile: closedCaptionFile,
        videoPlayerOptions: videoPlayerOptions
    );
    _playerController.addListener(_updateValue);
    _playerController.initialize().then((value) => _ready());
    WidgetsBinding.instance.addObserver(this);
  }

  KumaPlayerController.network(String dataSource,
      {VideoFormat formatHint,
        Future<ClosedCaptionFile> closedCaptionFile,
        VideoPlayerOptions videoPlayerOptions}) : super(VideoPlayerValue(duration: null)) {
    _startUrl(dataSource, (url) {
      _playerController = VideoPlayerController.network(
        url,
        formatHint: formatHint,
        closedCaptionFile: closedCaptionFile,
        videoPlayerOptions: videoPlayerOptions
      );
      _playerController.addListener(_updateValue);
      _playerController.initialize().then((value) => _ready());
    });
    WidgetsBinding.instance.addObserver(this);
  }

  void _startUrl(String url, void Function(String) cb) async {
    ProxyServer server = await ProxyServer.instance;
    _proxyItem = server.get(url);
    proxyItem.retain();
    for (var cb in _onSpeeds) proxyItem.addOnSpeed(cb);
    for (var cb in _onBuffered) proxyItem.addOnBuffered(cb);
    if (!_disposed)
      cb("http://localhost:${server.server.port}/${proxyItem.key}/${proxyItem.entry}");
  }

  void _updateValue() {
    this.value = _playerController.value;
  }

  void _ready() {
    _readyCompleter?.complete();
  }

  List<BufferedRange> get buffered => proxyItem?.buffered ?? [];

  @override
  void dispose() {
    super.dispose();
    for (var cb in _onSpeeds) proxyItem.removeOnSpeed(cb);
    for (var cb in _onBuffered) proxyItem.removeOnBuffered(cb);
    proxyItem?.release();
    _playerController?.dispose();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> prepared() {
    if (!_readyCompleter.isCompleted) return _readyCompleter.future;
    return SynchronousFuture(null);
  }

  Future<void> play() {
    return _playerController?.play();
  }

  Future<void> pause() {
    return _playerController?.pause();
  }

  Future<void> setLooping(bool looping) {
    return _playerController?.setLooping(looping);
  }

  Future<Duration> get position {
    return _playerController?.position;
  }

  Future<void> seekTo(Duration position) {
    return _playerController?.seekTo(position);
  }

  Future<void> setVolume(double volume) {
    return _playerController?.setVolume(volume);
  }

  Future<void> setPlaybackSpeed(double speed) {
    return _playerController?.setPlaybackSpeed(speed);
  }

  List<void Function(int)> _onSpeeds = [];
  List<void Function()> _onBuffered = [];

  void addOnSpeed(void Function(int) cb) {
    _onSpeeds.add(cb);
    proxyItem?.addOnSpeed(cb);
  }
  void removeOnSpeed(void Function(int) cb) {
    _onSpeeds.remove(cb);
    proxyItem?.removeOnSpeed(cb);
  }

  void addOnBuffered(VoidCallback cb) {
    _onBuffered.add(cb);
    proxyItem?.addOnBuffered(cb);
  }
  void removeOnBuffered(VoidCallback cb) {
    _onBuffered.remove(cb);
    proxyItem?.removeOnBuffered(cb);
  }

  Future<void> _setOverlay(bool overlay, {
    BuildContext context,
    String overlayAlert,
    String overlayButton
  }) async {
    if (Platform.isAndroid) {
      _overlay = overlay;
      if (_overlay) {
        if (!await canOverlay()) {
          await showDialog(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: Text(overlayAlert),
                  actions: [
                    FlatButton(
                        child: Text(overlayButton),
                        onPressed: () {
                          Navigator.of(context).pop();
                        }
                    )
                  ],
                );
              }
          );
          await platform.invokeMethod("requestOverlayPermission");
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_playerController == null) return;
    switch (state) {
      case AppLifecycleState.paused: {
        bool isPlaying = _playerController.value.isPlaying;
        if (_playerController.value?.size != null && _overlay && await canOverlay()) {
          // ignore: invalid_use_of_visible_for_testing_member
          await platform.invokeMethod("requestOverlay", {"textureId": _playerController.textureId});
          if (isPlaying) _playerController.play();
        }
      }
      break;
      case AppLifecycleState.resumed:
        if (_overlay) {
          // ignore: invalid_use_of_visible_for_testing_member
          bool isPlaying = await platform.invokeMethod<bool>("removeOverlay", {"textureId": _playerController.textureId});
          if (_playerController.value.isPlaying != isPlaying) {
            _playerController.value = _playerController.value.copyWith(isPlaying: isPlaying);
          }
        }
        break;
      case AppLifecycleState.detached: {
        break;
      }
      default:
    }
  }

  Future<bool> canOverlay() {
    return platform.invokeMethod<bool>("canOverlay");
  }

}

class KumaPlayer extends StatefulWidget {
  final bool overlay;
  final String overlayAlert;
  final String overlayButton;
  final KumaPlayerController controller;

  KumaPlayer({
    this.overlay = false,
    this.overlayAlert = "",
    this.overlayButton = "",
    @required this.controller
  });

  @override
  State<StatefulWidget> createState() => _KumaPlayerState();

}

class _KumaPlayerState extends State<KumaPlayer> {

  @override
  Widget build(BuildContext context) {
    return widget.controller?._playerController == null ? Container() : VideoPlayer(widget.controller._playerController);
  }

  @override
  void initState() {
    super.initState();

    widget.controller._setOverlay(
      widget.overlay,
      context: context,
      overlayAlert: widget.overlayAlert,
      overlayButton: widget.overlayButton
    );
    widget.controller.prepared().then((value) {
      try {
        setState(() { });
      } catch (e) {
      }
    });
  }

  @override
  void didUpdateWidget(KumaPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overlay != widget.overlay) {
      widget.controller._setOverlay(
          widget.overlay,
          context: context,
          overlayAlert: widget.overlayAlert,
          overlayButton: widget.overlayButton
      );
    }
    if (oldWidget.controller != widget.controller) {
      widget.controller.prepared().then((value) {
        setState(() { });
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}