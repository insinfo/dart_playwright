// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/har.ts

/// The HAR 1.2 log, reader side.
///
/// See http://www.softwareishard.com/blog/har-12-spec/. The recorder side of
/// this port writes the same shapes from
/// `playwright_core/lib/src/server/trace/har_tracer.dart`; what lives here is
/// the parser the trace model needs, because `trace.network` is a stream of
/// HAR entries and the snapshot renderer serves its resources out of them.
///
/// Every `_`-prefixed field is a Playwright extension to the spec.
library;

/// Reads an `int` that a trace may have serialized as a double.
int? _int(Object? value) => (value as num?)?.toInt();

/// Reads a `double` that a trace may have serialized as an int.
double? _double(Object? value) => (value as num?)?.toDouble();

List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) parse) =>
    (value as List?)
        ?.map((e) => parse((e as Map).cast<String, dynamic>()))
        .toList() ??
    <T>[];

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `HARFile`: the top-level document of a `.har` file.
class HarFile {
  HarLog log;

  HarFile({required this.log});

  factory HarFile.fromJson(Map<String, dynamic> json) => HarFile(
      log: HarLog.fromJson((json['log'] as Map).cast<String, dynamic>()));

  Map<String, dynamic> toJson() => {'log': log.toJson()};
}

/// `Log`: the body of a HAR file.
class HarLog {
  String version;
  HarCreator creator;
  HarBrowser? browser;
  List<HarPage>? pages;
  List<HarEntry> entries;
  String? comment;

  HarLog({
    required this.version,
    required this.creator,
    this.browser,
    this.pages,
    required this.entries,
    this.comment,
  });

  factory HarLog.fromJson(Map<String, dynamic> json) => HarLog(
        version: json['version'] as String,
        creator: HarCreator.fromJson(
            (json['creator'] as Map).cast<String, dynamic>()),
        browser: json['browser'] == null
            ? null
            : HarBrowser.fromJson(
                (json['browser'] as Map).cast<String, dynamic>()),
        pages: json['pages'] == null
            ? null
            : _list(json['pages'], HarPage.fromJson),
        entries: _list(json['entries'], HarEntry.fromJson),
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'creator': creator.toJson(),
        'browser': browser?.toJson(),
        'pages': pages?.map((e) => e.toJson()).toList(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'comment': comment,
      });
}

/// `Creator`: the tool that produced the log.
class HarCreator {
  String name;
  String version;
  String? comment;

  HarCreator({required this.name, required this.version, this.comment});

  factory HarCreator.fromJson(Map<String, dynamic> json) => HarCreator(
        name: json['name'] as String,
        version: json['version'] as String,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'name': name, 'version': version, 'comment': comment});
}

/// `Browser`: the browser that produced the log.
class HarBrowser {
  String name;
  String version;
  String? comment;

  HarBrowser({required this.name, required this.version, this.comment});

  factory HarBrowser.fromJson(Map<String, dynamic> json) => HarBrowser(
        name: json['name'] as String,
        version: json['version'] as String,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'name': name, 'version': version, 'comment': comment});
}

/// `Page`: one page of the log, referenced by [HarEntry.pageref].
class HarPage {
  String startedDateTime;
  String id;
  String title;
  HarPageTimings pageTimings;
  String? comment;

  HarPage({
    required this.startedDateTime,
    required this.id,
    required this.title,
    required this.pageTimings,
    this.comment,
  });

  factory HarPage.fromJson(Map<String, dynamic> json) => HarPage(
        startedDateTime: json['startedDateTime'] as String,
        id: json['id'] as String,
        title: json['title'] as String,
        pageTimings: HarPageTimings.fromJson(
            (json['pageTimings'] as Map).cast<String, dynamic>()),
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'startedDateTime': startedDateTime,
        'id': id,
        'title': title,
        'pageTimings': pageTimings.toJson(),
        'comment': comment,
      });
}

/// `PageTimings`.
class HarPageTimings {
  double? onContentLoad;
  double? onLoad;
  String? comment;

  HarPageTimings({this.onContentLoad, this.onLoad, this.comment});

  factory HarPageTimings.fromJson(Map<String, dynamic> json) => HarPageTimings(
        onContentLoad: _double(json['onContentLoad']),
        onLoad: _double(json['onLoad']),
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'onContentLoad': onContentLoad,
        'onLoad': onLoad,
        'comment': comment,
      });
}

