import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Riwayat keluar-masuk barang (ledger mutasi stok).
class MovementsPage extends StatefulWidget {
  const MovementsPage({super.key, this.productId});
  final int? productId;

  @override
  State<MovementsPage> createState() => _MovementsPageState();
}

class _MovementsPageState extends State<MovementsPage> with LoaderMixin {
  List rows = [];
  Json? meta;
  String q = '';
  String? type;
  DateTimeRange? range;
  int page = 1;
  late int? productId = widget.productId;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/inventory/movements', query: {
      'productId': productId,
      'q': q,
      'type': type,
      'from': range == null ? null : ymd(range!.start),
      'to': range == null ? null : ymd(range!.end),
      'page': page,
      'limit': 30,
    });
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  void _filter(VoidCallback f) {
    f();
    page = 1;
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Mutasi Stok',
            subtitle: productId != null && rows.isNotEmpty
                ? 'Riwayat ${rows.first['product']['sku']} ${rows.first['product']['name']}'
                : 'Ledger seluruh keluar-masuk barang: penerimaan, penjualan, B2B, penyesuaian & retur.',
          ),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (productId != null)
              InputChip(label: const Text('Filter produk aktif'), onDeleted: () => _filter(() => productId = null))
            else
              SearchBox(hint: 'Cari SKU / nama barang', onChanged: (v) => _filter(() => q = v)),
            DropdownButton<String?>(
              value: type,
              hint: const Text('Semua jenis'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Semua jenis')),
                for (final e in movementType.entries) DropdownMenuItem(value: e.key, child: Text(e.value.label)),
              ],
              onChanged: (v) => _filter(() => type = v),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range),
              label: Text(range == null ? 'Semua tanggal' : '${fmtDate(range!.start)} – ${fmtDate(range!.end)}'),
              onPressed: () async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now(),
                  initialDateRange: range,
                );
                if (r != null) _filter(() => range = r);
              },
            ),
            if (range != null) TextButton(onPressed: () => _filter(() => range = null), child: const Text('Reset tanggal')),
          ]),
          const SizedBox(height: 16),
          Card(
            child: rows.isEmpty
                ? const EmptyState(icon: Icons.swap_vert, message: 'Tidak ada mutasi')
                : ScrollTable(
                    minWidth: 1080,
                    columns: const [
                      DataColumn(label: Text('Waktu')),
                      DataColumn(label: Text('Barang')),
                      DataColumn(label: Text('Jenis')),
                      DataColumn(label: Text('Jumlah')),
                      DataColumn(label: Text('Saldo')),
                      DataColumn(label: Text('Referensi')),
                      DataColumn(label: Text('Petugas / Catatan')),
                    ],
                    rows: [
                      for (final m in rows)
                        DataRow(cells: [
                          DataCell(Text(fmtDateTime(m['createdAt']))),
                          DataCell(SizedBox(width: 240, child: Text('${m['product']['sku']} · ${m['product']['name']}', overflow: TextOverflow.ellipsis))),
                          DataCell(StatusChip(statusOf(movementType, m['type']), dense: true)),
                          DataCell(Text(
                            '${(m['qty'] as int) > 0 ? '+' : ''}${m['qtyDisplay']}${m['unitName'] != null && m['unitQty'] != null ? '\n(${m['unitQty']} ${m['unitName']})' : ''}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: toneColor(context, (m['qty'] as int) > 0 ? Tone.good : Tone.critical),
                            ),
                          )),
                          DataCell(Text(m['balanceDisplay'])),
                          DataCell(Text(m['refCode'] ?? '-')),
                          DataCell(SizedBox(width: 220, child: Text('${m['user'] ?? '-'}${m['note'] != null ? '\n${m['note']}' : ''}', style: const TextStyle(fontSize: 12.5)))),
                        ]),
                    ],
                  ),
          ),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }
}
