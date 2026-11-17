import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

typedef Json = Map<String, dynamic>;

class ApiException implements Exception {
  ApiException(this.message, {this.status, this.details = const []});

  final int? status;
  final String message;
  final List<dynamic> details;

  /// Pesan lengkap termasuk detail per field (untuk ditampilkan di dialog/snackbar).
  String get fullMessage {
    if (details.isEmpty) return message;
    final lines = details.map((d) => d is Map ? '• ${d['message']}' : '• $d').join('\n');
    return '$message\n$lines';
  }

  @override
  String toString() => fullMessage;
}

/// Pembungkus HTTP ke REST API Talago Royal. Semua method mengembalikan body JSON
/// (biasanya `{data, meta}`) atau melempar [ApiException] dengan pesan berbahasa Indonesia.
class ApiClient {
  ApiClient(String baseUrl)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (token != null) options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    }));
  }

  final Dio _dio;
  String? token;

  /// Dipanggil saat sesi kedaluwarsa (HTTP 401 ketika sudah login).
  void Function()? onUnauthorized;

  String get baseUrl => _dio.options.baseUrl;

  Future<Json> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get(path, queryParameters: _clean(query)));

  Future<Json> post(String path, [Object? body]) => _send(() => _dio.post(path, data: body ?? const {}));

  Future<Json> put(String path, [Object? body]) => _send(() => _dio.put(path, data: body ?? const {}));

  Future<Json> patch(String path, [Object? body]) => _send(() => _dio.patch(path, data: body ?? const {}));

  Future<Json> upload(
    String path, {
    required List<int> bytes,
    required String filename,
    void Function(double progress)? onProgress,
  }) {
    final form = FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: filename)});
    return _send(() => _dio.post(
          path,
          data: form,
          onSendProgress: (sent, total) => onProgress?.call(total > 0 ? sent / total : 0),
        ));
  }

  /// Buka PDF/berkas yang dilindungi di tab baru memakai token unduhan berumur pendek.
  Future<void> openDownload(String path) async {
    final res = await post('/api/auth/download-token', {'path': path});
    final url = '$baseUrl${res['data']['url']}';
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
  }

  Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    return {
      for (final e in query.entries)
        if (e.value != null && e.value.toString().isNotEmpty) e.key: e.value.toString(),
    };
  }

  Future<Json> _send(Future<Response<dynamic>> Function() request) async {
    try {
      final res = await request();
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{'data': data};
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      if (status == 401 && token != null) onUnauthorized?.call();
      if (data is Map && data['error'] is Map) {
        final err = data['error'] as Map;
        throw ApiException(
          (err['message'] ?? 'Terjadi kesalahan').toString(),
          status: status,
          details: (err['details'] as List?) ?? const [],
        );
      }
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw ApiException('Tidak dapat terhubung ke server. Pastikan backend berjalan.', status: status);
      }
      throw ApiException('Terjadi kesalahan (${status ?? e.type.name})', status: status);
    }
  }
}
