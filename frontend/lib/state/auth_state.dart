import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/socket_service.dart';

/// Sesi pengguna (token JWT + profil) dan peran untuk RBAC di sisi UI.
/// Catatan: RBAC sesungguhnya ditegakkan backend; UI hanya menyembunyikan menu.
class AuthState extends ChangeNotifier {
  AuthState(this.api, this.socket) {
    api.onUnauthorized = () => logout(expired: true);
  }

  final ApiClient api;
  final SocketService socket;
  static const _tokenKey = 'talago_token';

  Json? user;
  bool sessionExpired = false;

  bool get isLoggedIn => user != null;
  String? get role => user?['role'] as String?;
  bool get isOwner => role == 'OWNER';
  bool get isStaff => role == 'ADMIN' || role == 'OWNER';
  bool get isPartner => role == 'B2B';
  bool get isCustomer => role == 'CUSTOMER';
  Json? get partner => user?['partner'] as Json?;
  bool get partnerVerified => partner?['status'] == 'VERIFIED';
  String get name => (user?['name'] ?? '') as String;

  String get homePath => isStaff ? '/admin' : (isPartner ? '/b2b' : '/print');

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token != null) {
      api.token = token;
      try {
        user = (await api.get('/api/auth/me'))['data'] as Json;
      } catch (_) {
        api.token = null;
        await prefs.remove(_tokenKey);
      }
    }
    socket.connect(api.token);
  }

  Future<void> login(String email, String password) async {
    final res = await api.post('/api/auth/login', {'email': email, 'password': password});
    await _setSession(res['data'] as Json);
  }

  Future<void> register(Json body, {required bool partner}) async {
    final res = await api.post(partner ? '/api/auth/register-partner' : '/api/auth/register', body);
    await _setSession(res['data'] as Json);
  }

  Future<void> refreshMe() async {
    user = (await api.get('/api/auth/me'))['data'] as Json;
    notifyListeners();
  }

  void updateUser(Json data) {
    user = data;
    notifyListeners();
  }

  Future<void> logout({bool expired = false}) async {
    if (user == null && api.token == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    api.token = null;
    user = null;
    sessionExpired = expired;
    socket.connect(null);
    notifyListeners();
  }

  Future<void> _setSession(Json data) async {
    final token = data['token'] as String;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    api.token = token;
    user = data['user'] as Json;
    sessionExpired = false;
    socket.connect(token);
    notifyListeners();
  }
}
