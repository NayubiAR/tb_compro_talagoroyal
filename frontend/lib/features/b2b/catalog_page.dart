import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../state/po_draft.dart';
import '../../widgets/common.dart';

/// Katalog grosir tertutup khusus mitra terverifikasi, lengkap dengan tabel harga tiering.
class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> with LoaderMixin {
  List rows = [];
  Json? meta;
  List categories = [];
  String q = '';
  int? categoryId;
  bool inStock = false;
  int page = 1;

  @override
  void initState() {
    super.initState();
    context.api.get('/api/b2b/categories').then((r) {
      if (mounted) setState(() => categories = r['data'] as List);
    }).catchError((_) {});
    reload();
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/b2b/catalog', query: {
      'q': q,
      'categoryId': categoryId,
      'inStock': inStock ? 'true' : null,
      'page': page,
      'limit': 24,
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
    final draft = context.watch<PoDraft>();
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Katalog Grosir',
            subtitle: 'Harga sudah termasuk tiering kuantitas. Diskon level ${meta?['levelName'] ?? '-'} (${meta?['discountPercent'] ?? 0}%) dihitung di total PO.',
            actions: [
              FilledButton.icon(
                onPressed: () => context.go('/b2b/quick-po'),
                icon: Badge(isLabelVisible: draft.count > 0, label: Text('${draft.count}'), child: const Icon(Icons.table_view_outlined)),
                label: const Text('Lanjut ke Quick PO'),
              ),
            ],
          ),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SearchBox(hint: 'Cari barang / SKU', onChanged: (v) => _filter(() => q = v)),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<int?>(
                initialValue: categoryId,
                decoration: const InputDecoration(labelText: 'Kategori'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Semua kategori')),
                  for (final c in categories) DropdownMenuItem(value: c['id'] as int, child: Text(c['name'])),
                ],
                onChanged: (v) => _filter(() => categoryId = v),
              ),
            ),
            FilterChip(label: const Text('Hanya yang tersedia'), selected: inStock, onSelected: (v) => _filter(() => inStock = v)),
          ]),
          const SizedBox(height: 16),
          if (rows.isEmpty) const EmptyState(icon: Icons.search_off, message: 'Barang tidak ditemukan'),
          ResponsiveGrid(minItemWidth: 330, children: [for (final p in rows) _CatalogCard(product: p as Json)]),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }
}

class _CatalogCard extends StatefulWidget {
  const _CatalogCard({required this.product});
  final Json product;

  @override
  State<_CatalogCard> createState() => _CatalogCardState();
}

class _CatalogCardState extends State<_CatalogCard> {
  late String unit = (widget.product['units'] as List).first['name'] as String;
  final qty = TextEditingController(text: '1');

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final muted = TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant);
    final good = toneColor(context, Tone.good);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'], style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${p['sku']} · ${p['category']}', style: muted),
              ]),
            ),
            StatusChip(statusOf(availability, p['availability']), dense: true),
          ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Mulai ${rupiah(p['startingUnitPrice'])}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(' / ${p['baseUnit']}', style: muted),
            const SizedBox(width: 8),
            if ((p['retailUnitPrice'] as int) > (p['startingUnitPrice'] as int))
              Text(rupiah(p['retailUnitPrice']), style: muted.copyWith(decoration: TextDecoration.lineThrough)),
          ]),
          const SizedBox(height: 8),
          for (final t in p['priceTiers'] as List)
            Row(children: [
              Icon(Icons.trending_down, size: 14, color: good),
              const SizedBox(width: 4),
              Expanded(child: Text('≥ ${t['minQtyDisplay']}', style: const TextStyle(fontSize: 12.5))),
              Text('${rupiah(t['unitPrice'])}/${p['baseUnit']}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              if ((t['savingsPercent'] as int) > 0) Text('  -${t['savingsPercent']}%', style: TextStyle(fontSize: 12, color: good)),
            ]),
          const Divider(height: 18),
          Wrap(spacing: 10, runSpacing: 2, children: [
            for (final u in p['units'] as List) Text('${u['name']} ${rupiah(u['b2bPrice'])}', style: muted),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(width: 70, child: TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Qty'))),
            const SizedBox(width: 8),
            SizedBox(
              width: 100,
              child: DropdownButtonFormField<String>(
                initialValue: unit,
                items: [for (final u in p['units'] as List) DropdownMenuItem(value: u['name'] as String, child: Text(u['name']))],
                onChanged: (v) => setState(() => unit = v!),
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: p['availability'] == 'HABIS'
                  ? null
                  : () {
                      final n = int.tryParse(qty.text) ?? 0;
                      if (n < 1) return;
                      context.read<PoDraft>().add(p['sku'], unit, n);
                      showSnack(
                        context,
                        '$n $unit ${p['name']} ditambahkan ke draf PO',
                        action: SnackBarAction(label: 'Buka PO', onPressed: () => context.go('/b2b/quick-po')),
                      );
                    },
              icon: const Icon(Icons.add_shopping_cart, size: 18),
              label: const Text('Tambah'),
            ),
          ]),
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('Stok: ${p['stockDisplay']}', style: muted)),
        ]),
      ),
    );
  }
}
