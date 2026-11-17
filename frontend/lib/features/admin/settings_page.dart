import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';

/// Pengaturan toko. Pemilik dapat mengubah; staf hanya melihat.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with LoaderMixin {
  Json settings = {};
  List levels = [];
  final _c = <String, TextEditingController>{};
  List<Map<String, TextEditingController>> banks = [];

  bool get canEdit => context.auth.isOwner;

  TextEditingController c(String key, [Object? init]) => _c.putIfAbsent(key, () => TextEditingController(text: init?.toString() ?? ''));

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([context.api.get('/api/settings'), context.api.get('/api/partners/levels')]);
    settings = results[0]['data'] as Json;
    levels = results[1]['data'] as List;
    _c.clear();
    final store = settings['store_profile'] as Json;
    for (final k in ['name', 'tagline', 'address', 'phone', 'email', 'npwp', 'openingHours']) {
      c('store.$k', store[k]);
    }
    banks = [
      for (final b in store['bankAccounts'] as List)
        {for (final k in ['bank', 'number', 'holder']) k: TextEditingController(text: b[k])},
    ];
    final pricing = settings['print_pricing'] as Json;
    for (final size in ['A4', 'F4', 'A3']) {
      for (final mode in ['BW', 'COLOR']) {
        c('price.$size.$mode', pricing['pricePerPage'][size][mode]);
      }
    }
    c('binding.LAKBAN', pricing['binding']['LAKBAN']);
    c('binding.SPIRAL', pricing['binding']['SPIRAL']);
    final b2b = settings['b2b'] as Json;
    c('b2b.taxPercent', b2b['taxPercent']);
    c('b2b.invoiceNotes', b2b['invoiceNotes']);
  }

  int _int(String key) => int.tryParse(c(key).text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  Future<void> _save(String key, Json body) async {
    final res = await guard(context, () => context.api.put('/api/settings/$key', body), success: 'Pengaturan disimpan');
    if (res != null) reload(silent: true);
  }

  Widget _field(String key, String label, {String? prefix, String? suffix, int maxLines = 1, double width = 320, bool number = false}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c(key),
        enabled: canEdit,
        maxLines: maxLines,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label, prefixText: prefix, suffixText: suffix),
      ),
    );
  }

  Widget _saveButton(VoidCallback onPressed) => Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(onPressed: canEdit ? onPressed : null, icon: const Icon(Icons.save_outlined), label: const Text('Simpan')),
      );

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(maxWidth: 1000, children: [
          PageHeader(
            title: 'Pengaturan',
            subtitle: canEdit ? 'Perubahan tercatat di jejak audit.' : 'Hanya Pemilik Toko yang dapat mengubah pengaturan.',
          ),
          SectionCard(
            title: 'Profil toko',
            subtitle: 'Tampil di kop faktur/PO PDF, halaman login & layar antrean.',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 12, runSpacing: 12, children: [
                _field('store.name', 'Nama toko'),
                _field('store.tagline', 'Tagline', width: 420),
                _field('store.address', 'Alamat', width: 752, maxLines: 2),
                _field('store.phone', 'Telepon', width: 240),
                _field('store.email', 'Email', width: 240),
                _field('store.npwp', 'NPWP', width: 240),
                _field('store.openingHours', 'Jam buka', width: 320),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                const Text('Rekening pembayaran faktur', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: canEdit && banks.length < 5
                      ? () => setState(() => banks.add({for (final k in ['bank', 'number', 'holder']) k: TextEditingController()}))
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Rekening'),
                ),
              ]),
              for (final b in banks)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    SizedBox(width: 120, child: TextField(controller: b['bank'], enabled: canEdit, decoration: const InputDecoration(labelText: 'Bank'))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: b['number'], enabled: canEdit, decoration: const InputDecoration(labelText: 'No. rekening'))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: b['holder'], enabled: canEdit, decoration: const InputDecoration(labelText: 'Atas nama'))),
                    IconButton(onPressed: canEdit ? () => setState(() => banks.remove(b)) : null, icon: const Icon(Icons.remove_circle_outline)),
                  ]),
                ),
              const SizedBox(height: 16),
              _saveButton(() => _save('store_profile', {
                    for (final k in ['name', 'tagline', 'address', 'phone', 'email', 'npwp', 'openingHours']) k: c('store.$k').text.trim(),
                    'bankAccounts': [
                      for (final b in banks)
                        if (b['bank']!.text.trim().isNotEmpty) {for (final e in b.entries) e.key: e.value.text.trim()},
                    ],
                  })),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Tarif cloud printing',
            subtitle: 'Harga per halaman cetak (per sisi) dan biaya jilid per rangkap.',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Table(
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                columnWidths: const {0: FixedColumnWidth(80)},
                children: [
                  const TableRow(children: [SizedBox(), Padding(padding: EdgeInsets.all(8), child: Text('Hitam-Putih')), Padding(padding: EdgeInsets.all(8), child: Text('Berwarna'))]),
                  for (final size in ['A4', 'F4', 'A3'])
                    TableRow(children: [
                      Text(size, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Padding(padding: const EdgeInsets.all(6), child: _field('price.$size.BW', 'per halaman', prefix: 'Rp ', number: true)),
                      Padding(padding: const EdgeInsets.all(6), child: _field('price.$size.COLOR', 'per halaman', prefix: 'Rp ', number: true)),
                    ]),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 12, children: [
                _field('binding.LAKBAN', 'Jilid lakban', prefix: 'Rp ', width: 200, number: true),
                _field('binding.SPIRAL', 'Jilid spiral', prefix: 'Rp ', width: 200, number: true),
              ]),
              const SizedBox(height: 16),
              _saveButton(() => _save('print_pricing', {
                    'pricePerPage': {
                      for (final size in ['A4', 'F4', 'A3']) size: {'BW': _int('price.$size.BW'), 'COLOR': _int('price.$size.COLOR')},
                    },
                    'binding': {'LAKBAN': _int('binding.LAKBAN'), 'SPIRAL': _int('binding.SPIRAL')},
                  })),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Faktur B2B',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 12, runSpacing: 12, children: [
                _field('b2b.taxPercent', 'PPN', suffix: '%', width: 140, number: true),
                _field('b2b.invoiceNotes', 'Catatan di faktur', width: 600, maxLines: 2),
              ]),
              const SizedBox(height: 4),
              Text('Isi 0 jika toko belum PKP. Berlaku untuk PO baru.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              _saveButton(() => _save('b2b', {
                    'taxPercent': double.tryParse(c('b2b.taxPercent').text.replaceAll(',', '.')) ?? 0,
                    'invoiceNotes': c('b2b.invoiceNotes').text.trim(),
                  })),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Level mitra B2B',
            subtitle: 'Diskon tambahan di atas harga tiering, diberikan saat verifikasi mitra.',
            trailing: TextButton.icon(onPressed: canEdit ? () => _levelDialog(null) : null, icon: const Icon(Icons.add), label: const Text('Level')),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              for (final l in levels)
                ListTile(
                  title: Text('${l['name']} · diskon ${l['discountPercent']}%'),
                  subtitle: Text('${l['description'] ?? ''} · ${l['partnerCount']} mitra'),
                  trailing: IconButton(onPressed: canEdit ? () => _levelDialog(l as Json) : null, icon: const Icon(Icons.edit_outlined)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('Contoh: tarif A4 hitam-putih saat ini ${rupiah(_int('price.A4.BW'))}/halaman.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]));
  }

  Future<void> _levelDialog(Json? level) async {
    final name = TextEditingController(text: level?['name'] ?? '');
    final disc = TextEditingController(text: '${level?['discountPercent'] ?? 0}');
    final desc = TextEditingController(text: level?['description'] ?? '');
    final body = await showDialog<Json>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(level == null ? 'Tambah level' : 'Ubah level ${level['name']}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama level')),
            const SizedBox(height: 12),
            TextField(controller: disc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Diskon', suffixText: '%')),
            const SizedBox(height: 12),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'Kriteria / keterangan')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              'name': name.text.trim(),
              'discountPercent': double.tryParse(disc.text.replaceAll(',', '.')) ?? 0,
              'description': desc.text.trim(),
            }),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (body == null || !mounted) return;
    final res = await guard(
      context,
      () => level == null ? context.api.post('/api/partners/levels', body) : context.api.patch('/api/partners/levels/${level['id']}', body),
      success: 'Level disimpan',
    );
    if (res != null) reload(silent: true);
  }
}
