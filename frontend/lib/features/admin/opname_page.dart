import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/product_picker.dart';

class _OpnameLine {
  _OpnameLine(this.product) : counts = {for (final u in product['units'] as List) u['name'] as String: 0};
  final Json product;
  final Map<String, int> counts;

  List get units => product['units'] as List;
  int get counted => units.fold(0, (s, u) => s + (counts[u['name']] ?? 0) * (u['conversion'] as int));
  int get diff => counted - (product['stock'] as int);
}

/// Stock opname: hitung fisik per satuan (Dus/Pak/Pcs) → sistem menyesuaikan selisih.
class OpnamePage extends StatefulWidget {
  const OpnamePage({super.key});

  @override
  State<OpnamePage> createState() => _OpnamePageState();
}

class _OpnamePageState extends State<OpnamePage> with LoaderMixin {
  final lines = <_OpnameLine>[];
  final note = TextEditingController();
  List history = [];
  Json? meta;
  int page = 1;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/inventory/opnames', query: {'page': page, 'limit': 10});
    history = res['data'] as List;
    meta = res['meta'] as Json;
  }

  Future<void> _add() async {
    final p = await pickProduct(context, title: 'Tambah barang yang dihitung');
    if (p == null) return;
    if (lines.any((l) => l.product['id'] == p['id'])) {
      if (mounted) showSnack(context, 'Barang sudah ada di daftar', error: true);
      return;
    }
    setState(() => lines.add(_OpnameLine(p)));
  }

  Future<void> _save() async {
    final changed = lines.where((l) => l.diff != 0).length;
    final ok = await confirmDialog(
      context,
      title: 'Simpan hasil opname?',
      message: '${lines.length} barang dihitung, $changed barang akan disesuaikan stoknya. Penyesuaian tercatat di ledger mutasi & jejak audit.',
    );
    if (!ok || !mounted) return;
    setState(() => saving = true);
    final res = await guard(
      context,
      () => context.api.post('/api/inventory/opnames', {
        'note': note.text,
        'items': [
          for (final l in lines)
            {
              'productId': l.product['id'],
              'counts': [for (final e in l.counts.entries) {'unitName': e.key, 'qty': e.value}],
            },
        ],
      }),
    );
    if (!mounted) return;
    setState(() => saving = false);
    if (res == null) return;
    showSnack(context, 'Opname ${res['data']['code']} tersimpan');
    setState(() {
      lines.clear();
      note.clear();
    });
    reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Stock Opname',
            subtitle: 'Masukkan hasil hitung fisik dalam satuan apa pun; sistem menjumlahkan ke satuan terkecil dan mencatat selisih.',
            actions: [
              OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Tambah barang')),
              FilledButton.icon(onPressed: lines.isEmpty || saving ? null : _save, icon: const Icon(Icons.fact_check_outlined), label: const Text('Simpan opname')),
            ],
          ),
          SectionCard(
            title: 'Lembar hitung',
            trailing: SizedBox(width: 320, child: TextField(controller: note, decoration: const InputDecoration(labelText: 'Catatan (mis. rak A)'))),
            child: lines.isEmpty
                ? const EmptyState(icon: Icons.fact_check_outlined, message: 'Tambahkan barang yang akan dihitung')
                : Column(children: [
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          SizedBox(
                            width: 280,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(l.product['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('${l.product['sku']} · sistem: ${l.product['stockDisplay']}', style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                          MultiUnitCounter(units: l.units, values: l.counts, onChanged: () => setState(() {})),
                          _diffBadge(l),
                          IconButton(onPressed: () => setState(() => lines.remove(l)), icon: const Icon(Icons.delete_outline)),
                        ]),
                      ),
                  ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Riwayat opname',
            padding: EdgeInsets.zero,
            child: Column(children: [
              ScrollTable(
                columns: const [
                  DataColumn(label: Text('Kode')),
                  DataColumn(label: Text('Tanggal')),
                  DataColumn(label: Text('Catatan')),
                  DataColumn(label: Text('Dihitung'), numeric: true),
                  DataColumn(label: Text('Disesuaikan'), numeric: true),
                  DataColumn(label: Text('Petugas')),
                ],
                rows: [
                  for (final o in history)
                    DataRow(onSelectChanged: (_) => _detail(o['id'] as int), cells: [
                      DataCell(Text(o['code'])),
                      DataCell(Text(fmtDateTime(o['createdAt']))),
                      DataCell(Text(o['note'] ?? '-')),
                      DataCell(Text('${o['itemCount']}')),
                      DataCell(Text('${o['adjustedCount']}')),
                      DataCell(Text(o['user'])),
                    ]),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Paginator(meta: meta, onPage: (p) {
                  page = p;
                  reload();
                }),
              ),
            ]),
          ),
        ]));
  }

  Widget _diffBadge(_OpnameLine l) {
    final d = l.diff;
    final tone = d == 0 ? Tone.good : (d < 0 ? Tone.critical : Tone.info);
    final color = toneColor(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Fisik: ${formatQtyClient(l.counted, l.units)}', style: const TextStyle(fontSize: 12.5)),
        Text(d == 0 ? 'Sesuai' : 'Selisih ${d > 0 ? '+' : ''}${formatQtyClient(d, l.units)}', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Future<void> _detail(int id) async {
    final res = await guard(context, () => context.api.get('/api/inventory/opnames/$id'));
    if (res == null || !mounted) return;
    final o = res['data'] as Json;
    await showWideDialog(
      context,
      builder: (_) => DialogFrame(
        title: o['code'],
        subtitle: '${fmtDateTime(o['createdAt'])} · ${o['user']} · ${o['note'] ?? ''}',
        child: ScrollTable(
          minWidth: 700,
          columns: const [
            DataColumn(label: Text('Barang')),
            DataColumn(label: Text('Sistem')),
            DataColumn(label: Text('Fisik')),
            DataColumn(label: Text('Selisih')),
            DataColumn(label: Text('Nilai selisih'), numeric: true),
          ],
          rows: [
            for (final i in o['items'] as List)
              DataRow(cells: [
                DataCell(Text('${i['sku']} ${i['name']}')),
                DataCell(Text(i['systemDisplay'])),
                DataCell(Text(i['countedDisplay'])),
                DataCell(Text(i['differenceDisplay'])),
                DataCell(Text(rupiah(i['differenceValue']))),
              ]),
          ],
        ),
      ),
    );
  }
}
