

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:kuma_player/load_item.dart';
import 'package:kuma_player/proxy_server.dart';

enum DownloadState {
  Stop,
  Downloading,
  Complete
}

class VideoDownloader {
  ProxyItem _proxyItem;
  Completer<void> _readyCompleter = Completer();
  double _progress = 0;
  bool _progressDirty = true;
  bool _dependDirty = false;
  bool _invalidate = false;
  DownloadState _state = DownloadState.Stop;

  ProxyItem get proxyItem => _proxyItem;

  VoidCallback onProgress;
  VoidCallback onSpeed;
  VoidCallback onState;
  void Function(Error) onError;

  bool get isReady => _readyCompleter.isCompleted;

  bool _loading = false;

  VideoDownloader(String url) {
    _setup(url);
  }

  void _setup(String url) async {
    ProxyServer server = await ProxyServer.instance;
    if (!_invalidate) {
      _proxyItem = server.get(url);
      _proxyItem.retain();

      await _proxyItem.checkBuffered();
      int count = 0;
      for (var item in _proxyItem.loadItems) {
        if (item.loaded) count++;
      }
      if (count == _proxyItem.loadItems.length) {
        _state = DownloadState.Complete;
        onState?.call();
      }

      _proxyItem.addOnBuffered(_onBuffered);
      _proxyItem.addOnSpeed(_onSpeed);
      _readyCompleter.complete();
    }
  }

  Future<void> prepared() async {
    if (_readyCompleter.isCompleted) {
      return SynchronousFuture(null);
    } else {
      return _readyCompleter.future;
    }
  }

  void dispose() {
    _proxyItem?.removeOnSpeed(_onSpeed);
    _proxyItem?.removeOnBuffered(_onBuffered);
    _proxyItem?.release();
    _invalidate = true;
  }

  void _onBuffered() {
    if (_state == DownloadState.Downloading) {
      _progressDirty = true;
      onProgress?.call();
    } else {
      _dependDirty = true;
    }
  }

  double get progress {
    if (_progressDirty && _proxyItem != null) {
      var buffered = _proxyItem.buffered;
      _progress = 0;
      for (var part in buffered) {
        _progress += (part.end - part.start);
      }
      _progressDirty = false;
    }
    return _progress;
  }

  DownloadState get state => _state;

  void checkState() {
    if (_state == DownloadState.Downloading) {
      if (_dependDirty) {
        _dependDirty = false;
        _onBuffered();
      }
      _startDownload();
    }
  }

  Future<void> _startDownload() async {
    if (!_loading) {
      _loading = true;

      try {
        int count = 0;
        for (int i = 0; i < proxyItem.loadItems.length; ++i) {
          LoadItem item = proxyItem.loadItems[i];
          if (!item.loaded) {
            var stream = item.read();
            List<int> list = [];
            await for (var buf in stream) {
              if (_state != DownloadState.Downloading) {
                break;
              }
              list.addAll(buf);
            }
            proxyItem.processBuffer(item, list);
            count++;
          } else {
            count++;
          }
          if (_state != DownloadState.Downloading) {
            break;
          }
        }
        if (count == proxyItem.loadItems.length) {
          _state = DownloadState.Complete;
          onState?.call();
          onSpeed?.call();
        }
      } catch (e) {
        onError?.call(e);
      }

      _loading = false;
    }
  }

  void start() {
    if (_state == DownloadState.Stop) {
      _state = DownloadState.Downloading;
      onState?.call();
      checkState();
    }
  }

  void stop() {
    if (_state == DownloadState.Downloading) {
      _state = DownloadState.Stop;
      onState?.call();
      onSpeed?.call();
    }
  }

  Queue<int> _speeds = Queue();
  void _onSpeed(int speed) {
    if (_state == DownloadState.Downloading) {
      _speeds.add(speed);
      while (_speeds.length > 10) {
        _speeds.removeFirst();
      }
      onSpeed?.call();
    }
  }

  int get speed {
    if (_state == DownloadState.Downloading) {
      int total = 0;
      for (var speed in _speeds) {
        total += speed;
      }
      if (_speeds.length == 0) return 0;
      return (total / _speeds.length).round();
    } else {
      return 0;
    }
  }
}