/// `Entry`: one request/response pair.
///
/// This is also `ResourceSnapshot` of the trace format — a `resource-snapshot`
/// event carries exactly one of these.
class HarEntry {
  String? pageref;
  String startedDateTime;
  double time;
  HarRequest request;
  HarResponse response;
  HarCache cache;
  HarTimings timings;
  String? serverIPAddress;
  String? connection;
  String? frameref;
  double? monotonicTime;
  int? serverPort;
  HarSecurityDetails? securityDetails;
  bool? wasAborted;
  bool? wasFulfilled;
  bool? wasContinued;
  String? serviceWorkerRef;
  String? apiRequestRef;
  String? resourceType;
  List<HarWebSocketMessage>? webSocketMessages;

  HarEntry({
    this.pageref,
    required this.startedDateTime,
    required this.time,
    required this.request,
    required this.response,
    HarCache? cache,
    HarTimings? timings,
    this.serverIPAddress,
    this.connection,
    this.frameref,
    this.monotonicTime,
    this.serverPort,
    this.securityDetails,
    this.wasAborted,
    this.wasFulfilled,
    this.wasContinued,
    this.serviceWorkerRef,
    this.apiRequestRef,
    this.resourceType,
    this.webSocketMessages,
  })  : cache = cache ?? HarCache(),
        timings = timings ?? HarTimings(send: -1, wait: -1, receive: -1);

  factory HarEntry.fromJson(Map<String, dynamic> json) => HarEntry(
        pageref: json['pageref'] as String?,
        startedDateTime: json['startedDateTime'] as String? ?? '',
        time: _double(json['time']) ?? 0,
        request: HarRequest.fromJson(
            (json['request'] as Map).cast<String, dynamic>()),
        response: HarResponse.fromJson(
            (json['response'] as Map).cast<String, dynamic>()),
        cache: json['cache'] == null
            ? null
            : HarCache.fromJson((json['cache'] as Map).cast<String, dynamic>()),
        timings: json['timings'] == null
            ? null
            : HarTimings.fromJson(
                (json['timings'] as Map).cast<String, dynamic>()),
        serverIPAddress: json['serverIPAddress'] as String?,
        connection: json['connection'] as String?,
        frameref: json['_frameref'] as String?,
        monotonicTime: _double(json['_monotonicTime']),
        serverPort: _int(json['_serverPort']),
        securityDetails: json['_securityDetails'] == null
            ? null
            : HarSecurityDetails.fromJson(
                (json['_securityDetails'] as Map).cast<String, dynamic>()),
        wasAborted: json['_wasAborted'] as bool?,
        wasFulfilled: json['_wasFulfilled'] as bool?,
        wasContinued: json['_wasContinued'] as bool?,
        serviceWorkerRef: json['_serviceWorkerRef'] as String?,
        apiRequestRef: json['_apiRequestRef'] as String?,
        resourceType: json['_resourceType'] as String?,
        webSocketMessages: json['_webSocketMessages'] == null
            ? null
            : _list(json['_webSocketMessages'], HarWebSocketMessage.fromJson),
      );

  /// A copy whose response content points at [file].
  ///
  /// `SnapshotRenderer.resourceByUrl` patches the body of a resource with the
  /// override recorded for the snapshot being rendered, and it must not touch
  /// the stored entry, which other snapshots still serve unpatched.
  HarEntry copyWithResponseContentFile(String file) => HarEntry(
        pageref: pageref,
        startedDateTime: startedDateTime,
        time: time,
        request: request,
        response: HarResponse(
          status: response.status,
          statusText: response.statusText,
          httpVersion: response.httpVersion,
          cookies: response.cookies,
          headers: response.headers,
          content: HarContent(
            size: response.content.size,
            compression: response.content.compression,
            mimeType: response.content.mimeType,
            text: response.content.text,
            encoding: response.content.encoding,
            comment: response.content.comment,
            file: file,
          ),
          redirectURL: response.redirectURL,
          headersSize: response.headersSize,
          bodySize: response.bodySize,
          comment: response.comment,
          transferSize: response.transferSize,
          failureText: response.failureText,
        ),
        cache: cache,
        timings: timings,
        serverIPAddress: serverIPAddress,
        connection: connection,
        frameref: frameref,
        monotonicTime: monotonicTime,
        serverPort: serverPort,
        securityDetails: securityDetails,
        wasAborted: wasAborted,
        wasFulfilled: wasFulfilled,
        wasContinued: wasContinued,
        serviceWorkerRef: serviceWorkerRef,
        apiRequestRef: apiRequestRef,
        resourceType: resourceType,
        webSocketMessages: webSocketMessages,
      );

