import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/labels.dart';
import '../core/socket_service.dart';
import '../core/theme.dart';
import '../state/auth_state.dart';
import 'common.dart';

class NavItem {
  const NavItem(this.label, this.icon, this.path, {this.section});
  final String label;
  final IconData icon;
  final String path;
  final String? section;
}

List<NavItem> navItemsFor(AuthState auth) {
  if (auth.isStaff) {
    return [
      const NavItem('Dashboard', Icons.dashboard_outlined, '/admin', section: 'Operasional'),
      const NavItem('Kasir', Icons.point_of_sale, '/admin/pos', section: 'Operasional'),
      const NavItem('Antrean Cetak', Icons.print_outlined, '/admin/print-queue', section: 'Operasional'),
      const NavItem('Produk', Icons.inventory_2_outlined, '/admin/products', section: 'Inventaris Cerdas'),
      const NavItem('Restock Alert', Icons.notification_important_outlined, '/admin/restock', section: 'Inventaris Cerdas'),
      const NavItem('Penerimaan Barang', Icons.move_to_inbox_outlined, '/admin/stock-in', section: 'Inventaris Cerdas'),
      const NavItem('Stock Opname', Icons.fact_check_outlined, '/admin/opname', section: 'Inventaris Cerdas'),
      const NavItem('Mutasi Stok', Icons.swap_vert, '/admin/movements', section: 'Inventaris Cerdas'),
      const NavItem('Pesanan B2B', Icons.receipt_long_outlined, '/admin/b2b-orders', section: 'Portal B2B'),
      const NavItem('Faktur & Piutang', Icons.request_quote_outlined, '/admin/invoices', section: 'Portal B2B'),
      const NavItem('Mitra B2B', Icons.handshake_outlined, '/admin/partners', section: 'Portal B2B'),
      const NavItem('Laporan', Icons.insights_outlined, '/admin/reports', section: 'Manajemen'),
      const NavItem('Pengaturan', Icons.settings_outlined, '/admin/settings', section: 'Manajemen'),
      if (auth.isOwner) const NavItem('Pengguna', Icons.manage_accounts_outlined, '/admin/users', section: 'Manajemen'),
    ];
  }
  if (auth.isPartner) {
    return const [
      NavItem('Beranda', Icons.home_outlined, '/b2b', section: 'Portal B2B'),
      NavItem('Katalog Grosir', Icons.storefront_outlined, '/b2b/catalog', section: 'Portal B2B'),
      NavItem('Quick PO', Icons.table_view_outlined, '/b2b/quick-po', section: 'Portal B2B'),
      NavItem('Pesanan Saya', Icons.receipt_long_outlined, '/b2b/orders', section: 'Portal B2B'),
      NavItem('Faktur', Icons.request_quote_outlined, '/b2b/invoices', section: 'Portal B2B'),
      NavItem('Cetak Dokumen', Icons.upload_file_outlined, '/print', section: 'Cloud Printing'),
      NavItem('Pesanan Cetak', Icons.print_outlined, '/print/jobs', section: 'Cloud Printing'),
    ];
  }
  return const [
    NavItem('Cetak Dokumen', Icons.upload_file_outlined, '/print', section: 'Cloud Printing'),
    NavItem('Pesanan Cetak Saya', Icons.print_outlined, '/print/jobs', section: 'Cloud Printing'),
  ];
}

