import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

class _CartLine {
  _CartLine(this.product, this.unitName);
  final Json product;
  String unitName;
  int qty = 1;

  List get units => product['units'] as List;
  Json get unit => units.firstWhere((u) => u['name'] == unitName) as Json;
  int get unitPrice => unit['price'] as int;
  int get subtotal => unitPrice * qty;
  int get baseQty => (unit['conversion'] as int) * qty;
}

/// Kasir (Point of Sale) eceran multi-satuan: setiap penjualan memotong stok otomatis.
class PosPage extends StatefulWidget {
  const PosPage({super.key});

  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosPageState extends State<PosPage> {
  List results = [];
  bool searching = false;
  String query = '';
  final cart = <_CartLine>[];
  String method = 'CASH';
  final paidCtrl = TextEditingController();
  bool busy = false;

  int get total => cart.fold(0, (s, l) => s + l.subtotal);
  int get paid => int.tryParse(paidCtrl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    setState(() {
      query = q;
      searching = true;
    });
    try {
      final res = await context.api.get('/api/inventory/products', query: {'q': q, 'limit': 12, 'sort': q.isEmpty ? 'updated' : 'name'});
      if (mounted && q == query) setState(() => results = res['data'] as List);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => searching = false);
  }

  int _baseInCart(Json product) => cart.where((l) => l.product['id'] == product['id']).fold(0, (s, l) => s + l.baseQty);

  void _add(Json product, String unitName) {
    final existing = cart.where((l) => l.product['id'] == product['id'] && l.unitName == unitName);
    setState(() {
      if (existing.isNotEmpty) {
        existing.first.qty++;
      } else {
        cart.add(_CartLine(product, unitName));
      }
    });
    if (_baseInCart(product) > (product['stock'] as int)) {
      showSnack(context, 'Jumlah melebihi stok ${product['name']} (${product['stockDisplay']})', error: true);
    }
  }

  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    if (method == 'CASH' && paid < total) {
      showSnack(context, 'Uang dibayar kurang dari total', error: true);
      return;
    }
    setState(() => busy = true);
    final res = await guard(context, () => context.api.post('/api/sales', {
          'paymentMethod': method,
          if (method == 'CASH') 'paidAmount': paid,
          'items': [for (final l in cart) {'productId': l.product['id'], 'unitName': l.unitName, 'qty': l.qty}],
        }));
    if (!mounted) return;
    setState(() => busy = false);
    if (res == null) return;
    setState(() {
      cart.clear();
      paidCtrl.clear();
    });
    _search(query);
    await _showReceipt(res['data'] as Json);
  }

  Future<void> _showReceipt(Json sale) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.check_circle, color: toneColor(ctx, Tone.good), size: 40),
        title: const Text('Transaksi berhasil'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${sale['code']} · ${fmtDateTime(sale['createdAt'])}', textAlign: TextAlign.center),
            const Divider(),
            for (final i in sale['items'] as List)
              TotalRow('${i['unitQty']} ${i['unitName']} ${i['name']}', rupiah(i['subtotal'])),
            const Divider(),
            TotalRow('Total', rupiah(sale['total']), emphasis: true),
            TotalRow('Dibayar (${paymentMethodLabel[sale['paymentMethod']]})', rupiah(sale['paidAmount'])),
            if ((sale['changeAmount'] as int) > 0) TotalRow('Kembalian', rupiah(sale['changeAmount']), emphasis: true),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Transaksi baru'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final search = _searchPanel(context);
    final cartPanel = _cartPanel(context);
    return Padding(
      padding: EdgeInsets.all(context.isWide ? 24 : 12),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: search),
              const SizedBox(width: 20),
              SizedBox(width: 440, child: cartPanel),
            ])
          : ListView(children: [SizedBox(height: 520, child: search), const SizedBox(height: 16), cartPanel]),
    );
  }

  Widget _searchPanel(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SearchBox(hint: 'Cari SKU / nama barang (mis. "pulpen hitam")', onChanged: _search, width: double.infinity, autofocus: true),
      const SizedBox(height: 8),
      if (searching) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: results.isEmpty && !searching
            ? const EmptyState(icon: Icons.search_off, message: 'Produk tidak ditemukan')
            : ListView.separated(
                itemCount: results.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = results[i] as Json;
                  final out = p['stockStatus'] == 'OUT';
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('${p['sku']} · ${p['hierarchy']}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                            ]),
                          ),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            StatusChip(statusOf(stockStatus, p['stockStatus']), dense: true),
                            const SizedBox(height: 2),
                            Text('Stok ${p['stockDisplay']}', style: const TextStyle(fontSize: 12)),
                          ]),
                        ]),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          for (final u in p['units'] as List)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                              onPressed: out ? null : () => _add(p, u['name']),
                              icon: const Icon(Icons.add, size: 16),
                              label: Text('${u['name']} · ${rupiah(u['price'])}'),
                            ),
                        ]),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _cartPanel(BuildContext context) {
    final change = paid - total;
    return SectionCard(
      title: 'Keranjang',
      subtitle: cart.isEmpty ? 'Belum ada barang' : '${cart.length} baris',
      trailing: cart.isEmpty ? null : TextButton(onPressed: () => setState(cart.clear), child: const Text('Kosongkan')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (cart.isEmpty) const EmptyState(icon: Icons.shopping_cart_outlined, message: 'Pilih barang di sebelah kiri'),
        for (final l in cart)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(l.product['name'], style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Hapus',
                  onPressed: () => setState(() => cart.remove(l)),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ]),
              Row(children: [
                DropdownButton<String>(
                  value: l.unitName,
                  isDense: true,
                  items: [for (final u in l.units) DropdownMenuItem(value: u['name'] as String, child: Text(u['name']))],
                  onChanged: (v) => setState(() => l.unitName = v!),
                ),
                const SizedBox(width: 8),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: l.qty > 1 ? () => setState(() => l.qty--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text('${l.qty}', style: const TextStyle(fontWeight: FontWeight.w700)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => l.qty++),
                  icon: const Icon(Icons.add_circle_outline),
                ),
                const Spacer(),
                Text(rupiah(l.subtotal), style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              Text('@ ${rupiah(l.unitPrice)} / ${l.unitName}', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
        const Divider(),
        TotalRow('Total', rupiah(total), emphasis: true),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'CASH', label: Text('Tunai'), icon: Icon(Icons.payments_outlined)),
            ButtonSegment(value: 'QRIS', label: Text('QRIS'), icon: Icon(Icons.qr_code)),
            ButtonSegment(value: 'TRANSFER', label: Text('Transfer'), icon: Icon(Icons.account_balance_outlined)),
          ],
          selected: {method},
          onSelectionChanged: (s) => setState(() => method = s.first),
        ),
        if (method == 'CASH') ...[
          const SizedBox(height: 12),
          TextField(
            controller: paidCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Uang diterima', prefixText: 'Rp '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final v in [total, 20000, 50000, 100000])
              if (v > 0)
                ActionChip(
                  label: Text(v == total ? 'Uang pas' : compactRupiah(v)),
                  onPressed: () => setState(() => paidCtrl.text = '$v'),
                ),
          ]),
          if (paid > 0) TotalRow(change >= 0 ? 'Kembalian' : 'Kurang', rupiah(change.abs()), color: change < 0 ? Theme.of(context).colorScheme.error : null),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: cart.isEmpty || busy ? null : _checkout,
          icon: const Icon(Icons.check),
          label: Text(busy ? 'Menyimpan…' : 'Bayar ${rupiah(total)}'),
        ),
      ]),
    );
  }
}
