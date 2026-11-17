import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';
import '../../widgets/product_picker.dart';

class _UnitRow {
  _UnitRow({String name = '', int conversion = 1, int price = 0})
      : name = TextEditingController(text: name),
        conversion = TextEditingController(text: '$conversion'),
        price = TextEditingController(text: '$price');
  final TextEditingController name;
  final TextEditingController conversion;
  final TextEditingController price;

  Json toJson() => {'name': name.text.trim(), 'conversion': int.tryParse(conversion.text) ?? 0, 'price': int.tryParse(price.text) ?? 0};
}

class _TierRow {
  _TierRow({int minQty = 1, int unitPrice = 0})
      : minQty = TextEditingController(text: '$minQty'),
        unitPrice = TextEditingController(text: '$unitPrice');
  final TextEditingController minQty;
  final TextEditingController unitPrice;

  Json toJson() => {'minQty': int.tryParse(minQty.text) ?? 0, 'unitPrice': int.tryParse(unitPrice.text) ?? 0};
}

/// Form tambah/ubah produk: hierarki multi-satuan dinamis + harga tiering B2B.
class ProductFormPage extends StatefulWidget {
  const ProductFormPage({super.key, this.productId});
  final int? productId;

  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> with LoaderMixin {
  final _form = GlobalKey<FormState>();
  final sku = TextEditingController();
  final name = TextEditingController();
  final description = TextEditingController();
  final costPrice = TextEditingController(text: '0');
  final reorderQty = TextEditingController(text: '0');
  final leadTime = TextEditingController(text: '3');
  final initialQty = TextEditingController(text: '0');
  String reorderUnit = '';
  String initialUnit = '';
  int? categoryId;
  bool isActive = true;
  List categories = [];
  List<_UnitRow> units = [];
  List<_TierRow> tiers = [];
  Json? product;
  bool saving = false;

  bool get editing => widget.productId != null;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final api = context.api;
    categories = (await api.get('/api/inventory/categories'))['data'] as List;
    if (!editing) {
      units = [_UnitRow(name: 'Dus', conversion: 60), _UnitRow(name: 'Pak', conversion: 12), _UnitRow(name: 'Pcs', conversion: 1)];
      tiers = [_TierRow(minQty: 1)];
      reorderUnit = initialUnit = 'Pcs';
      return;
    }
    product = (await api.get('/api/inventory/products/${widget.productId}'))['data'] as Json;
    final p = product!;
    sku.text = p['sku'];
    name.text = p['name'];
    description.text = p['description'] ?? '';
    costPrice.text = '${p['costPrice']}';
    reorderQty.text = '${p['reorderPoint']}';
    leadTime.text = '${p['leadTimeDays']}';
    categoryId = p['categoryId'] as int;
    isActive = p['isActive'] == true;
    units = [for (final u in p['units'] as List) _UnitRow(name: u['name'], conversion: u['conversion'], price: u['price'])];
    tiers = [for (final t in p['priceTiers'] as List) _TierRow(minQty: t['minQty'], unitPrice: t['unitPrice'])];
    reorderUnit = p['baseUnit'];
  }

  List<Json> get _unitJson => [for (final u in units) u.toJson()]..sort((a, b) => (b['conversion'] as int).compareTo(a['conversion'] as int));
  Json? get _baseUnit => _unitJson.where((u) => u['conversion'] == 1).firstOrNull;

  int _toBase(TextEditingController qty, String unitName) {
    final unit = _unitJson.where((u) => u['name'] == unitName).firstOrNull ?? _baseUnit;
    return (int.tryParse(qty.text) ?? 0) * ((unit?['conversion'] as int?) ?? 1);
  }

  /// Validasi hierarki di sisi UI (aturan yang sama ditegakkan backend).
  String? _hierarchyError() {
    final list = _unitJson;
    if (list.isEmpty) return 'Minimal satu satuan';
    if (list.any((u) => (u['name'] as String).isEmpty)) return 'Nama satuan wajib diisi';
    if (list.last['conversion'] != 1) return 'Harus ada satuan terkecil dengan konversi 1';
    for (var i = 0; i < list.length - 1; i++) {
      final big = list[i], small = list[i + 1];
      if (big['conversion'] == small['conversion']) return 'Konversi ${big['name']} dan ${small['name']} sama';
      if ((big['conversion'] as int) % (small['conversion'] as int) != 0) {
        return '1 ${big['name']} (${big['conversion']}) tidak habis dibagi ${small['name']} (${small['conversion']})';
      }
    }
    return null;
  }

