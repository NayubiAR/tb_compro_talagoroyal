import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/revenue_chart.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with LoaderMixin, RealtimeMixin {
  Json d = {};

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(
      ['stock.alert', 'order.updated', 'print.job.updated', 'sales.created', 'invoice.updated'],
      () => reload(silent: true),
    );
  }

  @override
  Future<void> load() async => d = (await context.api.get('/api/reports/dashboard'))['data'] as Json;

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final today = d['today'] as Json;
      final queue = d['printQueue'] as Json;
      final restock = d['restock'] as Json;
      final counts = restock['counts'] as Json;
      final inv = d['inventory'] as Json;
      final ar = d['receivables'] as Json;
      final pendingPartners = d['pendingPartners'] as int;
      final wide = MediaQuery.sizeOf(context).width >= 1200;

      final chart = SectionCard(
        title: 'Omzet 14 hari terakhir',
        subtitle: 'Per kanal penjualan (B2B dihitung saat PO disetujui)',
        child: RevenueChart(series: d['revenueTrend'] as List),
      );
      final alerts = SectionCard(
        title: 'Perlu segera di-restock',
        subtitle: 'Prioritas: habis → kritis → fast-moving',
        trailing: TextButton(onPressed: () => context.go('/admin/restock'), child: const Text('Semua')),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          if ((restock['top'] as List).isEmpty) const EmptyState(icon: Icons.check_circle_outline, message: 'Semua stok aman'),
          for (final a in restock['top'] as List)
            ListTile(
              dense: true,
              leading: StatusChip(statusOf(restockLevel, a['level']), dense: true),
              title: Row(children: [
                Flexible(child: Text(a['name'], overflow: TextOverflow.ellipsis)),
                if (a['fastMoving'] == true)
                  Tooltip(
                    message: 'Fast-moving (20% terlaris)',
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.local_fire_department, size: 16, color: toneColor(context, Tone.serious)),
                    ),
                  ),
              ]),
              subtitle: Text('Stok ${a['stockDisplay']} · saran pesan ${a['suggestedOrderDisplay']}'),
              onTap: () => context.go('/admin/stock-in?productId=${a['productId']}'),
            ),
        ]),
      );

      return RefreshIndicator(
        onRefresh: reload,
        child: PageBody(children: [
          PageHeader(
            title: 'Dashboard',
            subtitle: 'Ringkasan operasional · ${fmtDate(DateTime.now())}',
            actions: [
              FilledButton.icon(onPressed: () => context.go('/admin/pos'), icon: const Icon(Icons.point_of_sale), label: const Text('Buka Kasir')),
              OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('Muat ulang')),
            ],
          ),
          if (pendingPartners > 0) ...[
            Card(
              color: toneColor(context, Tone.warning).withValues(alpha: 0.1),
              child: ListTile(
                leading: Icon(Icons.handshake_outlined, color: toneColor(context, Tone.warning)),
                title: Text('$pendingPartners pendaftaran mitra B2B menunggu verifikasi'),
                trailing: TextButton(onPressed: () => context.go('/admin/partners'), child: const Text('Tinjau')),
              ),
            ),
            const SizedBox(height: 16),
          ],
          ResponsiveGrid(minItemWidth: 320, children: [
            StatCard(
              label: 'Omzet hari ini',
              value: rupiah(today['total']),
              icon: Icons.payments_outlined,
              caption: 'Eceran ${compactRupiah(today['retail'])} · B2B ${compactRupiah(today['b2b'])} · Cetak ${compactRupiah(today['print'])}',
              onTap: () => context.go('/admin/reports'),
            ),
            StatCard(
              label: 'PO menunggu verifikasi',
              value: '${d['pendingOrders']}',
              icon: Icons.receipt_long_outlined,
              tone: (d['pendingOrders'] as int) > 0 ? Tone.warning : null,
              caption: 'Pesanan partai besar dari mitra',
              onTap: () => context.go('/admin/b2b-orders'),
            ),
            StatCard(
              label: 'Antrean cetak',
              value: '${queue['waiting']} menunggu',
              icon: Icons.print_outlined,
              caption: '${queue['printing']} dicetak · ${queue['ready']} siap diambil',
              onTap: () => context.go('/admin/print-queue'),
            ),
            StatCard(
              label: 'Piutang berjalan',
              value: rupiah(ar['outstanding']),
              icon: Icons.request_quote_outlined,
              tone: (ar['overdue'] as int) > 0 ? Tone.critical : null,
              caption: 'Jatuh tempo ${rupiah(ar['overdue'])}',
              onTap: () => context.go('/admin/invoices'),
            ),
            StatCard(
              label: 'Nilai aset stok (HPP)',
              value: rupiah(inv['stockValue']),
              icon: Icons.warehouse_outlined,
              caption: '${number(inv['totalSku'])} SKU aktif · potensi jual ${compactRupiah(inv['retailValue'])}',
              onTap: () => context.go('/admin/products'),
            ),
            StatCard(
              label: 'Smart Restock Alert',
              value: '${counts['HABIS'] + counts['KRITIS']} perlu restock',
              icon: Icons.notification_important_outlined,
              tone: (counts['HABIS'] as int) > 0 ? Tone.critical : Tone.serious,
              caption: '${counts['HABIS']} habis · ${counts['KRITIS']} kritis · ${counts['WASPADA']} waspada',
              onTap: () => context.go('/admin/restock'),
            ),
          ]),
          const SizedBox(height: 16),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: chart),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: alerts),
            ])
          else ...[chart, const SizedBox(height: 16), alerts],
        ]),
      );
    });
  }
}
