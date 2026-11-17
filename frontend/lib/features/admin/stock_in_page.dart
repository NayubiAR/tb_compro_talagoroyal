import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import '../../widgets/product_picker.dart';

class _Line {
  _Line(this.product, {int qty = 1}) : unitName = ((product['units'] as List).first)['name'] as String, qty = TextEditingController(text: '$qty');
  final Json product;
  String unitName;
  final TextEditingController qty;
  final cost = TextEditingController();

  int get conversion => ((product['units'] as List).firstWhere((u) => u['name'] == unitName))['conversion'] as int;
}

/// Penerimaan barang (stok masuk) dari pemasok — mendukung input per Dus/Pak/Pcs.
class StockInPage extends StatefulWidget {
  const StockInPage({super.key, this.productId, this.suggestedQty});
  final int? productId;
  final int? suggestedQty;

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> with LoaderMixin {
  final supplier = TextEditingController();
  final reference = TextEditingController();
  final note = TextEditingController();
  final lines = <_Line>[];
  List history = [];
  Json? meta;
  int page = 1;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    reload();
    if (widget.productId != null) _prefill(widget.productId!);
  }

  Future<void> _prefill(int id) async {
    final res = await guard(context, () => context.api.get('/api/inventory/products/$id'));
    if (res == null || !mounted) return;
    final p = res['data'] as Json;
    final line = _Line(p);
    final top = (p['units'] as List).first;
    if (widget.suggestedQty != null && widget.suggestedQty! > 0) {
      line.qty.text = '${(widget.suggestedQty! / (top['conversion'] as int)).ceil()}';
    }
    setState(() => lines.add(line));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/inventory/receipts', query: {'page': page, 'limit': 10});
    history = res['data'] as List;
    meta = res['meta'] as Json;
  }

  Future<void> _add() async {
    final p = await pickProduct(context, title: 'Tambah barang diterima');
    if (p != null) setState(() => lines.add(_Line(p)));
  }

  Future<void> _save() async {
    if (lines.isEmpty) return;
    final items = [
      for (final l in lines)
        {
          'productId': l.product['id'],
          'unitName': l.unitName,
          'qty': int.tryParse(l.qty.text) ?? 0,
          'unitCost': int.tryParse(l.cost.text) ?? 0,
        },
    ];
    if (items.any((i) => (i['qty'] as int) < 1)) {
      showSnack(context, 'Jumlah setiap barang minimal 1', error: true);
      return;
    }
    setState(() => saving = true);
    final res = await guard(
      context,
      () => context.api.post('/api/inventory/receipts', {
        'supplier': supplier.text,
        'reference': reference.text,
        'note': note.text,
        'items': items,
      }),
    );
    if (!mounted) return;
    setState(() => saving = false);
    if (res == null) return;
    final r = res['data'] as Json;
    showSnack(context, 'Penerimaan ${r['code']} tersimpan · ${(r['items'] as List).length} barang masuk stok');
    setState(() {
      lines.clear();
      supplier.clear();
      reference.clear();
      note.clear();
    });
    reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Penerimaan Barang',
            subtitle: 'Stok bertambah otomatis & HPP dihitung ulang (rata-rata tertimbang) bila harga beli diisi.',
            actions: [
              OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Tambah barang')),
              FilledButton.icon(
                onPressed: lines.isEmpty || saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Simpan penerimaan'),
              ),
            ],
          ),
          SectionCard(
            title: 'Dokumen pemasok',
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(width: 280, child: TextField(controller: supplier, decoration: const InputDecoration(labelText: 'Pemasok'))),
              SizedBox(width: 220, child: TextField(controller: reference, decoration: const InputDecoration(labelText: 'No. surat jalan / faktur'))),
              SizedBox(width: 360, child: TextField(controller: note, decoration: const InputDecoration(labelText: 'Catatan'))),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Barang diterima',
            child: lines.isEmpty
                ? EmptyState(
                    icon: Icons.move_to_inbox_outlined,
                    message: 'Belum ada barang. Tambahkan dari katalog.',
                    action: OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Tambah barang')),
                  )
                : Column(children: [for (final l in lines) _lineRow(l)]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Riwayat penerimaan',
            padding: EdgeInsets.zero,
            child: Column(children: [
              ScrollTable(
                columns: const [
                  DataColumn(label: Text('Kode')),
                  DataColumn(label: Text('Tanggal')),
                  DataColumn(label: Text('Pemasok')),
                  DataColumn(label: Text('Referensi')),
                  DataColumn(label: Text('Jumlah item'), numeric: true),
                  DataColumn(label: Text('Petugas')),
                ],
                rows: [
                  for (final r in history)
                    DataRow(
                      onSelectChanged: (_) => _detail(r['id'] as int),
                      cells: [
                        DataCell(Text(r['code'])),
                        DataCell(Text(fmtDateTime(r['createdAt']))),
                        DataCell(Text(r['supplier'] ?? '-')),
                        DataCell(Text(r['reference'] ?? '-')),
                        DataCell(Text('${r['itemCount']}')),
                        DataCell(Text(r['user'] ?? '-')),
                      ],
                    ),
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

  Widget _lineRow(_Line l) {
    final units = l.product['units'] as List;
    final qty = int.tryParse(l.qty.text) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 300,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.product['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${l.product['sku']} · stok kini ${l.product['stockDisplay']}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
        SizedBox(width: 90, child: TextField(controller: l.qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Jumlah'), onChanged: (_) => setState(() {}))),
        SizedBox(
          width: 110,
          child: DropdownButtonFormField<String>(
            initialValue: l.unitName,
            decoration: const InputDecoration(labelText: 'Satuan'),
            items: [for (final u in units) DropdownMenuItem(value: u['name'] as String, child: Text(u['name']))],
            onChanged: (v) => setState(() => l.unitName = v!),
          ),
        ),
        SizedBox(
          width: 170,
          child: TextField(controller: l.cost, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Harga beli / ${l.unitName}', prefixText: 'Rp ')),
        ),
        Text('= ${number(qty * l.conversion)} ${l.product['baseUnit']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(onPressed: () => setState(() => lines.remove(l)), icon: const Icon(Icons.delete_outline), tooltip: 'Hapus'),
      ]),
    );
  }

  Future<void> _detail(int id) async {
    final res = await guard(context, () => context.api.get('/api/inventory/receipts/$id'));
    if (res == null || !mounted) return;
    final r = res['data'] as Json;
    await showWideDialog(
      context,
      maxWidth: 720,
      builder: (_) => DialogFrame(
        title: r['code'],
        subtitle: '${fmtDateTime(r['createdAt'])} · ${r['supplier'] ?? '-'} · ${r['user']}',
        child: Column(children: [
          for (final i in r['items'] as List)
            ListTile(
              dense: true,
              title: Text(i['name']),
              subtitle: Text(i['sku']),
              trailing: Text('${i['unitQty']} ${i['unitName']} (${i['qtyDisplay']})'),
            ),
        ]),
      ),
    );
  }
}
