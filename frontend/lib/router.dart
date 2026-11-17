import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/admin/b2b_orders_page.dart';
import 'features/admin/dashboard_page.dart';
import 'features/admin/invoices_page.dart';
import 'features/admin/movements_page.dart';
import 'features/admin/opname_page.dart';
import 'features/admin/partners_page.dart';
import 'features/admin/pos_page.dart';
import 'features/admin/print_queue_page.dart';
import 'features/admin/product_form_page.dart';
import 'features/admin/products_page.dart';
import 'features/admin/reports_page.dart';
import 'features/admin/restock_page.dart';
import 'features/admin/settings_page.dart';
import 'features/admin/stock_in_page.dart';
import 'features/admin/users_page.dart';
import 'features/auth/login_page.dart';
import 'features/auth/register_page.dart';
import 'features/b2b/b2b_home_page.dart';
import 'features/b2b/catalog_page.dart';
import 'features/b2b/invoices_page.dart';
import 'features/b2b/orders_page.dart';
import 'features/b2b/quick_po_page.dart';
import 'features/common/notifications_page.dart';
import 'features/common/profile_page.dart';
import 'features/print/print_job_page.dart';
import 'features/print/print_jobs_page.dart';
import 'features/print/print_order_page.dart';
import 'features/public/queue_monitor_page.dart';
import 'state/auth_state.dart';
import 'widgets/app_shell.dart';

const _publicPaths = {'/login', '/register', '/antrean'};

int? _intParam(GoRouterState s, String name) => int.tryParse(s.uri.queryParameters[name] ?? '');

GoRoute _page(String path, Widget Function(GoRouterState state) build) => GoRoute(
      path: path,
      pageBuilder: (context, state) => NoTransitionPage(key: ValueKey(state.uri.toString()), child: build(state)),
    );

/// Router dengan guard berbasis peran (RBAC di sisi UI; backend tetap memvalidasi setiap request).
GoRouter buildRouter(AuthState auth) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: auth,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (!auth.isLoggedIn) return _publicPaths.contains(loc) ? null : '/login';
      if (loc == '/' || loc == '/login' || loc == '/register') return auth.homePath;
      if (loc.startsWith('/admin') && !auth.isStaff) return auth.homePath;
      if (loc == '/admin/users' && !auth.isOwner) return '/admin';
      if (loc.startsWith('/b2b') && !auth.isPartner) return auth.homePath;
      if (loc.startsWith('/print') && auth.isStaff) return '/admin/print-queue';
      return null;
    },
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Halaman tidak ditemukan', style: TextStyle(fontSize: 20)),
          TextButton(onPressed: () => context.go('/'), child: const Text('Kembali ke beranda')),
        ]),
      ),
    ),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterPage()),
      GoRoute(path: '/antrean', builder: (_, _) => const QueueMonitorPage()),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          // ── Staf & pemilik ──
          _page('/admin', (_) => const DashboardPage()),
          _page('/admin/pos', (_) => const PosPage()),
          _page('/admin/print-queue', (_) => const PrintQueuePage()),
          _page('/admin/products', (_) => const ProductsPage()),
          _page('/admin/products/new', (_) => const ProductFormPage()),
          _page('/admin/products/:id', (s) => ProductFormPage(productId: int.parse(s.pathParameters['id']!))),
          _page('/admin/restock', (_) => const RestockPage()),
          _page('/admin/stock-in', (s) => StockInPage(productId: _intParam(s, 'productId'), suggestedQty: _intParam(s, 'qty'))),
          _page('/admin/opname', (_) => const OpnamePage()),
          _page('/admin/movements', (s) => MovementsPage(productId: _intParam(s, 'productId'))),
          _page('/admin/b2b-orders', (s) => AdminOrdersPage(initialId: _intParam(s, 'id'))),
          _page('/admin/invoices', (_) => const AdminInvoicesPage()),
          _page('/admin/partners', (_) => const PartnersPage()),
          _page('/admin/reports', (_) => const ReportsPage()),
          _page('/admin/settings', (_) => const SettingsPage()),
          _page('/admin/users', (_) => const UsersPage()),
          // ── Mitra B2B ──
          _page('/b2b', (_) => const B2bHomePage()),
          _page('/b2b/catalog', (_) => const CatalogPage()),
          _page('/b2b/quick-po', (_) => const QuickPoPage()),
          _page('/b2b/orders', (s) => PartnerOrdersPage(initialId: _intParam(s, 'id'))),
          _page('/b2b/invoices', (_) => const PartnerInvoicesPage()),
          // ── Cloud printing (pelanggan & mitra) ──
          _page('/print', (_) => const PrintOrderPage()),
          _page('/print/jobs', (_) => const PrintJobsPage()),
          _page('/print/jobs/:id', (s) => PrintJobPage(id: int.parse(s.pathParameters['id']!))),
          // ── Umum ──
          _page('/notifications', (_) => const NotificationsPage()),
          _page('/profile', (_) => const ProfilePage()),
        ],
      ),
    ],
  );
}
