import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  List categories = [];
  Json? summary;
  String q = '';
  int? categoryId;
  String? stock;
  String active = 'true';
  int page = 1;

  @override
  void initState() {
    super.initState();
    context.api.get('/api/inventory/categories').then((r) {
      if (mounted) setState(() => categories = r['data'] as List);
    }).catchError((_) {});
    reload();
    listenRealtime(['stock.changed'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([
      context.api.get('/api/inventory/products', query: {
        'q': q,
        'categoryId': categoryId,
        'stockStatus': stock,
        'active': active,
        'page': page,
        'limit': 25,
      }),
      context.api.get('/api/inventory/summary'),
    ]);
    rows = results[0]['data'] as List;
    meta = results[0]['meta'] as Json;
    summary = results[1]['data'] as Json;
  }

  void _filter(VoidCallback change) {
    change();
    page = 1;
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Produk & Stok',
            subtitle: summary == null
                ? null
                : '${number(summary!['totalSku'])} SKU aktif · nilai aset ${rupiah(summary!['stockValue'])} · ${summary!['lowCount']} menipis · ${summary!['outCount']} habis',
            actions: [
              OutlinedButton.icon(onPressed: () => _categoryDialog(context), icon: const Icon(Icons.category_outlined), label: const Text('Kategori')),
              FilledButton.icon(onPressed: () => context.go('/admin/products/new'), icon: const Icon(Icons.add), label: const Text('Tambah Produk')),
            ],
          ),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SearchBox(hint: 'Cari SKU / nama (bisa beberapa kata)', initial: q, onChanged: (v) => _filter(() => q = v)),
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
            for (final (value, label) in [(null, 'Semua'), ('OK', 'Aman'), ('LOW', 'Menipis'), ('OUT', 'Habis')])
              ChoiceChip(label: Text(label), selected: stock == value, onSelected: (_) => _filter(() => stock = value)),
            FilterChip(
              label: const Text('Tampilkan nonaktif'),
              selected: active == 'all',
              onSelected: (v) => _filter(() => active = v ? 'all' : 'true'),
            ),
          ]),
          const SizedBox(height: 16),
          Card(
            child: rows.isEmpty
                ? const EmptyState(icon: Icons.inventory_2_outlined, message: 'Tidak ada produk yang cocok')
                : ScrollTable(
                    minWidth: 980,
                    columns: const [
                      DataColumn(label: Text('SKU')),
                      DataColumn(label: Text('Nama Barang')),
                      DataColumn(label: Text('Hierarki Satuan')),
                      DataColumn(label: Text('Stok')),
                      DataColumn(label: Text('Batas Min.')),
                      DataColumn(label: Text('Harga Eceran'), numeric: true),
                      DataColumn(label: Text('')),
                    ],
                    rows: [
                      for (final p in rows)
                        DataRow(
                          onSelectChanged: (_) => context.go('/admin/products/${p['id']}'),
                          cells: [
                            DataCell(Text(p['sku'], style: const TextStyle(fontFamily: 'monospace'))),
                            DataCell(SizedBox(
                              width: 260,
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(p['name'], overflow: TextOverflow.ellipsis),
                                Text(p['category']?['name'] ?? '', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                              ]),
                            )),
                            DataCell(Text(p['hierarchy'], style: const TextStyle(fontSize: 12.5))),
                            DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                              StatusChip(statusOf(stockStatus, p['stockStatus']), dense: true),
                              const SizedBox(width: 8),
                              Text(p['stockDisplay']),
                            ])),
                            DataCell(Text(p['reorderDisplay'])),
                            DataCell(Text('${rupiah(p['retailPrice'])} / ${p['baseUnit']}')),
                            DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                tooltip: 'Riwayat mutasi',
                                icon: const Icon(Icons.swap_vert),
                                onPressed: () => context.go('/admin/movements?productId=${p['id']}'),
                              ),
                              IconButton(
                                tooltip: 'Terima barang',
                                icon: const Icon(Icons.move_to_inbox_outlined),
                                onPressed: () => context.go('/admin/stock-in?productId=${p['id']}'),
                              ),
                              if (p['isActive'] != true) const Chip(label: Text('Nonaktif')),
                            ])),
                          ],
                        ),
                    ],
                  ),
          ),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }

  Future<void> _categoryDialog(BuildContext context) async {
    final name = await promptText(context, title: 'Tambah kategori', label: 'Nama kategori', minLength: 2);
    if (name == null || !context.mounted) return;
    final res = await guard(context, () => context.api.post('/api/inventory/categories', {'name': name}), success: 'Kategori ditambahkan');
    if (res != null && context.mounted) {
      final r = await context.api.get('/api/inventory/categories');
      if (mounted) setState(() => categories = r['data'] as List);
    }
  }
}
