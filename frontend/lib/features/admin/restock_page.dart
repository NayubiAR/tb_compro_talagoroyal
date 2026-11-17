import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Smart Restock Alert: prioritas berdasarkan level & kecepatan jual 30 hari.
class RestockPage extends StatefulWidget {
  const RestockPage({super.key});

  @override
  State<RestockPage> createState() => _RestockPageState();
}

class _RestockPageState extends State<RestockPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json counts = {};
  String? level;
  bool fastOnly = false;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['stock.changed'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/inventory/restock-alerts', query: {'level': level, 'fastOnly': fastOnly ? 'true' : null, 'limit': 500});
    rows = res['data'] as List;
    counts = res['counts'] as Json;
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final totalCost = rows.fold<int>(0, (s, r) => s + (r['estimatedCost'] as int));
      return PageBody(children: [
        const PageHeader(
          title: 'Smart Restock Alert',
          subtitle: 'Habis = stok 0 · Kritis = stok ≤ batas minimum · Waspada = diperkirakan habis sebelum pasokan datang (lead time).',
        ),
        ResponsiveGrid(minItemWidth: 220, children: [
          StatCard(label: 'Habis', value: '${counts['HABIS']}', icon: Icons.error_outline, tone: Tone.critical, onTap: () => _setLevel('HABIS')),
          StatCard(label: 'Kritis', value: '${counts['KRITIS']}', icon: Icons.warning_amber, tone: Tone.serious, onTap: () => _setLevel('KRITIS')),
          StatCard(label: 'Waspada', value: '${counts['WASPADA']}', icon: Icons.trending_down, tone: Tone.warning, onTap: () => _setLevel('WASPADA')),
          StatCard(
            label: 'Fast-moving terdampak',
            value: '${counts['fastMoving']}',
            icon: Icons.local_fire_department_outlined,
            caption: '20% barang terlaris 30 hari',
            onTap: () {
              fastOnly = !fastOnly;
              reload();
            },
          ),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final (v, l) in [(null, 'Semua level'), ('HABIS', 'Habis'), ('KRITIS', 'Kritis'), ('WASPADA', 'Waspada')])
            ChoiceChip(label: Text(l), selected: level == v, onSelected: (_) => _setLevel(v)),
          FilterChip(
            avatar: const Icon(Icons.local_fire_department, size: 16),
            label: const Text('Hanya fast-moving'),
            selected: fastOnly,
            onSelected: (v) {
              fastOnly = v;
              reload();
            },
          ),
          const SizedBox(width: 12),
          Text('${rows.length} barang · estimasi biaya restock ${rupiah(totalCost)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        Card(
          child: rows.isEmpty
              ? const EmptyState(icon: Icons.check_circle_outline, message: 'Tidak ada barang yang perlu di-restock')
              : ScrollTable(
                  minWidth: 1100,
                  columns: const [
                    DataColumn(label: Text('Level')),
                    DataColumn(label: Text('Barang')),
                    DataColumn(label: Text('Stok')),
                    DataColumn(label: Text('Batas Min.')),
                    DataColumn(label: Text('Terjual 30 hr')),
                    DataColumn(label: Text('Hari tersisa'), numeric: true),
                    DataColumn(label: Text('Saran pesan')),
                    DataColumn(label: Text('Estimasi biaya'), numeric: true),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final r in rows)
                      DataRow(cells: [
                        DataCell(StatusChip(statusOf(restockLevel, r['level']), dense: true)),
                        DataCell(SizedBox(
                          width: 260,
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(r['name'], overflow: TextOverflow.ellipsis)),
                              if (r['fastMoving'] == true)
                                Tooltip(
                                  message: 'Fast-moving',
                                  child: Icon(Icons.local_fire_department, size: 16, color: toneColor(context, Tone.serious)),
                                ),
                            ]),
                            Text('${r['sku']} · ${r['category']}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ]),
                        )),
                        DataCell(Text(r['stockDisplay'])),
                        DataCell(Text(r['reorderDisplay'])),
                        DataCell(Text('${r['soldDisplay']}\n≈ ${r['avgDailyUsage']}/hari', style: const TextStyle(fontSize: 12.5))),
                        DataCell(Text(r['daysOfCover'] == null ? '-' : '${r['daysOfCover']} hr (LT ${r['leadTimeDays']})')),
                        DataCell(Text(r['suggestedOrderDisplay'], style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(Text(rupiah(r['estimatedCost']))),
                        DataCell(FilledButton.tonal(
                          onPressed: () => context.go('/admin/stock-in?productId=${r['productId']}&qty=${r['suggestedOrderQty']}'),
                          child: const Text('Terima barang'),
                        )),
                      ]),
                  ],
                ),
        ),
      ]);
    });
  }

  void _setLevel(String? v) {
    level = level == v ? null : v;
    reload();
  }
}