  Map<String, dynamic> toJson() => _compact({
        'pageref': pageref,
        'startedDateTime': startedDateTime,
        'time': time,
        'request': request.toJson(),
        'response': response.toJson(),
        'cache': cache.toJson(),
        'timings': timings.toJson(),
        'serverIPAddress': serverIPAddress,
        'connection': connection,
        '_frameref': frameref,
        '_monotonicTime': monotonicTime,
        '_serverPort': serverPort,
        '_securityDetails': securityDetails?.toJson(),
        '_wasAborted': wasAborted,
        '_wasFulfilled': wasFulfilled,
        '_wasContinued': wasContinued,
        '_serviceWorkerRef': serviceWorkerRef,
        '_apiRequestRef': apiRequestRef,
        '_resourceType': resourceType,
        '_webSocketMessages':
            webSocketMessages?.map((e) => e.toJson()).toList(),
      });
}

/// `WebSocketMessage`: one frame of a websocket conversation.
class HarWebSocketMessage {
  /// `send` or `receive`.
  String type;
  double time;
  int opcode;
  String data;

  HarWebSocketMessage({
    required this.type,
    required this.time,
    required this.opcode,
    required this.data,
  });

  factory HarWebSocketMessage.fromJson(Map<String, dynamic> json) =>
      HarWebSocketMessage(
        type: json['type'] as String,
        time: _double(json['time']) ?? 0,
        opcode: _int(json['opcode']) ?? 0,
        data: json['data'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'type': type, 'time': time, 'opcode': opcode, 'data': data};
}

/// `Request`.
class HarRequest {
  String method;
  String url;
  String httpVersion;
  List<HarCookie> cookies;
  List<HarHeader> headers;
  List<HarQueryParameter> queryString;
  HarPostData? postData;
  int headersSize;
  int bodySize;
  String? comment;

  HarRequest({
    required this.method,
    required this.url,
    this.httpVersion = '',
    List<HarCookie>? cookies,
    List<HarHeader>? headers,
    List<HarQueryParameter>? queryString,
    this.postData,
    this.headersSize = -1,
    this.bodySize = -1,
    this.comment,
  })  : cookies = cookies ?? <HarCookie>[],
        headers = headers ?? <HarHeader>[],
        queryString = queryString ?? <HarQueryParameter>[];

  factory HarRequest.fromJson(Map<String, dynamic> json) => HarRequest(
        method: json['method'] as String? ?? '',
        url: json['url'] as String? ?? '',
        httpVersion: json['httpVersion'] as String? ?? '',
        cookies: _list(json['cookies'], HarCookie.fromJson),
        headers: _list(json['headers'], HarHeader.fromJson),
        queryString: _list(json['queryString'], HarQueryParameter.fromJson),
        postData: json['postData'] == null
            ? null
            : HarPostData.fromJson(
                (json['postData'] as Map).cast<String, dynamic>()),
        headersSize: _int(json['headersSize']) ?? -1,
        bodySize: _int(json['bodySize']) ?? -1,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'method': method,
        'url': url,
        'httpVersion': httpVersion,
        'cookies': cookies.map((e) => e.toJson()).toList(),
        'headers': headers.map((e) => e.toJson()).toList(),
        'queryString': queryString.map((e) => e.toJson()).toList(),
        'postData': postData?.toJson(),
        'headersSize': headersSize,
        'bodySize': bodySize,
        'comment': comment,
      });
}

/// `Response`.
class HarResponse {
  int status;
  String statusText;
  String httpVersion;
  List<HarCookie> cookies;
  List<HarHeader> headers;
  HarContent content;
  String redirectURL;
  int headersSize;
  int bodySize;
  String? comment;
  int? transferSize;
  String? failureText;

  HarResponse({
    required this.status,
    this.statusText = '',
    this.httpVersion = '',
    List<HarCookie>? cookies,
    List<HarHeader>? headers,
    required this.content,
    this.redirectURL = '',
    this.headersSize = -1,
    this.bodySize = -1,
    this.comment,
    this.transferSize,
    this.failureText,
  })  : cookies = cookies ?? <HarCookie>[],
        headers = headers ?? <HarHeader>[];

