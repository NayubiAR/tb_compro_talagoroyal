import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Pemesanan cetak mandiri: unggah → atur spesifikasi → biaya otomatis → bayar QRIS.
class PrintOrderPage extends StatefulWidget {
  const PrintOrderPage({super.key});

  @override
  State<PrintOrderPage> createState() => _PrintOrderPageState();
}

class _PrintOrderPageState extends State<PrintOrderPage> {
  Json? pricing;
  Json? job;
  bool uploading = false;
  double progress = 0;
  String paperSize = 'A4';
  String colorMode = 'BW';
  String orientation = 'PORTRAIT';
  String binding = 'NONE';
  bool duplex = false;
  int copies = 1;
  final pageRange = TextEditingController();
  final notes = TextEditingController();
  Json? quote;
  String? quoteError;
  bool checkingOut = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    context.api.get('/api/print/pricing').then((r) {
      if (mounted) setState(() => pricing = r['data'] as Json);
    }).catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Json get _config => {
        'paperSize': paperSize,
        'colorMode': colorMode,
        'orientation': orientation,
        'duplex': duplex,
        'copies': copies,
        'binding': binding,
        'pageRange': pageRange.text.trim(),
        'notes': notes.text.trim(),
      };

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf', 'doc', 'docx']);
    if (file == null || !mounted) return;
    final maxMb = (pricing?['maxUploadMb'] as num?) ?? 25;
    final size = file.lengthSync() ?? await file.length() ?? 0;
    if (!mounted) return;
    if (size > maxMb * 1024 * 1024) {
      showSnack(context, 'Ukuran berkas maksimal $maxMb MB', error: true);
      return;
    }
    setState(() {
      uploading = true;
      progress = 0;
    });
    final previous = job;
    final api = context.api;
    final res = await guard(context, () async {
      final bytes = await file.readAsBytes();
      return api.upload('/api/print/jobs', bytes: bytes, filename: file.name, onProgress: (p) {
        if (mounted) setState(() => progress = p);
      });
    });
    if (!mounted) return;
    setState(() => uploading = false);
    if (res == null) return;
    if (previous != null) context.api.post('/api/print/jobs/${previous['id']}/cancel').catchError((_) => <String, dynamic>{});
    setState(() {
      job = res['data'] as Json;
      pageRange.clear();
    });
    _requote();
  }

  void _requote() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (job == null) return;
      try {
        final res = await context.api.post('/api/print/jobs/${job!['id']}/quote', _config);
        if (mounted) {
          setState(() {
            quote = res['data'] as Json;
            quoteError = null;
          });
        }
      } on ApiException catch (e) {
        if (mounted) {
          setState(() {
            quote = null;
            quoteError = e.fullMessage;
          });
        }
      }
    });
  }

  Future<void> _checkout() async {
    setState(() => checkingOut = true);
    final res = await guard(context, () => context.api.post('/api/print/jobs/${job!['id']}/checkout', _config));
    if (!mounted) return;
    setState(() => checkingOut = false);
    if (res != null) context.go('/print/jobs/${res['data']['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final main = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _uploadCard(context),
      const SizedBox(height: 16),
      _configCard(context),
    ]);
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_summaryCard(context), const SizedBox(height: 16), _priceList(context)]);
    return PageBody(maxWidth: 1200, children: [
      PageHeader(
        title: 'Cetak Dokumen',
        subtitle: 'Unggah dari mana saja, bayar dengan QRIS, ambil di toko saat nomor antrean Anda dipanggil.',
        actions: [OutlinedButton.icon(onPressed: () => context.go('/print/jobs'), icon: const Icon(Icons.receipt_long_outlined), label: const Text('Pesanan saya'))],
      ),
      if (wide)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: main), const SizedBox(width: 16), SizedBox(width: 380, child: side)])
      else ...[main, const SizedBox(height: 16), side],
    ]);
  }

  Widget _uploadCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: '1. Unggah dokumen',
      subtitle: 'Format .pdf, .doc, .docx · maks ${pricing?['maxUploadMb'] ?? 25} MB. Untuk hasil paling akurat gunakan PDF.',
      child: job == null
          ? InkWell(
              onTap: uploading ? null : _pick,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 36),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant, width: 1.5),
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                ),
                child: Column(children: [
                  Icon(Icons.cloud_upload_outlined, size: 44, color: scheme.primary),
                  const SizedBox(height: 10),
                  Text(uploading ? 'Mengunggah & menghitung halaman… ${(progress * 100).round()}%' : 'Klik untuk memilih berkas',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (uploading) Padding(padding: const EdgeInsets.fromLTRB(40, 12, 40, 0), child: LinearProgressIndicator(value: progress)),
                ]),
              ),
            )
          : ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Icon(job!['mimeType'] == 'application/pdf' ? Icons.picture_as_pdf : Icons.description)),
              title: Text(job!['originalName']),
              subtitle: Text('${job!['pageCount']} halaman · ${fileSize(job!['fileSize'] as int)} · dihitung dari ${job!['pageCountNote']}'),
              trailing: TextButton(onPressed: uploading ? null : _pick, child: Text(uploading ? '${(progress * 100).round()}%' : 'Ganti berkas')),
            ),
    );
  }

  Widget _segmented<T>(String label, T value, Map<T, String> options, ValueChanged<T> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [for (final e in options.entries) ButtonSegment(value: e.key, label: Text(e.value))],
          selected: {value},
          onSelectionChanged: job == null
              ? null
              : (s) {
                  onChanged(s.first);
                  _requote();
                },
        ),
      ]),
    );
  }

  Widget _configCard(BuildContext context) {
    final enabled = job != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SectionCard(
        title: '2. Atur cetakan',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 24, children: [
            _segmented('Ukuran kertas', paperSize, const {'A4': 'A4', 'F4': 'F4 / Folio', 'A3': 'A3'}, (v) => paperSize = v),
            _segmented('Warna', colorMode, colorModeLabel, (v) => colorMode = v),
            _segmented('Orientasi', orientation, orientationLabel, (v) => orientation = v),
            _segmented('Jilid', binding, bindingLabel, (v) => binding = v),
          ]),
          Wrap(spacing: 24, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Jumlah rangkap', style: TextStyle(fontWeight: FontWeight.w600)),
              IconButton(onPressed: enabled && copies > 1 ? () { copies--; _requote(); } : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$copies', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              IconButton(onPressed: enabled && copies < 100 ? () { copies++; _requote(); } : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: duplex, onChanged: enabled ? (v) { duplex = v; _requote(); } : null),
              const Text('Bolak-balik (hemat kertas)'),
            ]),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: pageRange,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: 'Halaman yang dicetak',
              hintText: 'Contoh: 1-5, 8, 10-12',
              helperText: enabled ? 'Kosongkan untuk mencetak semua halaman (1–${job!['pageCount']})' : null,
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          TextField(controller: notes, enabled: enabled, maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan untuk operator (opsional)')),
        ]),
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final q = quote;
    return SectionCard(
      title: '3. Ringkasan biaya',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (job == null) const Text('Unggah dokumen untuk melihat biaya.'),
        if (quoteError != null) Text(quoteError!, style: TextStyle(color: toneColor(context, Tone.critical))),
        if (q != null) ...[
          TotalRow('${q['pagesToPrint']} hal × ${q['copies']} rangkap × ${rupiah(q['pricePerPage'])}', rupiah(q['printCost'])),
          if ((q['bindingCost'] as int) > 0) TotalRow('${bindingLabel[binding]} × ${q['copies']}', rupiah(q['bindingCost'])),
          const Divider(),
          TotalRow('Total bayar', rupiah(q['total']), emphasis: true),
          Text('≈ ${q['sheets']} lembar kertas', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: q == null || checkingOut ? null : _checkout,
          icon: const Icon(Icons.qr_code_2),
          label: Text(checkingOut ? 'Membuat QRIS…' : 'Bayar dengan QRIS'),
        ),
        const SizedBox(height: 8),
        Text('Pesanan masuk antrean setelah pembayaran terverifikasi. QRIS berlaku ${pricing?['paymentExpiryMinutes'] ?? 15} menit.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _priceList(BuildContext context) {
    final p = pricing;
    if (p == null) return const SizedBox.shrink();
    return SectionCard(
      title: 'Daftar harga',
      child: Column(children: [
        Table(children: [
          const TableRow(children: [Text(''), Text('Hitam-Putih', style: TextStyle(fontWeight: FontWeight.w600)), Text('Berwarna', style: TextStyle(fontWeight: FontWeight.w600))]),
          for (final size in ['A4', 'F4', 'A3'])
            TableRow(children: [
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(size)),
              Text(rupiah(p['pricePerPage'][size]['BW'])),
              Text(rupiah(p['pricePerPage'][size]['COLOR'])),
            ]),
        ]),
        const Divider(),
        TotalRow('Jilid lakban', rupiah(p['binding']['LAKBAN'])),
        TotalRow('Jilid spiral', rupiah(p['binding']['SPIRAL'])),
      ]),
    );
  }
}
