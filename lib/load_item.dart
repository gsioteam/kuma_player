import 'dart:convert';

import 'proxy_server.dart';
import 'request_queue.dart';
import 'dart:math' as math;

class LoadItem {
  bool _loaded;
  int _weight;
  RequestItem Function() _requestItemBuilder;
  ProxyItem _proxyItem;
  void Function(int) onLoadData;

  String cacheKey;

  bool get loaded => _loaded;
  int get weight => _weight;
  dynamic data;

  LoadItem({
    this.cacheKey,
    ProxyItem proxyItem,
    int weight,
    RequestItem Function() builder,
    this.data
  }) : _proxyItem = proxyItem, _weight = weight, _requestItemBuilder = builder {
    _loaded = _proxyItem.server.cacheManager.contains(this.cacheKey);
  }

  Stream<List<int>> read([int start = 0, int end = -1]) async* {
    if (_proxyItem.server.cacheManager.contains(this.cacheKey)) {
      List<int> buffer = await _proxyItem.server.cacheManager.load(this.cacheKey);
      if (start != 0 || end > 0) {
        yield buffer.sublist(start, end > 0 ? end : null);
      } else {
        yield buffer;
      }
    } else {
      RequestItem item = _requestItemBuilder();
      if (item.method.toUpperCase() == "HEAD") {
        var response = await item.getResponse();
        String json = jsonEncode(response.headers);
        List<int> buf = utf8.encode(json);
        yield buf;
        onLoadData?.call(buf.length);
        _onComplete([buf]);
      } else {
        item.onComplete = _onComplete;
        var response = await item.getResponse();
        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (end < 0) end = response.contentLength;
          const int BLK_SIZE = 4096;
          for (int offset = start; offset < end; offset += BLK_SIZE) {
            var buf = await item.readPart(offset, math.min(end, offset + BLK_SIZE));
            onLoadData?.call(buf.length);
            yield buf;
          }
        } else {
          throw "Request $data failed code:${response.statusCode}";
        }
      }
    }
  }

  void _onComplete(List<List<int>> chunks) {
    _loaded = true;
    _proxyItem.server.cacheManager.insert(cacheKey, chunks.expand((e) => e).toList());
    _proxyItem.itemLoaded(this, chunks);
  }
}