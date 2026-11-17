import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../state/po_draft.dart';
import '../../widgets/common.dart';

class _Row {
  _Row(this.line)
      : sku = TextEditingController(text: line.sku),
        qty = TextEditingController(text: line.qty > 0 ? '${line.qty}' : '');
  final PoDraftLine line;
  final TextEditingController sku;
  final TextEditingController qty;
  final skuFocus = FocusNode();
  final qtyFocus = FocusNode();

  bool get filled => line.sku.trim().isNotEmpty;

  void dispose() {
    sku.dispose();
    qty.dispose();
    skuFocus.dispose();
    qtyFocus.dispose();
  }
}

/// Quick PO: input massal bergaya spreadsheet (ketik SKU + qty, atau tempel dari Excel).
/// Harga tiering, diskon level, PPN & validasi stok dihitung langsung oleh server.
class QuickPoPage extends StatefulWidget {
  const QuickPoPage({super.key});

  @override
  State<QuickPoPage> createState() => _QuickPoPageState();
}

class _QuickPoPageState extends State<QuickPoPage> {
  late final PoDraft draft = context.read<PoDraft>();
  final rows = <_Row>[];
  final partnerRef = TextEditingController();
  final note = TextEditingController();
  Json? summary;
  final quoted = <_Row, Json>{};
  bool quoting = false;
  bool submitting = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    for (final l in draft.lines) {
      rows.add(_Row(l));
    }
    _ensureEmptyRows();
    _quote();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final r in rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _ensureEmptyRows() {
    while (rows.where((r) => !r.filled).length < 3) {
      final line = PoDraftLine(qty: 0);
      draft.lines.add(line);
      rows.add(_Row(line));
    }
  }

