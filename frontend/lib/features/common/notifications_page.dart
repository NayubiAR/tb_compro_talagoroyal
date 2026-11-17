import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../widgets/common.dart';

const _icons = {
  'PRINT': Icons.print_outlined,
  'B2B_ORDER': Icons.receipt_long_outlined,
  'INVOICE': Icons.request_quote_outlined,
  'PARTNER': Icons.handshake_outlined,
  'STOCK_ALERT': Icons.notification_important_outlined,
};

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  int unread = 0;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['notification'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/notifications', query: {'limit': 100});
    rows = res['data'] as List;
    unread = res['meta']['unreadCount'] as int;
  }

  Future<void> _open(dynamic n) async {
    if (n['readAt'] == null) {
      context.api.post('/api/notifications/${n['id']}/read').catchError((_) => <String, dynamic>{});
    }
    final link = n['link'] as String?;
    if (link != null) {
      context.go(link);
    } else {
      setState(() => n['readAt'] = DateTime.now().toIso8601String());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return loadedBody(() => PageBody(maxWidth: 860, children: [
          PageHeader(
            title: 'Notifikasi',
            subtitle: unread > 0 ? '$unread belum dibaca' : 'Semua sudah dibaca',
            actions: [
              TextButton.icon(
                onPressed: unread == 0
                    ? null
                    : () async {
                        await guard(context, () => context.api.post('/api/notifications/read-all'));
                        reload(silent: true);
                      },
                icon: const Icon(Icons.done_all),
                label: const Text('Tandai semua dibaca'),
              ),
            ],
          ),
          if (rows.isEmpty) const EmptyState(icon: Icons.notifications_none, message: 'Belum ada notifikasi'),
          Card(
            child: Column(children: [
              for (final n in rows)
                ListTile(
                  tileColor: n['readAt'] == null ? scheme.primary.withValues(alpha: 0.05) : null,
                  leading: Icon(_icons[n['type']] ?? Icons.notifications_none, color: n['readAt'] == null ? scheme.primary : scheme.onSurfaceVariant),
                  title: Text(n['title'], style: TextStyle(fontWeight: n['readAt'] == null ? FontWeight.w700 : FontWeight.w500)),
                  subtitle: Text('${n['body']}\n${fmtDateTime(n['createdAt'])}'),
                  isThreeLine: true,
                  trailing: n['link'] != null ? const Icon(Icons.chevron_right) : null,
                  onTap: () => _open(n),
                ),
            ]),
          ),
        ]));
  }
}
