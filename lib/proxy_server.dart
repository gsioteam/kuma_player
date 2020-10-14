
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http_multi_server/http_multi_server.dart';
import 'package:shelf/shelf.dart';
import 'cache_manager.dart';
import 'request_queue.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as platform;
import 'package:mime/mime.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

String _calculateKey(String url) {
  var hash = crypto.sha256.convert(utf8.encode(url));
  return hash.toString();
}

class ProxyData {
  String url;

  ProxyData(this.url);
}

class ResponseRange {
  int total;
  int start;
  int end;

  ResponseRange({this.total, this.start, this.end});
}

class _RangeData {
  int start, end;

  _RangeData(this.start, this.end);
}
class ResponseData {
  dynamic body;
  Map<String, Object> headers;
  ResponseRange range;

  ResponseData({
    this.body,
    this.headers,
    this.range
  });
}

_RangeData _getRange(Map<String, String> headers) {
  String range = headers["Range"] ?? headers["range"];
  if (range != null) {
    int start = 0, end = -1;
    var words = range.split('=');
    if (words.length == 2) {
      words = words[1].split('-');
      if (words.length == 2) {
        start = int.tryParse(words[0]) ?? 0;
        end = int.tryParse(words[1]) ?? -1;
        if (end != -1) end++;
      }
    }
    return _RangeData(start, end);
  } else {
    return null;
  }
}

abstract class ProxyItem {
  Uri _url;
  String _base;
  String _key;
  String _entry;
  Map<String, ProxyData> _files = Map();
  ProxyServer _server;
  RequestQueue _queue = RequestQueue();
  Uri get url => _url;
  String get base => _base;
  String get key => _key;
  String get entry => _entry;
  ProxyServer get server => _server;

  ProxyItem._(String url) {
    int index = url.lastIndexOf("/");
    if (index < 0) {
      throw "Wrong url $_url";
    }
    _entry = url.substring(index + 1);
    _base = url.substring(0, index + 1);
    _url = Uri.parse(url);
    _key = _calculateKey(url);
    _files[entry] = ProxyData(url);
  }

  factory ProxyItem(String url) {
    int idx = url.indexOf('?');
    String raw;
    if (idx >= 0) {
      raw = url.substring(0, idx - 1);
    } else if ((idx = url.indexOf('#')) >= 0) {
      raw = url.substring(0, idx - 1);
    } else {
      raw = url;
    }
    String filename = raw.substring(raw.lastIndexOf('/') + 1);
    idx = filename.lastIndexOf('\.');
    String ext;
    if (idx >= 0) {
      ext = filename.substring(idx + 1).toLowerCase();
    }
    if (ext == "m3u8") {
      return HlsProxyItem._(url);
    } else {
      return SingleProxyItem._(url);
    }
  }

  Future<Response> handle(Request request, String key);

  void dispose() {
    server._removeItem(this);
  }
}

enum ParseState {
  Line,
  Url
}

class HlsProxyItem extends ProxyItem {

  Map<Uri, String> cached = Map();

  HlsProxyItem._(String url) : super._(url);

  String getFileEntry(String url) {
    int index;
    String rawUrl;
    if ((index = url.indexOf("?")) > 0) {
      rawUrl = url.substring(0, index);
    } else if ((index = url.indexOf("#")) > 0) {
      rawUrl = url.substring(0, index);
    } else {
      rawUrl = url;
    }
    if (rawUrl.indexOf(base) == 0) {
      return rawUrl.replaceFirst(base, "");
    } else {
      int lastIndex = rawUrl.lastIndexOf('/');
      if (lastIndex < 0) {
        throw "Wrong url $url";
      }
      String filename = rawUrl.substring(lastIndex + 1);
      String prePath = rawUrl.substring(0, lastIndex + 1);
      String key = _calculateKey(prePath);
      key = key + '/' + filename;
      return key;
    }
  }

  String _insertFile(String url) {
    String entry = getFileEntry(url);
    _files[entry] = ProxyData(url);
    return entry;
  }

  Response _createResponse(Request request, ResponseData Function(ResponseData) creator) {
    String mimeType = lookupMimeType(request.handlerPath);
    String range = request.headers['range'] ?? request.headers['Range'];
    int start = 0, end = -1;
    int statusCode = 200;
    if (range != null) {
      var words = range.split('=');
      if (words.length == 2) {
        words = range[1].split('-');
        if (words.length == 2) {
          start = int.tryParse(words[0]) ?? 0;
          end = int.tryParse(words[1]) ?? -1;
          statusCode = 206;
        }
      }
    }

    var responseData = creator(ResponseData(
      headers: {
        "Content-Type": mimeType,
      },
      range: ResponseRange(
        start: start,
        end: end
      )
    ));
    if (range != null) {
      responseData.headers["Content-Range"] = "bytes ${responseData.range.start ?? 0}-${responseData.range.end == -1 ? (responseData.range.total - 1) : responseData.range.end}/${responseData.range.total ?? ""}";
    }
    responseData.headers["Content-Length"] = "${(responseData.range.end == -1 ? responseData.range.total : (responseData.range.end + 1)) - (responseData.range.start ?? 0)}";
    var res = Response(statusCode,
        body: responseData.body,
        headers: responseData.headers
    );
    return res;
  }