  factory HarResponse.fromJson(Map<String, dynamic> json) => HarResponse(
        status: _int(json['status']) ?? 0,
        statusText: json['statusText'] as String? ?? '',
        httpVersion: json['httpVersion'] as String? ?? '',
        cookies: _list(json['cookies'], HarCookie.fromJson),
        headers: _list(json['headers'], HarHeader.fromJson),
        content: json['content'] == null
            ? HarContent(size: -1, mimeType: 'x-unknown')
            : HarContent.fromJson(
                (json['content'] as Map).cast<String, dynamic>()),
        redirectURL: json['redirectURL'] as String? ?? '',
        headersSize: _int(json['headersSize']) ?? -1,
        bodySize: _int(json['bodySize']) ?? -1,
        comment: json['comment'] as String?,
        transferSize: _int(json['_transferSize']),
        failureText: json['_failureText'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'status': status,
        'statusText': statusText,
        'httpVersion': httpVersion,
        'cookies': cookies.map((e) => e.toJson()).toList(),
        'headers': headers.map((e) => e.toJson()).toList(),
        'content': content.toJson(),
        'redirectURL': redirectURL,
        'headersSize': headersSize,
        'bodySize': bodySize,
        'comment': comment,
        '_transferSize': transferSize,
        '_failureText': failureText,
      });
}

/// `Cookie`.
class HarCookie {
  String name;
  String value;
  String? path;
  String? domain;
  String? expires;
  bool? httpOnly;
  bool? secure;
  String? sameSite;
  String? comment;

  HarCookie({
    required this.name,
    required this.value,
    this.path,
    this.domain,
    this.expires,
    this.httpOnly,
    this.secure,
    this.sameSite,
    this.comment,
  });

  factory HarCookie.fromJson(Map<String, dynamic> json) => HarCookie(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        path: json['path'] as String?,
        domain: json['domain'] as String?,
        expires: json['expires'] as String?,
        httpOnly: json['httpOnly'] as bool?,
        secure: json['secure'] as bool?,
        sameSite: json['sameSite'] as String?,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'name': name,
        'value': value,
        'path': path,
        'domain': domain,
        'expires': expires,
        'httpOnly': httpOnly,
        'secure': secure,
        'sameSite': sameSite,
        'comment': comment,
      });
}

/// `Header`: one HTTP header, name and value.
class HarHeader {
  String name;
  String value;
  String? comment;

  HarHeader({required this.name, required this.value, this.comment});

  factory HarHeader.fromJson(Map<String, dynamic> json) => HarHeader(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'name': name, 'value': value, 'comment': comment});
}

/// `QueryParameter`.
class HarQueryParameter {
  String name;
  String value;
  String? comment;

  HarQueryParameter({required this.name, required this.value, this.comment});

  factory HarQueryParameter.fromJson(Map<String, dynamic> json) =>
      HarQueryParameter(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'name': name, 'value': value, 'comment': comment});
}

/// `PostData`.
///
/// `_file` is the trace-relative path of the body blob; in traces older than
/// version 9 the same blob was named by `_sha1`, which the modernizer rewrites.
class HarPostData {
  String mimeType;
  List<HarParam> params;
  String text;
  String? comment;
  String? file;

  HarPostData({
    required this.mimeType,
    List<HarParam>? params,
    this.text = '',
    this.comment,
    this.file,
  }) : params = params ?? <HarParam>[];

  factory HarPostData.fromJson(Map<String, dynamic> json) => HarPostData(
        mimeType: json['mimeType'] as String? ?? '',
        params: _list(json['params'], HarParam.fromJson),
        text: json['text'] as String? ?? '',
        comment: json['comment'] as String?,
        file: json['_file'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'mimeType': mimeType,
        'params': params.map((e) => e.toJson()).toList(),
        'text': text,
        'comment': comment,
        '_file': file,
      });
}

/// `Param`: one part of a multipart or form-encoded body.
class HarParam {
  String name;
  String? value;
  String? fileName;
  String? contentType;
  String? comment;

  HarParam({
    required this.name,
    this.value,
    this.fileName,
    this.contentType,
    this.comment,
  });

  factory HarParam.fromJson(Map<String, dynamic> json) => HarParam(
        name: json['name'] as String? ?? '',
        value: json['value'] as String?,
        fileName: json['fileName'] as String?,
        contentType: json['contentType'] as String?,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'name': name,
        'value': value,
        'fileName': fileName,
        'contentType': contentType,
        'comment': comment,
      });
}

