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

class KumaPlayerController extends ValueNotifier<VideoPlayerValue> {

  VideoPlayerController _playerController;
  ProxyItem proxyItem;
  Completer<void> _readyCompleter = Completer();
  bool _disposed = false;

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
  }

  void _startUrl(String url, void Function(String) cb) async {
    ProxyServer server = await ProxyServer.instance;
    proxyItem = server.get(url);
    if (!_disposed)
      cb("http://localhost:${server.server.port}/${proxyItem.key}/${proxyItem.entry}");
  }

  void _updateValue() {
    this.value = _playerController.value;
  }

  void _ready() {
    _readyCompleter?.complete();
    _readyCompleter = null;
  }

  @override
  void dispose() {
    super.dispose();
    proxyItem?.dispose();
    _playerController?.dispose();
    _disposed = true;
  }

  Future<void> prepared() {
    if (_readyCompleter != null) return _readyCompleter.future;
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

class _KumaPlayerState extends State<KumaPlayer> with WidgetsBindingObserver {
  bool _overlay = false;

  static const platform = const MethodChannel('kuma_player');

  @override
  Widget build(BuildContext context) {
    return widget.controller?._playerController == null ? Container() : VideoPlayer(widget.controller._playerController);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setOverlay(widget.overlay);

    widget.controller.prepared().then((value) {
      setState(() { });
    });
  }

  @override
  void didUpdateWidget(KumaPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overlay != widget.overlay) {
      _setOverlay(widget.overlay);
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
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<bool> canOverlay() {
    return platform.invokeMethod<bool>("canOverlay");
  }

  Future<void> _setOverlay(bool overlay) async {
    if (Platform.isAndroid) {
      _overlay = overlay;
      if (_overlay) {
        if (!await canOverlay()) {
          await showDialog(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: Text(widget.overlayAlert),
                  actions: [
                    FlatButton(
                        child: Text(widget.overlayButton),
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
    VideoPlayerController playerController = widget.controller?._playerController;
    if (playerController == null) return;
    switch (state) {
      case AppLifecycleState.paused: {
        if (_overlay && await canOverlay()) {
          // ignore: invalid_use_of_visible_for_testing_member
          await platform.invokeMethod("requestOverlay", {"textureId": playerController.textureId});
          playerController.play();
        }
      }
        break;
      case AppLifecycleState.resumed:
        if (_overlay) {
          // ignore: invalid_use_of_visible_for_testing_member
          platform.invokeMethod("removeOverlay", {"textureId": playerController.textureId});
        }
        break;
      case AppLifecycleState.detached: {
        break;
      }
      default:
    }
  }


}