  Stream<List<int>> _getStream(RequestItem item, String cacheKey, int start, int end) async* {
    int offset = start;
    while (offset < end) {
      int eoff = math.min(offset + 4096, end);
      yield await item.readPart(offset, eoff);
      offset = eoff;
    }

    server.cacheManager.insert(cacheKey, item.chunks.expand((element) => element).toList());
  }

  String handleUrl(String url) {
    return _insertFile(url);
  }

  //  static const RegExp
  static const String URI_STATE = "URI=\"";

  String parseHls(Uri uri, String body) {
    String content = cached[uri];
    if (content != null) return content;

    var lines = body.split("\n");
    List<String> newLines = [];
    ParseState state = ParseState.Line;
    lines.forEach((line) {
      int index = 0;
      switch (state) {
        case ParseState.Line: {

          if ((index = line.indexOf(URI_STATE)) >= 0) {
            String begin = line.substring(0, index + URI_STATE.length);
            String tail;
            bool transform = false;
            StringBuffer sb = StringBuffer();
            for (int off = index + URI_STATE.length; off < line.length; ++off) {
              String ch = line[off];
              if (transform) {
                sb.write(ch);
                transform = false;
              } else {
                if (ch == '\\') {
                  transform = true;
                } else if (ch == '"') {
                  tail = line.substring(off);
                  break;
                } else {
                  sb.write(ch);
                }
              }
            }

            newLines.add(begin + uri.resolve(sb.toString()).toString().replaceAll('"', '\\"') + tail);
          } else if (line.indexOf("#EXT-X-STREAM-INF:") == 0 ||
              line.indexOf("#EXTINF:") == 0) {
            state = ParseState.Url;
            newLines.add(line.trim());
          } else {
            newLines.add(line.trim());
          }
          break;
        }
        case ParseState.Url: {
          state = ParseState.Line;
          newLines.add(handleUrl(uri.resolve(line.trim()).toString()));
          break;
        }

        default:
          break;
      }
    });

    content = newLines.join("\n");
    cached[uri] = content;
    return content;
  }

  @override
  Future<Response> handle(Request request, String path) async {
    if (_files.containsKey(path)) {
      String ext = p.extension(path)?.toLowerCase();
      String cacheKey = "${this.key}/$path";
      if (ext == ".m3u8") {
        String url = _files[path].url;
        String body;
        if (_server.cacheManager.contains(cacheKey)) {
          Uint8List data = await _server.cacheManager.load(cacheKey);
          body = utf8.decode(data);
        } else {
          RequestItem item = _queue.start(url);
          List<List<int>> chunks = await item.read();
          var buf = Uint8List.fromList(chunks.expand<int>((element) => element).toList());
          body = utf8.decode(buf);
          _server.cacheManager.insert(cacheKey, buf);
        }

        body = parseHls(Uri.parse(url), body);
        
        return _createResponse(request, (data) {
          data.body = body;
          data.range.total = body.length;
          return data;
        });
      } else {
        String url = _files[path].url;
        if (_server.cacheManager.contains(cacheKey)) {
          Uint8List body = await _server.cacheManager.load(cacheKey);
          return _createResponse(request, (data) {
            data.body = body;
            data.range.total = body.length;
            data.range.start = 0;
            data.range.end = -1;
            return data;
          });
        } else {
          RequestItem item = _queue.start(url);
          http.StreamedResponse response = await item.getResponse();
          return _createResponse(request, (data) {
            data.body = _getStream(item, cacheKey, 0, response.contentLength);
            data.range.total = response.contentLength;
            data.range.start = 0;
            data.range.end = -1;
            return data;
          });
        }
      }
    } else {
      return Response.notFound(null);
    }
  }
}

class SingleProxyItem extends ProxyItem {

  static const int STREAM_LENGTH = 2 * 1024;
  static const int BLOCK_LENGTH = 5 * 1024 * 1024;
  int contentLength;
  bool canSeek;

  String _cacheKey;
  String get cacheKey {
    if (_cacheKey == null) {
      _cacheKey = "${this.key}/$entry";
    }
    return _cacheKey;
  }

  SingleProxyItem._(String url) : super._(url);

