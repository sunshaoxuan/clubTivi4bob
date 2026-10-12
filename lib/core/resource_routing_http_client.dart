import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'resource_node_router.dart';

/// Routes raw dart:io, package:http and cached-image requests as well as Dio.
/// Failover happens before request headers/body are sent, including uploads.
class ResourceRoutingHttpClient implements HttpClient {
  ResourceRoutingHttpClient(this.inner, this.router);
  final HttpClient inner;
  final ResourceNodeRouter router;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    var target = await router.resolve(url);
    HttpClientRequest request;
    try {
      request = await inner.openUrl(method, target);
    } on SocketException {
      if (!ResourceNodeRouter.eligible(target)) rethrow;
      router.failed(target);
      final alternative = await router.resolve(url);
      if (alternative == target) rethrow;
      target = alternative;
      request = await inner.openUrl(method, target);
    } on HandshakeException {
      if (!ResourceNodeRouter.eligible(target)) rethrow;
      router.failed(target);
      target = await router.resolve(url);
      request = await inner.openUrl(method, target);
    }
    return ResourceNodeRouter.eligible(target)
        ? _ResourceRequest(request, inner, router, target)
        : request;
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(method, Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Duration get idleTimeout => inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => inner.autoUncompress;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;
  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? value) =>
      inner.authenticate = value;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials value) =>
      inner.addCredentials(url, realm, value);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) => inner.connectionFactory = value;
  @override
  set findProxy(String Function(Uri)? value) => inner.findProxy = value;
  @override
  set authenticateProxy(
    Future<bool> Function(String, int, String, String?)? value,
  ) => inner.authenticateProxy = value;
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials value,
  ) => inner.addProxyCredentials(host, port, realm, value);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) => inner.badCertificateCallback = value;
  @override
  set keyLog(Function(String)? value) => inner.keyLog = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
}

/// Upload failures update the next selection but never resubmit a sent body.
class _ResourceRequest implements HttpClientRequest {
  _ResourceRequest(this.inner, this.client, this.router, this.target);
  final HttpClientRequest inner;
  final HttpClient client;
  final ResourceNodeRouter router;
  final Uri target;
  Future<HttpClientResponse>? _closing;
  bool _aborted = false;

  Future<HttpClientResponse> _finish() async {
    HttpClientResponse? response;
    try {
      response = await inner.close();
      if (!const {502, 503, 504}.contains(response.statusCode)) return response;
    } catch (error) {
      if (_aborted ||
          !(error is SocketException ||
              error is HandshakeException ||
          error is HttpException)) {
        rethrow;
      }
      router.failed(target);
      if (!const {'GET', 'HEAD'}.contains(method)) rethrow;
      return _retry();
    }
    router.failed(target);
    if (!const {'GET', 'HEAD'}.contains(method)) return response;
    await response.drain<void>();
    return _retry();
  }

  Future<HttpClientResponse> _retry() async {
    final alternate = await router.resolve(target);
    final next = await client.openUrl(method, alternate);
    next.followRedirects = followRedirects;
    next.maxRedirects = maxRedirects;
    headers.forEach((name, values) {
      if (!const {
        'host',
        'connection',
        'transfer-encoding',
      }.contains(name.toLowerCase())) {
        next.headers.set(name, values);
      }
    });
    return next.close();
  }

  @override
  Future<HttpClientResponse> close() => _closing ??= _finish();
  @override
  Future<HttpClientResponse> get done => _closing ?? inner.done;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  set persistentConnection(bool value) => inner.persistentConnection = value;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;
  @override
  int get contentLength => inner.contentLength;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  bool get bufferOutput => inner.bufferOutput;
  @override
  set bufferOutput(bool value) => inner.bufferOutput = value;
  @override
  String get method => inner.method;
  @override
  Uri get uri => inner.uri;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  List<Cookie> get cookies => inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _aborted = true;
    inner.abort(exception, stackTrace);
  }

  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => inner.addStream(stream);
  @override
  Future<void> flush() => inner.flush();
  @override
  void write(Object? object) => inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => inner.writeln(object);
}
