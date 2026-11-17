import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';

class PrintJobsPage extends StatefulWidget {
  const PrintJobsPage({super.key});

  @override
  State<PrintJobsPage> createState() => _PrintJobsPageState();
}

class _PrintJobsPageState extends State<PrintJobsPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  String scope = 'active';
  int page = 1;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['print.job.updated'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/print/jobs', query: {'scope': scope, 'page': page, 'limit': 12});
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(maxWidth: 1100, children: [
          PageHeader(
            title: 'Pesanan Cetak',
            actions: [FilledButton.icon(onPressed: () => context.go('/print'), icon: const Icon(Icons.upload_file), label: const Text('Cetak dokumen baru'))],
          ),
          Wrap(spacing: 8, children: [
            for (final (v, l) in [('active', 'Sedang berjalan'), ('history', 'Riwayat'), ('all', 'Semua')])
              ChoiceChip(label: Text(l), selected: scope == v, onSelected: (_) {
                scope = v;
                page = 1;
                reload();
              }),
          ]),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            EmptyState(
              icon: Icons.print_outlined,
              message: scope == 'active' ? 'Tidak ada pesanan yang sedang berjalan' : 'Belum ada pesanan',
              action: FilledButton(onPressed: () => context.go('/print'), child: const Text('Cetak dokumen')),
            ),
          for (final j in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: CircleAvatar(
                    radius: 24,
                    child: Text(j['queueLabel'] ?? '—', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  title: Text(j['originalName'], overflow: TextOverflow.ellipsis),
                  subtitle: Text('${j['code']} · ${fmtDateTime(j['createdAt'])}\n${printConfigSummary(j['config'] as Json)}'),
                  isThreeLine: true,
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    StatusChip(statusOf(printStatus, j['status']), dense: true),
                    const SizedBox(height: 4),
                    Text(rupiah(j['pricing']['total']), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                  onTap: () => context.go('/print/jobs/${j['id']}'),
                ),
              ),
            ),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }
}
