import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';

/// Verifikasi pendaftaran mitra B2B & pengaturan level harga, termin (TOP), dan limit kredit.
class PartnersPage extends StatefulWidget {
  const PartnersPage({super.key});

  @override
  State<PartnersPage> createState() => _PartnersPageState();
}

class _PartnersPageState extends State<PartnersPage> with LoaderMixin {
  List rows = [];
  Json? meta;
  List levels = [];
  String? status;
  String q = '';
  int page = 1;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([
      context.api.get('/api/partners', query: {'status': status, 'q': q, 'page': page}),
      context.api.get('/api/partners/levels'),
    ]);
    rows = results[0]['data'] as List;
    meta = results[0]['meta'] as Json;
    levels = results[1]['data'] as List;
  }

  Future<void> _terms(Json p, {required bool verify}) async {
    final body = await showDialog<Json>(context: context, builder: (_) => _TermsDialog(partner: p, levels: levels, verify: verify));
    if (body == null || !mounted) return;
    final res = await guard(
      context,
      () => verify ? context.api.post('/api/partners/${p['id']}/verify', body) : context.api.patch('/api/partners/${p['id']}', body),
      success: verify ? '${p['institutionName']} terverifikasi' : 'Syarat mitra diperbarui',
    );
    if (res != null) reload(silent: true);
  }

  Future<void> _reject(Json p) async {
    final reason = await promptText(context, title: 'Tolak ${p['institutionName']}', label: 'Alasan (dikirim ke mitra)', minLength: 3, confirmLabel: 'Tolak');
    if (reason == null || !mounted) return;
    final res = await guard(context, () => context.api.post('/api/partners/${p['id']}/reject', {'reason': reason}), success: 'Pendaftaran ditolak');
    if (res != null) reload(silent: true);
  }

  Future<void> _setStatus(Json p, String s) async {
    final ok = await confirmDialog(
      context,
      title: s == 'SUSPENDED' ? 'Tangguhkan mitra?' : 'Aktifkan kembali mitra?',
      message: s == 'SUSPENDED' ? 'Mitra tidak dapat membuat PO baru selama ditangguhkan.' : 'Mitra dapat kembali mengakses katalog & membuat PO.',
    );
    if (!ok || !mounted) return;
    final res = await guard(context, () => context.api.patch('/api/partners/${p['id']}', {'status': s}));
    if (res != null) reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final counts = (meta?['counts'] as Json?) ?? {};
      return PageBody(children: [
        const PageHeader(title: 'Mitra B2B', subtitle: 'Hanya mitra terverifikasi yang dapat melihat harga tiering & membuat PO.'),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(label: const Text('Semua'), selected: status == null, onSelected: (_) => _filter(null)),
          for (final e in partnerStatus.entries)
            ChoiceChip(label: Text('${e.value.label} (${counts[e.key] ?? 0})'), selected: status == e.key, onSelected: (_) => _filter(e.key)),
          SearchBox(hint: 'Institusi / PIC / email', onChanged: (v) {
            q = v;
            page = 1;
            reload();
          }),
        ]),
        const SizedBox(height: 12),
        Card(
          child: rows.isEmpty
              ? const EmptyState(icon: Icons.handshake_outlined, message: 'Tidak ada mitra')
              : ScrollTable(
                  minWidth: 1150,
                  columns: const [
                    DataColumn(label: Text('Institusi')),
                    DataColumn(label: Text('PIC')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Level')),
                    DataColumn(label: Text('Termin')),
                    DataColumn(label: Text('Limit kredit'), numeric: true),
                    DataColumn(label: Text('Piutang'), numeric: true),
                    DataColumn(label: Text('Aksi')),
                  ],
                  rows: [
                    for (final p in rows)
                      DataRow(cells: [
                        DataCell(SizedBox(
                          width: 220,
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p['institutionName'], style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                            Text('${institutionTypeLabel[p['institutionType']]} · daftar ${fmtDate(p['createdAt'])}', style: const TextStyle(fontSize: 12)),
                          ]),
                        )),
                        DataCell(Text('${p['user']?['name']}\n${p['user']?['email']} · ${p['user']?['phone'] ?? '-'}', style: const TextStyle(fontSize: 12.5))),
                        DataCell(StatusChip(statusOf(partnerStatus, p['status']), dense: true)),
                        DataCell(Text(p['level'] == null ? '-' : '${p['level']} (${p['discountPercent']}%)')),
                        DataCell(Text('${p['paymentTermDays']} hari')),
                        DataCell(Text((p['creditLimit'] as int) == 0 ? 'Tanpa batas' : rupiah(p['creditLimit']))),
                        DataCell(Text(rupiah(p['outstanding']))),
                        DataCell(Wrap(spacing: 4, children: [
                          if (p['status'] == 'PENDING') ...[
                            FilledButton.tonal(onPressed: () => _terms(p, verify: true), child: const Text('Verifikasi')),
                            TextButton(onPressed: () => _reject(p), child: const Text('Tolak')),
                          ],
                          if (p['status'] == 'VERIFIED') ...[
                            TextButton(onPressed: () => _terms(p, verify: false), child: const Text('Ubah syarat')),
                            TextButton(onPressed: () => _setStatus(p, 'SUSPENDED'), child: const Text('Tangguhkan')),
                          ],
                          if (p['status'] == 'SUSPENDED') TextButton(onPressed: () => _setStatus(p, 'VERIFIED'), child: const Text('Aktifkan')),
                          if (p['status'] == 'REJECTED') Text(p['rejectionReason'] ?? '', style: const TextStyle(fontSize: 12)),
                        ])),
                      ]),
                  ],
                ),
        ),
        Paginator(meta: meta, onPage: (p) {
          page = p;
          reload();
        }),
      ]);
    });
  }

  void _filter(String? s) {
    status = s;
    page = 1;
    reload();
  }
}