NavItem? activeItem(List<NavItem> items, String location) {
  NavItem? best;
  for (final item in items) {
    final match = location == item.path || location.startsWith('${item.path}/');
    if (match && (best == null || item.path.length > best.path.length)) best = item;
  }
  return best;
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final items = navItemsFor(auth);
    final current = activeItem(items, location);
    final title = current?.label ?? (location.startsWith('/notifications') ? 'Notifikasi' : location.startsWith('/profile') ? 'Profil' : 'Talago Royal');
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final actions = [NotificationBell(location: location), const _UserMenu(), const SizedBox(width: 8)];

    if (!wide) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        drawer: Drawer(child: _Sidebar(items: items, current: current, closeOnTap: true)),
        body: child,
      );
    }
    return Scaffold(
      body: Row(children: [
        SizedBox(width: 256, child: _Sidebar(items: items, current: current)),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(children: [
            Container(
              height: 60,
              padding: const EdgeInsets.only(left: 24),
              color: Theme.of(context).colorScheme.surface,
              child: Row(children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                ...actions,
              ]),
            ),
            const Divider(height: 1),
            Expanded(child: child),
          ]),
        ),
      ]),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.items, required this.current, this.closeOnTap = false});
  final List<NavItem> items;
  final NavItem? current;
  final bool closeOnTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthState>();
    final tiles = <Widget>[];
    String? lastSection;
    for (final item in items) {
      if (item.section != lastSection) {
        lastSection = item.section;
        tiles.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
          child: Text(item.section!.toUpperCase(),
              style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        ));
      }
      final selected = identical(item, current) || item.path == current?.path;
      tiles.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
        child: ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: scheme.primary.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(item.icon, size: 20),
          title: Text(item.label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          onTap: () {
            if (closeOnTap) Navigator.of(context).pop();
            context.go(item.path);
          },
        ),
      ));
    }
    return Container(
      color: scheme.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Brand.navy, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.edit_note, color: Brand.gold),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Talago Royal', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text(roleLabel[auth.role] ?? '', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
        Expanded(child: ListView(children: tiles)),
        const Divider(height: 1),
        const _RealtimeIndicator(),
      ]),
    );
  }
}

class _RealtimeIndicator extends StatelessWidget {
  const _RealtimeIndicator();

  @override
  Widget build(BuildContext context) {
    final socket = context.read<SocketService>();
    return ValueListenableBuilder<bool>(
      valueListenable: socket.connected,
      builder: (context, on, _) {
        final color = toneColor(context, on ? Tone.good : Tone.neutral);
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(on ? Icons.wifi_tethering : Icons.wifi_tethering_off, size: 16, color: color),
            const SizedBox(width: 8),
            Text(on ? 'Real-time tersambung' : 'Menyambungkan real-time…', style: TextStyle(fontSize: 12, color: color)),
          ]),
        );
      },
    );
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final initial = auth.name.isNotEmpty ? auth.name[0].toUpperCase() : '?';
    return PopupMenuButton<String>(
      tooltip: 'Akun',
      offset: const Offset(0, 48),
      onSelected: (v) async {
        if (v == 'logout') {
          await auth.logout();
        } else if (context.mounted) {
          context.go(v);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(auth.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(auth.user?['email'] ?? '', style: const TextStyle(fontSize: 12)),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '/profile', child: ListTile(leading: Icon(Icons.person_outline), title: Text('Profil & Keamanan'))),
        const PopupMenuItem(value: '/notifications', child: ListTile(leading: Icon(Icons.notifications_none), title: Text('Notifikasi'))),
        if (auth.isStaff)
          const PopupMenuItem(value: '/antrean', child: ListTile(leading: Icon(Icons.tv), title: Text('Layar Monitor Antrean'))),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout), title: Text('Keluar'))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: CircleAvatar(radius: 17, backgroundColor: Brand.navy, child: Text(initial, style: const TextStyle(color: Colors.white))),
      ),
    );
  }
}

/// Ikon lonceng dengan jumlah notifikasi belum dibaca; notifikasi baru muncul sebagai toast real-time.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, required this.location});
  final String location;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int unread = 0;
  StreamSubscription<RealtimeEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = context.socket.on('notification').listen((e) {
      if (!mounted) return;
      setState(() => unread++);
      final data = e.data as Map? ?? {};
      showSnack(
        context,
        '${data['title'] ?? 'Notifikasi baru'}',
        action: data['link'] != null
            ? SnackBarAction(label: 'Lihat', onPressed: () => context.go(data['link'] as String))
            : null,
      );
    });
  }

  @override
  void didUpdateWidget(covariant NotificationBell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final res = await context.api.get('/api/notifications', query: {'limit': 1});
      if (mounted) setState(() => unread = res['meta']['unreadCount'] as int);
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Notifikasi',
      onPressed: () => context.go('/notifications'),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: const Icon(Icons.notifications_none),
      ),
    );
  }
}