  Future<void> getResponse() async {
    String indexKey = "${this.cacheKey}/index";
    if (contentLength == null) {
      Uint8List indexBuf;
      if (server.cacheManager.contains(indexKey)) {
        indexBuf = await server.cacheManager.load(indexKey);
        Map<String, dynamic> index = jsonDecode(utf8.decode(indexBuf));
        contentLength = index["length"];
        canSeek = index["canSeek"];
      } else {
        String urlStr = url.toString();
        RequestItem item = _queue.start(urlStr,
            key: urlStr + "#index#",
            method: "HEAD",
            headers: {
              "Range": "bytes=0-"
            }
        );
        http.StreamedResponse response = await item.getResponse();
        if (response.statusCode >= 200 && response.statusCode < 300) {
          contentLength = response.contentLength;
          canSeek = response.headers.containsKey("accept-ranges") || response.headers.containsKey("Accept-Ranges");
        } else {
          throw "Request failed ${response.statusCode}";
        }
        String json = jsonEncode({
          "length": contentLength,
          "canSeek": canSeek
        });
        server.cacheManager.insert(indexKey, utf8.encode(json));
      }
    }
  }

  Stream<List<int>> requestRange(_RangeData range) async* {
    int offset = range.start;
    String urlStr = url.toString();
    while ((offset < range.end || range.end == -1) && offset < contentLength) {
      int blockIndex = (offset / BLOCK_LENGTH).floor();
      int blockStart = blockIndex * BLOCK_LENGTH, blockEnd = blockStart + BLOCK_LENGTH;

      blockEnd = math.min(blockEnd, contentLength);

      String cacheKey = "${this.cacheKey}/$blockIndex";
      if (server.cacheManager.contains(cacheKey)) {
        var buf = await server.cacheManager.load(cacheKey);
        var start = offset - blockStart, end = (range.end > 0 ? math.min(blockEnd, range.end) : blockEnd) - blockStart;
        if (start != 0 || end != blockEnd) {
          buf = buf.sublist(start, end);
        }
        yield buf;
        offset += buf.length;
      } else {
        RequestItem item = _queue.start(urlStr,
            key: urlStr + "#$blockIndex#",
            headers: {
              "Range": "bytes=$blockStart-${blockEnd - 1}"
            }
        );
//        print("[R] ${urlStr + "#$blockIndex#"}");
        item.onComplete = (chunks) {
          server.cacheManager.insert(cacheKey, chunks.expand((e) => e).toList());
        };

        while (offset < blockEnd) {
          int reqEnd = math.min(blockEnd, offset + STREAM_LENGTH);
          var buf = await item.readPart(offset - blockStart, reqEnd - blockStart);
          yield buf;
          offset += buf.length;
        }
      }
    }
  }

  @override
  Future<Response> handle(Request request, String path) async {
    if (_files.containsKey(path)) {
      _RangeData range = _getRange(request.headers);
      bool hasRange = range != null;
      await getResponse();
      if (range == null) {
        range = _RangeData(0, -1);
      }
      var body = requestRange(range);
      var headers = {
        "Content-Type": lookupMimeType(path),
        "Content-Length": "${(range.end == -1 ? contentLength : range.end) - range.start}"
      };
      if (hasRange) {
        headers["Content-Range"] = "bytes ${range.start}-${range.end == -1 ? (contentLength - 1) : (range.end - 1)}/$contentLength";
      }
      Response res = Response(hasRange ? 206 : 200,
          body: body,
          headers: headers
      );
      return res;
    } else {
      return Response.notFound(null);
    }
  }
}

class ProxyServer {
  static ProxyServer _instance;

  HttpMultiServer server;
  Map<String, ProxyItem> items = Map();
  Directory dir;
  CacheManager cacheManager;

  static Future<ProxyServer> get instance async {
    if (_instance == null) {
      _instance = ProxyServer();
      await _instance.setup();
    }
    return _instance;
  }

  Future<void> setup() async {
    dir = await platform.getApplicationSupportDirectory();
    cacheManager = CacheManager(dir);

    server = await HttpMultiServer.loopback(0);
    shelf_io.serveRequests(server, (request) {
      print("[${request.method}] ${request.requestedUri}");
      print(request.headers);
      var segs = request.requestedUri.path.split("/");
      String key;
      int split = 0;
      for (String seg in segs) {
        split++;
        if (seg.isNotEmpty) {
          key = seg;
          break;
        } else {
        }
      }
      ProxyItem item = items[key];
      if (item != null) {
        return item.handle(request, segs.sublist(split).join("/"));
      } else {
        return Response.notFound("${request.requestedUri.path} no resource");
      }
    });
  }

  ProxyItem get(String url) {
    String key = _calculateKey(url);
    ProxyItem item = items[key];
    if (item == null) {
      item = ProxyItem(url);
      items[key] = item;
      item._server = this;
    }
    return item;
  }

  void _removeItem(ProxyItem item) {
    items.remove(item.key);
  }
}