class _TermsDialog extends StatefulWidget {
  const _TermsDialog({required this.partner, required this.levels, required this.verify});
  final Json partner;
  final List levels;
  final bool verify;

  @override
  State<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends State<_TermsDialog> {
  late int? levelId = widget.partner['levelId'] as int? ?? (widget.levels.isEmpty ? null : widget.levels.first['id'] as int);
  late final term = TextEditingController(text: '${widget.partner['paymentTermDays']}');
  late final limit = TextEditingController(text: '${widget.partner['creditLimit']}');

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;
    return AlertDialog(
      title: Text(widget.verify ? 'Verifikasi ${p['institutionName']}' : 'Syarat ${p['institutionName']}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.verify) ...[
            InfoRow('Jenis', institutionTypeLabel[p['institutionType']] ?? '-'),
            InfoRow('Alamat', p['address'] ?? '-'),
            InfoRow('NPWP', p['npwp'] ?? '-'),
            InfoRow('PIC', '${p['user']?['name']} · ${p['user']?['phone'] ?? '-'}'),
            const Divider(height: 24),
          ],
          DropdownButtonFormField<int?>(
            initialValue: levelId,
            decoration: const InputDecoration(labelText: 'Level harga'),
            items: [
              for (final l in widget.levels)
                DropdownMenuItem(value: l['id'] as int, child: Text('${l['name']} · diskon ${l['discountPercent']}%')),
            ],
            onChanged: (v) => setState(() => levelId = v),
          ),
          const SizedBox(height: 12),
          TextField(controller: term, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Termin pembayaran (TOP)', suffixText: 'hari')),
          const SizedBox(height: 12),
          TextField(
            controller: limit,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Limit kredit (piutang maksimum)', prefixText: 'Rp ', helperText: '0 = tanpa batas'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'levelId': levelId,
            'paymentTermDays': int.tryParse(term.text) ?? 30,
            'creditLimit': int.tryParse(limit.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
          }),
          child: Text(widget.verify ? 'Verifikasi' : 'Simpan'),
        ),
      ],
    );
  }
}
