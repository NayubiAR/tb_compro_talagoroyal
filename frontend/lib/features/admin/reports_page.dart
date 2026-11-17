import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';
import '../../widgets/revenue_chart.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> with LoaderMixin {
  late DateTimeRange range = _lastDays(30);
  Json sales = {};
  Json inventory = {};

  static DateTimeRange _lastDays(int n) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    return DateTimeRange(start: end.subtract(Duration(days: n - 1)), end: end);
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([
      context.api.get('/api/reports/sales', query: {'from': ymd(range.start), 'to': ymd(range.end)}),
      context.api.get('/api/reports/inventory'),
    ]);
    sales = results[0]['data'] as Json;
    inventory = results[1]['data'] as Json;
  }

  void _setRange(DateTimeRange r) {
    range = r;
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final t = sales['totals'] as Json;
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      final now = DateTime.now();
      final topProducts = SectionCard(
        title: 'Produk terlaris',
        subtitle: 'Gabungan penjualan kasir & PO B2B (nilai kotor sebelum diskon level/PPN)',
        padding: EdgeInsets.zero,
        child: ScrollTable(
          minWidth: 640,
          columns: const [
            DataColumn(label: Text('#')),
            DataColumn(label: Text('Barang')),
            DataColumn(label: Text('Terjual')),
            DataColumn(label: Text('Nilai'), numeric: true),
          ],
          rows: [
            for (final (i, p) in (sales['topProducts'] as List).indexed)
              DataRow(cells: [
                DataCell(Text('${i + 1}')),
                DataCell(SizedBox(width: 260, child: Text('${p['name']}\n${p['sku']} · ${p['category']}', style: const TextStyle(fontSize: 12.5)))),
                DataCell(Text(p['qtyDisplay'])),
                DataCell(Text(rupiah(p['revenue']))),
              ]),
          ],
        ),
      );
      final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionCard(
          title: 'Mitra B2B teratas',
          child: (sales['topPartners'] as List).isEmpty
              ? const Text('Belum ada PO pada periode ini')
              : BarList(items: [for (final p in sales['topPartners'] as List) ('${p['institutionName']} (${p['orders']} PO)', p['total'] as int)]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Metode pembayaran kasir',
          child: BarList(items: [
            for (final m in sales['paymentMethods'] as List) ('${paymentMethodLabel[m['method']]} (${m['count']} trx)', m['total'] as int),
          ]),
        ),
      ]);
      final deadStock = inventory['deadStock'] as Json;
      final valuation = SectionCard(
        title: 'Valuasi stok per kategori (HPP)',
        child: BarList(items: [for (final c in inventory['byCategory'] as List) ('${c['category']} · ${c['skuCount']} SKU', c['stockValue'] as int)]),
      );
      final dead = SectionCard(
        title: 'Barang tidak bergerak (dead stock)',
        subtitle: '${number(deadStock['count'])} SKU tidak terjual 60 hari · modal tertahan ${rupiah(deadStock['value'])}',
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          for (final d in deadStock['top'] as List)
            ListTile(dense: true, title: Text(d['name']), subtitle: Text('${d['sku']} · stok ${d['stockDisplay']}'), trailing: Text(rupiah(d['stockValue']))),
        ]),
      );
      return PageBody(children: [
        PageHeader(
          title: 'Laporan',
          subtitle: '${fmtDate(range.start)} – ${fmtDate(range.end)}',
          actions: [
            for (final (label, r) in [
              ('7 hari', _lastDays(7)),
              ('30 hari', _lastDays(30)),
              ('Bulan ini', DateTimeRange(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month, now.day))),
            ])
              ChoiceChip(label: Text(label), selected: range == r, onSelected: (_) => _setRange(r)),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range),
              label: const Text('Pilih tanggal'),
              onPressed: () async {
                final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now(), initialDateRange: range);
                if (r != null) _setRange(r);
              },
            ),
          ],
        ),
        ResponsiveGrid(minItemWidth: 230, children: [
          StatCard(label: 'Total omzet', value: rupiah(t['total']), icon: Icons.payments_outlined),
          StatCard(label: 'Eceran (kasir)', value: rupiah(t['retail']), icon: Icons.point_of_sale, caption: '${t['retailCount']} transaksi'),
          StatCard(label: 'B2B', value: rupiah(t['b2b']), icon: Icons.business_center_outlined, caption: '${t['b2bCount']} PO disetujui'),
          StatCard(label: 'Cloud printing', value: rupiah(t['print']), icon: Icons.print_outlined, caption: '${t['printCount']} pesanan dibayar'),
        ]),
        const SizedBox(height: 16),
        SectionCard(title: 'Omzet harian per kanal', child: RevenueChart(series: sales['series'] as List, height: 300)),
        const SizedBox(height: 16),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: topProducts), const SizedBox(width: 16), Expanded(flex: 2, child: side)])
        else ...[topProducts, const SizedBox(height: 16), side],
        const SizedBox(height: 24),
        Text('Laporan Gudang', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ResponsiveGrid(minItemWidth: 230, children: [
          StatCard(label: 'Nilai aset stok (HPP)', value: rupiah(inventory['summary']['stockValue']), icon: Icons.warehouse_outlined),
          StatCard(label: 'Potensi omzet (harga eceran)', value: rupiah(inventory['summary']['retailValue']), icon: Icons.sell_outlined),
          for (final m in inventory['movements30d'] as List)
            StatCard(
              label: '${statusOf(movementType, m['type']).label} · 30 hari',
              value: '${m['count']} mutasi',
              icon: statusOf(movementType, m['type']).icon,
              caption: '${number((m['qty'] as int).abs())} satuan terkecil',
            ),
        ]),
        const SizedBox(height: 16),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: valuation), const SizedBox(width: 16), Expanded(child: dead)])
        else ...[valuation, const SizedBox(height: 16), dead],
      ]);
    });
  }
}