  void _changed() {
    draft.changed();
    _ensureEmptyRows();
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _quote);
  }

  Future<void> _quote() async {
    final active = rows.where((r) => r.filled && r.line.qty > 0).toList();
    if (active.isEmpty) {
      setState(() {
        summary = null;
        quoted.clear();
      });
      return;
    }
    setState(() => quoting = true);
    try {
      final res = await context.api.post('/api/b2b/quote', {'items': [for (final r in active) r.line.toJson()]});
      final data = res['data'] as Json;
      final lines = data['lines'] as List;
      if (!mounted) return;
      setState(() {
        quoted.clear();
        for (var i = 0; i < active.length; i++) {
          quoted[active[i]] = lines[i] as Json;
        }
        summary = data['summary'] as Json;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => quoting = false);
  }

  void _remove(_Row r) {
    draft.lines.remove(r.line);
    rows.remove(r);
    quoted.remove(r);
    r.dispose();
    _changed();
  }

  void _clear() {
    for (final r in rows) {
      r.dispose();
    }
    rows.clear();
    quoted.clear();
    draft.clear();
    _changed();
  }

  /// Tempel dari Excel/Sheets: tiap baris `SKU⇥Qty⇥Satuan` (satuan opsional).
  Future<void> _paste() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tempel dari Excel / Google Sheets'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Salin kolom SKU, Qty, dan (opsional) Satuan dari spreadsheet, lalu tempel di sini. Pemisah tab, titik koma, atau koma.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 10,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'ATL-0001\t2\tDus\nKRT-0001\t10\tRim\nBKU-0001\t5\tPak'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Tambahkan')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    var added = 0;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final cols = raw.split(RegExp(r'\t|;|,')).map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
      if (cols.length < 2) continue;
      final qty = int.tryParse(cols[1].replaceAll('.', ''));
      if (qty == null || qty < 1) continue; // lewati baris judul
      final empty = rows.where((r) => !r.filled).firstOrNull;
      final line = empty?.line ?? PoDraftLine();
      line
        ..sku = cols[0]
        ..qty = qty
        ..unitName = cols.length > 2 ? cols[2] : null;
      if (empty != null) {
        empty.sku.text = line.sku;
        empty.qty.text = '$qty';
      } else {
        draft.lines.add(line);
        rows.add(_Row(line));
      }
      added++;
    }
    if (mounted) showSnack(context, '$added baris ditambahkan');
    _changed();
  }

  Future<void> _submit() async {
    final active = rows.where((r) => r.filled && r.line.qty > 0).toList();
    final ok = await confirmDialog(
      context,
      title: 'Kirim PO?',
      message: '${active.length} item senilai ${rupiah(summary!['total'])} akan diajukan untuk diverifikasi toko. Harga terkunci sesuai perhitungan saat ini.',
      confirmLabel: 'Kirim PO',
    );
    if (!ok || !mounted) return;
    setState(() => submitting = true);
    final res = await guard(
      context,
      () => context.api.post('/api/b2b/orders', {
        'items': [for (final r in active) r.line.toJson()],
        'partnerRef': partnerRef.text,
        'note': note.text,
      }),
    );
    if (!mounted) return;
    setState(() => submitting = false);
    if (res == null) return;
    final order = res['data'] as Json;
    draft.clear();
    showSnack(context, 'PO ${order['poNumber']} terkirim. Anda akan diberi tahu setelah diverifikasi.');
    context.go('/b2b/orders?id=${order['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final canSubmit = s != null && s['hasErrors'] != true && s['hasStockIssues'] != true && (s['itemCount'] as int) > 0 && !submitting;
    final wide = MediaQuery.sizeOf(context).width >= 1200;
    final sheet = _sheet(context);
    final side = _summaryCard(context, s, canSubmit);
    return PageBody(maxWidth: 1500, children: [
      PageHeader(
        title: 'Quick PO',
        subtitle: 'Ketik SKU & jumlah seperti di spreadsheet (Enter untuk pindah baris), atau tempel langsung dari Excel.',
        actions: [
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Tempel dari Excel')),
          OutlinedButton.icon(onPressed: () => context.go('/b2b/catalog'), icon: const Icon(Icons.storefront_outlined), label: const Text('Cari di katalog')),
          TextButton(onPressed: _clear, child: const Text('Kosongkan')),
        ],
      ),
      if (wide)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: sheet), const SizedBox(width: 16), SizedBox(width: 380, child: side)])
      else ...[sheet, const SizedBox(height: 16), side],
    ]);
  }

  Widget _sheet(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Card(
      child: Column(children: [
        if (quoting) const LinearProgressIndicator(minHeight: 2),
        ScrollTable(
          minWidth: 1000,
          columns: const [
            DataColumn(label: Text('#')),
            DataColumn(label: Text('SKU')),
            DataColumn(label: Text('Barang')),
            DataColumn(label: Text('Qty')),
            DataColumn(label: Text('Satuan')),
            DataColumn(label: Text('Harga satuan'), numeric: true),
            DataColumn(label: Text('Subtotal'), numeric: true),
            DataColumn(label: Text('')),
          ],
          rows: [
            for (final (i, r) in rows.indexed)
              DataRow(cells: [
                DataCell(Text('${i + 1}', style: muted)),
                DataCell(SizedBox(
                  width: 120,
                  child: TextField(
                    controller: r.sku,
                    focusNode: r.skuFocus,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(hintText: 'SKU', border: InputBorder.none),
                    onChanged: (v) {
                      r.line.sku = v.trim().toUpperCase();
                      _changed();
                    },
                    onSubmitted: (_) => r.qtyFocus.requestFocus(),
                  ),
                )),
                DataCell(_lineInfo(context, r)),
                DataCell(SizedBox(
                  width: 70,
                  child: TextField(
                    controller: r.qty,
                    focusNode: r.qtyFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: '0', border: InputBorder.none),
                    onChanged: (v) {
                      r.line.qty = int.tryParse(v) ?? 0;
                      _changed();
                    },
                    onSubmitted: (_) {
                      final next = rows.indexOf(r) + 1;
                      if (next < rows.length) rows[next].skuFocus.requestFocus();
                    },
                  ),
                )),
                DataCell(_unitPicker(r)),
                DataCell(Text(quoted[r]?['unitPrice'] == null ? '' : rupiah(quoted[r]!['unitPrice']))),
                DataCell(Text(quoted[r]?['subtotal'] == null || quoted[r]!['subtotal'] == 0 ? '' : rupiah(quoted[r]!['subtotal']),
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                DataCell(r.filled ? IconButton(onPressed: () => _remove(r), icon: const Icon(Icons.close, size: 18), tooltip: 'Hapus baris') : const SizedBox()),
              ]),
          ],
        ),
      ]),
    );
  }

  Widget _unitPicker(_Row r) {
    final q = quoted[r];
    final units = (q?['units'] as List?) ?? [];
    if (units.isEmpty) return Text(r.line.unitName ?? '-');
    final value = q?['unitName'] as String? ?? r.line.unitName;
    return DropdownButton<String>(
      value: units.any((u) => u['name'] == value) ? value : null,
      hint: const Text('Satuan'),
      underline: const SizedBox(),
      items: [for (final u in units) DropdownMenuItem(value: u['name'] as String, child: Text('${u['name']}'))],
      onChanged: (v) {
        r.line.unitName = v;
        _changed();
      },
    );
  }

  Widget _lineInfo(BuildContext context, _Row r) {
    final q = quoted[r];
    if (q == null) return const SizedBox(width: 280);
    final errors = (q['errors'] as List).cast<String>();
    final warnings = (q['warnings'] as List).cast<String>();
    final next = q['nextTier'] as Json?;
    final small = const TextStyle(fontSize: 11.5);
    return SizedBox(
      width: 280,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (q['productName'] != null) Text(q['productName'], overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        for (final e in errors) Text(e, style: small.copyWith(color: toneColor(context, Tone.critical))),
        for (final w in warnings) Text(w, style: small.copyWith(color: toneColor(context, Tone.serious))),
        if (errors.isEmpty && warnings.isEmpty && next != null)
          Text('Tambah ${next['neededDisplay']} → ${rupiah(next['unitPrice'])}/${next['baseUnit']}', style: small.copyWith(color: toneColor(context, Tone.good))),
      ]),
    );
  }

  Widget _summaryCard(BuildContext context, Json? s, bool canSubmit) {
    return SectionCard(
      title: 'Ringkasan PO',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s == null)
          const Text('Isi minimal satu baris untuk melihat harga.')
        else ...[
          TotalRow('${s['itemCount']} item · subtotal harga tier', rupiah(s['subtotal'])),
          if ((s['discount'] as int) > 0) TotalRow('Diskon level ${s['levelName']} (${s['discountPercent']}%)', '- ${rupiah(s['discount'])}'),
          if ((s['tax'] as int) > 0) TotalRow('PPN (${s['taxPercent']}%)', rupiah(s['tax'])),
          const Divider(),
          TotalRow('Total', rupiah(s['total']), emphasis: true),
          if ((s['savings'] as int) > 0) TotalRow('Hemat dibanding eceran', rupiah(s['savings']), color: toneColor(context, Tone.good)),
          if (s['hasErrors'] == true)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Perbaiki baris bertanda merah sebelum mengirim.', style: TextStyle(color: toneColor(context, Tone.critical)))),
          if (s['hasStockIssues'] == true)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sebagian jumlah melebihi stok tersedia.', style: TextStyle(color: toneColor(context, Tone.serious)))),
        ],
        const SizedBox(height: 16),
        TextField(controller: partnerRef, decoration: const InputDecoration(labelText: 'No. PO / SPK internal instansi (opsional)')),
        const SizedBox(height: 12),
        TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Catatan untuk toko')),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: canSubmit ? _submit : null,
          icon: const Icon(Icons.send),
          label: Text(submitting ? 'Mengirim…' : 'Kirim PO'),
        ),
        const SizedBox(height: 8),
        Text('Faktur PDF terbit otomatis setelah PO diverifikasi. Barang diambil di toko.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