  String get _hierarchyPreview {
    final list = _unitJson;
    if (_hierarchyError() != null) return '';
    final top = list.first['conversion'] as int;
    return [for (var i = 0; i < list.length; i++) i == 0 ? '1 ${list[i]['name']}' : '${top ~/ (list[i]['conversion'] as int)} ${list[i]['name']}'].join(' = ');
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final err = _hierarchyError();
    if (err != null) {
      showSnack(context, err, error: true);
      return;
    }
    setState(() => saving = true);
    final body = {
      'sku': sku.text.trim(),
      'name': name.text.trim(),
      'description': description.text.trim(),
      'categoryId': categoryId,
      'costPrice': int.tryParse(costPrice.text) ?? 0,
      'reorderPoint': _toBase(reorderQty, reorderUnit),
      'leadTimeDays': int.tryParse(leadTime.text) ?? 3,
      'isActive': isActive,
      'units': _unitJson,
      'priceTiers': [for (final t in tiers) t.toJson()],
      if (!editing) 'initialStock': _toBase(initialQty, initialUnit),
    };
    final res = await guard(
      context,
      () => editing ? context.api.put('/api/inventory/products/${widget.productId}', body) : context.api.post('/api/inventory/products', body),
      success: editing ? 'Produk diperbarui' : 'Produk ditambahkan',
    );
    if (!mounted) return;
    setState(() => saving = false);
    if (res != null) context.go('/admin/products');
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final unitNames = [for (final u in _unitJson) u['name'] as String].where((n) => n.isNotEmpty).toList();
      if (!unitNames.contains(reorderUnit) && unitNames.isNotEmpty) reorderUnit = unitNames.last;
      if (!unitNames.contains(initialUnit) && unitNames.isNotEmpty) initialUnit = unitNames.last;
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_infoCard(), const SizedBox(height: 16), _unitsCard(unitNames)]);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _stockCard(unitNames),
        const SizedBox(height: 16),
        _tiersCard(),
        if (product != null) ...[const SizedBox(height: 16), _historyCard()],
      ]);
      return Form(
        key: _form,
        child: PageBody(maxWidth: 1300, children: [
          PageHeader(
            title: editing ? 'Ubah Produk' : 'Tambah Produk',
            subtitle: editing ? '${product!['sku']} · stok ${product!['stockDisplay']}' : 'Stok selalu disimpan dalam satuan terkecil — konversi otomatis.',
            actions: [
              OutlinedButton(onPressed: () => context.go('/admin/products'), child: const Text('Batal')),
              FilledButton.icon(onPressed: saving ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Simpan')),
            ],
          ),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: left), const SizedBox(width: 16), Expanded(child: right)])
          else ...[left, const SizedBox(height: 16), right],
        ]),
      );
    });
  }

  Widget _infoCard() {
    return SectionCard(
      title: 'Informasi barang',
      child: Column(children: [
        Row(children: [
          SizedBox(
            width: 180,
            child: TextFormField(
              controller: sku,
              decoration: const InputDecoration(labelText: 'SKU'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Wajib diisi' : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: categoryId,
              decoration: const InputDecoration(labelText: 'Kategori'),
              items: [for (final c in categories) DropdownMenuItem(value: c['id'] as int, child: Text(c['name']))],
              onChanged: (v) => setState(() => categoryId = v),
              validator: (v) => v == null ? 'Pilih kategori' : null,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextFormField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Nama barang'),
          validator: (v) => (v ?? '').trim().length < 2 ? 'Wajib diisi' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(controller: description, maxLines: 2, decoration: const InputDecoration(labelText: 'Deskripsi (opsional)')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Aktif dijual'),
          value: isActive,
          onChanged: (v) => setState(() => isActive = v),
        ),
      ]),
    );
  }

  Widget _unitsCard(List<String> unitNames) {
    final err = _hierarchyError();
    return SectionCard(
      title: 'Hierarki multi-satuan',
      subtitle: 'Konversi = jumlah satuan terkecil dalam 1 satuan. Harga = harga eceran per satuan.',
      trailing: TextButton.icon(
        onPressed: units.length >= 6 ? null : () => setState(() => units.add(_UnitRow(conversion: 0))),
        icon: const Icon(Icons.add),
        label: const Text('Satuan'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final u in units)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Expanded(flex: 3, child: TextField(controller: u.name, decoration: const InputDecoration(labelText: 'Satuan'), onChanged: (_) => setState(() {}))),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(controller: u.conversion, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Konversi'), onChanged: (_) => setState(() {})),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: TextField(controller: u.price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Harga eceran', prefixText: 'Rp '))),
              IconButton(
                onPressed: units.length <= 1 ? null : () => setState(() => units.remove(u)),
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: 'Hapus satuan',
              ),
            ]),
          ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(err == null ? Icons.account_tree_outlined : Icons.error_outline, size: 18, color: err == null ? null : Theme.of(context).colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(err ?? _hierarchyPreview,
                  style: TextStyle(fontWeight: FontWeight.w600, color: err == null ? null : Theme.of(context).colorScheme.error)),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _qtyWithUnit(TextEditingController ctrl, String unit, List<String> unitNames, ValueChanged<String> onUnit, String label) {
    return Row(children: [
      Expanded(child: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: label), onChanged: (_) => setState(() {}))),
      const SizedBox(width: 8),
      SizedBox(
        width: 120,
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label-${unitNames.join()}'),
          initialValue: unitNames.contains(unit) ? unit : null,
          items: [for (final n in unitNames) DropdownMenuItem(value: n, child: Text(n))],
          onChanged: (v) => setState(() => onUnit(v!)),
        ),
      ),
    ]);
  }

  Widget _stockCard(List<String> unitNames) {
    final base = _baseUnit?['name'] ?? 'satuan';
    return SectionCard(
      title: 'Stok & Smart Restock',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _qtyWithUnit(reorderQty, reorderUnit, unitNames, (v) => reorderUnit = v, 'Batas minimum (reorder point)'),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text('= ${number(_toBase(reorderQty, reorderUnit))} $base. Alert muncul saat stok ≤ batas ini.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        Row(children: [
          Expanded(
            child: TextField(controller: leadTime, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Lead time pemasok', suffixText: 'hari')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: costPrice,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'HPP per $base', prefixText: 'Rp ', helperText: 'Untuk valuasi aset'),
            ),
          ),
        ]),
        if (!editing) ...[
          const SizedBox(height: 12),
          _qtyWithUnit(initialQty, initialUnit, unitNames, (v) => initialUnit = v, 'Stok awal (opsional)'),
        ],
      ]),
    );
  }

  Widget _tiersCard() {
    final base = _baseUnit?['name'] ?? 'satuan';
    return SectionCard(
      title: 'Harga bertingkat B2B (tiering)',
      subtitle: 'Harga per $base untuk mitra, berdasarkan total kuantitas per PO. Makin banyak, makin murah.',
      trailing: TextButton.icon(onPressed: tiers.length >= 10 ? null : () => setState(() => tiers.add(_TierRow(minQty: 0))), icon: const Icon(Icons.add), label: const Text('Tier')),
      child: Column(children: [
        if (tiers.isEmpty) const Text('Tanpa tier: mitra membayar harga eceran.'),
        for (final t in tiers)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: t.minQty,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Mulai dari', suffixText: base, helperText: _unitJson.isEmpty ? null : '≈ ${formatQtyClient(int.tryParse(t.minQty.text) ?? 0, _unitJson)}'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: t.unitPrice, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Harga / $base', prefixText: 'Rp '))),
              IconButton(onPressed: () => setState(() => tiers.remove(t)), icon: const Icon(Icons.remove_circle_outline)),
            ]),
          ),
      ]),
    );
  }

  Widget _historyCard() {
    final movements = product!['movements'] as List;
    return SectionCard(
      title: 'Mutasi terakhir',
      trailing: TextButton(onPressed: () => context.go('/admin/movements?productId=${widget.productId}'), child: const Text('Semua')),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(children: [
        if (movements.isEmpty) const EmptyState(icon: Icons.history, message: 'Belum ada mutasi'),
        for (final m in movements.take(8))
          ListTile(
            dense: true,
            leading: StatusChip(statusOf(movementType, m['type']), dense: true),
            title: Text('${(m['qty'] as int) > 0 ? '+' : ''}${m['qtyDisplay']} → saldo ${m['balanceDisplay']}'),
            subtitle: Text('${fmtDateTime(m['createdAt'])} · ${m['refCode'] ?? '-'} · ${m['user'] ?? ''}'),
          ),
      ]),
    );
  }
}
