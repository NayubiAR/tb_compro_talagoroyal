import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/labels.dart';
import 'common.dart';

/// Dialog pencarian produk (SKU / nama) dari ribuan SKU, mengembalikan produk terpilih.
Future<Json?> pickProduct(BuildContext context, {String title = 'Pilih Produk'}) {
  return showWideDialog<Json>(context, maxWidth: 720, builder: (_) => _ProductPicker(title: title));
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker({required this.title});
  final String title;

  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  List<dynamic> results = [];
  bool loading = false;
  String query = '';

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    setState(() {
      query = q;
      loading = true;
    });
    try {
      final res = await context.api.get('/api/inventory/products', query: {'q': q, 'limit': 15, 'sort': q.isEmpty ? 'updated' : 'name'});
      if (mounted && q == query) setState(() => results = res['data'] as List);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return DialogFrame(
      title: widget.title,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SearchBox(hint: 'Ketik SKU atau nama barang…', onChanged: _search, width: double.infinity, autofocus: true),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (!loading && results.isEmpty) const EmptyState(icon: Icons.search_off, message: 'Produk tidak ditemukan'),
        for (final p in results)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(p['name']),
            subtitle: Text('${p['sku']} · ${p['hierarchy']} · Stok ${p['stockDisplay']}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              StatusChip(statusOf(stockStatus, p['stockStatus']), dense: true),
              const SizedBox(height: 2),
              Text(rupiah(p['retailPrice']), style: const TextStyle(fontSize: 12)),
            ]),
            onTap: () => Navigator.pop(context, p as Json),
          ),
      ]),
    );
  }
}

/// Input jumlah per satuan (mis. 2 Dus + 3 Pak + 4 Pcs) → total satuan terkecil.
class MultiUnitCounter extends StatelessWidget {
  const MultiUnitCounter({super.key, required this.units, required this.values, required this.onChanged});
  final List<dynamic> units;
  final Map<String, int> values;
  final VoidCallback onChanged;

  int get totalBase => units.fold(0, (s, u) => s + (values[u['name']] ?? 0) * (u['conversion'] as int));

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final u in units)
        SizedBox(
          width: 110,
          child: TextFormField(
            initialValue: '${values[u['name']] ?? 0}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: u['name'], suffixText: u['conversion'] == 1 ? null : '×${u['conversion']}'),
            onChanged: (v) {
              values[u['name']] = int.tryParse(v) ?? 0;
              onChanged();
            },
          ),
        ),
    ]);
  }
}

/// Format jumlah satuan terkecil menjadi satuan bertingkat (sama dengan logika backend).
String formatQtyClient(int baseQty, List<dynamic> units) {
  final sorted = [...units]..sort((a, b) => (b['conversion'] as int).compareTo(a['conversion'] as int));
  var rest = baseQty.abs();
  final parts = <String>[];
  for (final u in sorted) {
    final c = u['conversion'] as int;
    final q = rest ~/ c;
    rest -= q * c;
    if (q > 0) parts.add('$q ${u['name']}');
  }
  if (parts.isEmpty) return '0 ${sorted.isEmpty ? '' : sorted.last['name']}';
  return (baseQty < 0 ? '-' : '') + parts.join(' ');
}
