import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/revenue_chart.dart';
import '../b2b/order_detail.dart';

/// Faktur B2B & pelacakan piutang (Lunas / Jatuh Tempo) + aging report.
class AdminInvoicesPage extends StatefulWidget {
  const AdminInvoicesPage({super.key});

  @override
  State<AdminInvoicesPage> createState() => _AdminInvoicesPageState();
}

class _AdminInvoicesPageState extends State<AdminInvoicesPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  Json ar = {};
  String? status = 'OPEN';
  String q = '';
  int page = 1;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['invoice.updated', 'order.updated'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([
      context.api.get('/api/admin/b2b/invoices', query: {'status': status, 'q': q, 'page': page}),
      context.api.get('/api/admin/b2b/receivables'),
    ]);
    rows = results[0]['data'] as List;
    meta = results[0]['meta'] as Json;
    ar = results[1]['data'] as Json;
  }

  Future<void> _pay(Json inv) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _PaymentDialog(invoice: inv));
    if (ok == true) reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final aging = ar['aging'] as Json;
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      final agingCard = SectionCard(
        title: 'Umur piutang (aging)',
        child: BarList(items: [
          ('Belum jatuh tempo', aging['current'] as int),
          ('Terlambat 1–30 hari', aging['d1_30'] as int),
          ('Terlambat 31–60 hari', aging['d31_60'] as int),
          ('Terlambat 61–90 hari', aging['d61_90'] as int),
          ('Terlambat > 90 hari', aging['d90plus'] as int),
        ]),
      );
      final partnersCard = SectionCard(
        title: 'Piutang per mitra',
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          if ((ar['partners'] as List).isEmpty) const EmptyState(icon: Icons.check_circle_outline, message: 'Tidak ada piutang'),
          for (final p in (ar['partners'] as List).take(6))
            ListTile(
              dense: true,
              title: Text(p['institutionName']),
              subtitle: Text('${p['invoiceCount']} faktur · tertua jatuh tempo ${fmtDate(p['oldestDueDate'])}'),
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(rupiah(p['outstanding']), style: const TextStyle(fontWeight: FontWeight.w700)),
                if ((p['overdue'] as int) > 0)
                  Text('jatuh tempo ${rupiah(p['overdue'])}', style: TextStyle(fontSize: 12, color: toneColor(context, Tone.critical))),
              ]),
            ),
        ]),
      );
      return PageBody(children: [
        const PageHeader(title: 'Faktur & Piutang', subtitle: 'Catat pembayaran transfer/tunai dari mitra; status jatuh tempo dihitung otomatis.'),
        ResponsiveGrid(minItemWidth: 240, children: [
          StatCard(label: 'Total piutang', value: rupiah(ar['outstanding']), icon: Icons.account_balance_wallet_outlined, caption: '${ar['invoiceCount']} faktur belum lunas'),
          StatCard(label: 'Jatuh tempo', value: rupiah(ar['overdue']), icon: Icons.error_outline, tone: (ar['overdue'] as int) > 0 ? Tone.critical : Tone.good),
        ]),
        const SizedBox(height: 16),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: agingCard), const SizedBox(width: 16), Expanded(child: partnersCard)])
        else ...[agingCard, const SizedBox(height: 16), partnersCard],
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final (v, l) in [('OPEN', 'Belum lunas'), ('OVERDUE', 'Jatuh tempo'), ('PAID', 'Lunas'), ('VOID', 'Dibatalkan'), (null, 'Semua')])
            ChoiceChip(label: Text(l), selected: status == v, onSelected: (_) {
              status = v;
              page = 1;
              reload();
            }),
          const SizedBox(width: 8),
          SearchBox(hint: 'No. faktur / PO / instansi', onChanged: (v) {
            q = v;
            page = 1;
            reload();
          }),
        ]),
        const SizedBox(height: 12),
        Card(
          child: rows.isEmpty
              ? const EmptyState(icon: Icons.request_quote_outlined, message: 'Tidak ada faktur')
              : ScrollTable(
                  minWidth: 1100,
                  columns: const [
                    DataColumn(label: Text('No. Faktur')),
                    DataColumn(label: Text('Mitra')),
                    DataColumn(label: Text('Jatuh tempo')),
                    DataColumn(label: Text('Total'), numeric: true),
                    DataColumn(label: Text('Dibayar'), numeric: true),
                    DataColumn(label: Text('Sisa'), numeric: true),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final i in rows)
                      DataRow(cells: [
                        DataCell(Text('${i['invoiceNumber']}\n${i['poNumber']} · ${fmtDate(i['issueDate'])}', style: const TextStyle(fontSize: 13))),
                        DataCell(Text(i['partner']?['institutionName'] ?? '-')),
                        DataCell(Text('${fmtDate(i['dueDate'])}${dueHint(i as Json)}', style: TextStyle(color: i['displayStatus'] == 'OVERDUE' ? toneColor(context, Tone.critical) : null))),
                        DataCell(Text(rupiah(i['total']))),
                        DataCell(Text(rupiah(i['amountPaid']))),
                        DataCell(Text(rupiah(i['remaining']), style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataCell(StatusChip(statusOf(invoiceStatus, i['displayStatus']), dense: true)),
                        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                          if (i['status'] == 'UNPAID' || i['status'] == 'PARTIAL')
                            IconButton.filledTonal(tooltip: 'Catat pembayaran', onPressed: () => _pay(i), icon: const Icon(Icons.payments_outlined)),
                          IconButton(
                            tooltip: 'PDF faktur',
                            onPressed: () => guard(context, () => context.api.openDownload('/api/admin/b2b/invoices/${i['id']}/pdf')),
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                          ),
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
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.invoice});
  final Json invoice;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late final amount = TextEditingController(text: '${widget.invoice['remaining']}');
  final reference = TextEditingController();
  final note = TextEditingController();
  String method = 'TRANSFER';
  DateTime paidAt = DateTime.now();
  bool busy = false;

  Future<void> _submit() async {
    final value = int.tryParse(amount.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (value <= 0) {
      showSnack(context, 'Nominal tidak valid', error: true);
      return;
    }
    setState(() => busy = true);
    final res = await guard(
      context,
      () => context.api.post('/api/admin/b2b/invoices/${widget.invoice['id']}/payments', {
        'amount': value,
        'method': method,
        'reference': reference.text,
        'note': note.text,
        'paidAt': ymd(paidAt),
      }),
      success: 'Pembayaran dicatat & mitra diberi tahu',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (res != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Catat pembayaran ${widget.invoice['invoiceNumber']}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InfoRow('Sisa tagihan', rupiah(widget.invoice['remaining']), bold: true),
          const SizedBox(height: 12),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Nominal dibayar', prefixText: 'Rp ')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: method,
            decoration: const InputDecoration(labelText: 'Metode'),
            items: [for (final e in paymentMethodLabel.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => method = v!),
          ),
          const SizedBox(height: 12),
          TextField(controller: reference, decoration: const InputDecoration(labelText: 'No. referensi / bukti transfer')),
          const SizedBox(height: 12),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Catatan')),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text('Tanggal bayar: ${fmtDate(paidAt)}'),
            trailing: TextButton(
              onPressed: () async {
                final d = await showDatePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now(), initialDate: paidAt);
                if (d != null) setState(() => paidAt = d);
              },
              child: const Text('Ubah'),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: busy ? null : _submit, child: const Text('Simpan pembayaran')),
      ],
    );
  }
}