/// `Content`: the response body.
///
/// `_file` is the trace-relative path of the blob; in traces older than version
/// 9 the same blob was named by `_sha1`, which the modernizer rewrites.
class HarContent {
  int size;
  int? compression;
  String mimeType;
  String? text;
  String? encoding;
  String? comment;
  String? file;

  HarContent({
    required this.size,
    this.compression,
    required this.mimeType,
    this.text,
    this.encoding,
    this.comment,
    this.file,
  });

  factory HarContent.fromJson(Map<String, dynamic> json) => HarContent(
        size: _int(json['size']) ?? -1,
        compression: _int(json['compression']),
        mimeType: json['mimeType'] as String? ?? '',
        text: json['text'] as String?,
        encoding: json['encoding'] as String?,
        comment: json['comment'] as String?,
        file: json['_file'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'size': size,
        'compression': compression,
        'mimeType': mimeType,
        'text': text,
        'encoding': encoding,
        'comment': comment,
        '_file': file,
      });
}

/// `Cache`.
class HarCache {
  HarCacheState? beforeRequest;
  HarCacheState? afterRequest;
  String? comment;

  HarCache({this.beforeRequest, this.afterRequest, this.comment});

  factory HarCache.fromJson(Map<String, dynamic> json) => HarCache(
        beforeRequest: json['beforeRequest'] == null
            ? null
            : HarCacheState.fromJson(
                (json['beforeRequest'] as Map).cast<String, dynamic>()),
        afterRequest: json['afterRequest'] == null
            ? null
            : HarCacheState.fromJson(
                (json['afterRequest'] as Map).cast<String, dynamic>()),
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'beforeRequest': beforeRequest?.toJson(),
        'afterRequest': afterRequest?.toJson(),
        'comment': comment,
      });
}

/// `CacheState`.
class HarCacheState {
  String? expires;
  String lastAccess;
  String eTag;
  int hitCount;
  String? comment;

  HarCacheState({
    this.expires,
    required this.lastAccess,
    required this.eTag,
    required this.hitCount,
    this.comment,
  });

  factory HarCacheState.fromJson(Map<String, dynamic> json) => HarCacheState(
        expires: json['expires'] as String?,
        lastAccess: json['lastAccess'] as String? ?? '',
        eTag: json['eTag'] as String? ?? '',
        hitCount: _int(json['hitCount']) ?? 0,
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'expires': expires,
        'lastAccess': lastAccess,
        'eTag': eTag,
        'hitCount': hitCount,
        'comment': comment,
      });
}

/// `Timings`.
class HarTimings {
  double? blocked;
  double? dns;
  double? connect;
  double send;
  double wait;
  double receive;
  double? ssl;
  String? comment;

  HarTimings({
    this.blocked,
    this.dns,
    this.connect,
    required this.send,
    required this.wait,
    required this.receive,
    this.ssl,
    this.comment,
  });

  factory HarTimings.fromJson(Map<String, dynamic> json) => HarTimings(
        blocked: _double(json['blocked']),
        dns: _double(json['dns']),
        connect: _double(json['connect']),
        send: _double(json['send']) ?? -1,
        wait: _double(json['wait']) ?? -1,
        receive: _double(json['receive']) ?? -1,
        ssl: _double(json['ssl']),
        comment: json['comment'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'blocked': blocked,
        'dns': dns,
        'connect': connect,
        'send': send,
        'wait': wait,
        'receive': receive,
        'ssl': ssl,
        'comment': comment,
      });
}

/// `SecurityDetails`.
class HarSecurityDetails {
  String? protocol;
  String? subjectName;
  String? issuer;
  double? validFrom;
  double? validTo;

  HarSecurityDetails({
    this.protocol,
    this.subjectName,
    this.issuer,
    this.validFrom,
    this.validTo,
  });

  factory HarSecurityDetails.fromJson(Map<String, dynamic> json) =>
      HarSecurityDetails(
        protocol: json['protocol'] as String?,
        subjectName: json['subjectName'] as String?,
        issuer: json['issuer'] as String?,
        validFrom: _double(json['validFrom']),
        validTo: _double(json['validTo']),
      );

  Map<String, dynamic> toJson() => _compact({
        'protocol': protocol,
        'subjectName': subjectName,
        'issuer': issuer,
        'validFrom': validFrom,
        'validTo': validTo,
      });
}
