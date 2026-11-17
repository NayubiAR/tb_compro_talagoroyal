import 'package:flutter/foundation.dart';

/// Konfigurasi aplikasi.
///
/// Alamat backend dapat diatur saat build:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:4000
///   flutter build web --dart-define=API_BASE_URL=https://api.talagoroyal.id
/// Jika tidak diisi: mode debug memakai http://localhost:4000, mode rilis memakai
/// origin halaman (cocok bila hasil build disajikan oleh backend lewat WEB_DIR).
class AppConfig {
  static const _apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static String get apiBaseUrl {
    if (_apiBaseUrl.isNotEmpty) return _apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    if (kDebugMode) return 'http://localhost:4000';
    return Uri.base.origin;
  }
}
