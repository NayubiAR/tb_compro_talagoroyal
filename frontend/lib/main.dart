import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/socket_service.dart';
import 'core/theme.dart';
import 'router.dart';
import 'state/auth_state.dart';
import 'state/po_draft.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');
  Intl.defaultLocale = 'id_ID';

  final api = ApiClient(AppConfig.apiBaseUrl);
  final socket = SocketService(AppConfig.apiBaseUrl);
  final auth = AuthState(api, socket);
  await auth.restore();

  runApp(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<SocketService>.value(value: socket),
      ChangeNotifierProvider<AuthState>.value(value: auth),
      ChangeNotifierProvider<PoDraft>(create: (_) => PoDraft()),
    ],
    child: TalagoApp(auth: auth),
  ));
}

class TalagoApp extends StatefulWidget {
  const TalagoApp({super.key, required this.auth});
  final AuthState auth;

  @override
  State<TalagoApp> createState() => _TalagoAppState();
}

class _TalagoAppState extends State<TalagoApp> {
  late final GoRouter _router = buildRouter(widget.auth);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Talago Royal',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      locale: const Locale('id', 'ID'),
      supportedLocales: const [Locale('id', 'ID'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
