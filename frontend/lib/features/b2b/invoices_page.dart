import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'order_detail.dart';

class PartnerInvoicesPage extends StatefulWidget {
  const PartnerInvoicesPage({super.key});

  @override
  State<PartnerInvoicesPage> createState() => _PartnerInvoicesPageState();
}

class _PartnerInvoicesPageState extends State<PartnerInvoicesPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  Json? store;
  String? status = 'OPEN';
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
      context.api.get('/api/b2b/invoices', query: {'status': status, 'page': page}),
      if (store == null) context.api.get('/api/settings/store'),
    ]);
    rows = results[0]['data'] as List;
    meta = results[0]['meta'] as Json;
    if (results.length > 1) store = results[1]['data'] as Json;
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final outstanding = rows.where((i) => i['status'] == 'UNPAID' || i['status'] == 'PARTIAL').fold<int>(0, (s, i) => s + (i['remaining'] as int));
      return PageBody(children: [
        const PageHeader(title: 'Faktur', subtitle: 'Faktur terbit otomatis saat PO disetujui. Status pembayaran diperbarui oleh toko setelah dana diterima.'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.account_balance_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Pembayaran via transfer bank', style: TextStyle(fontWeight: FontWeight.w700)),
                  for (final b in (store?['bankAccounts'] as List?) ?? []) Text('${b['bank']} ${b['number']} a.n. ${b['holder']}'),
                  Text('Cantumkan nomor faktur pada berita transfer. Konfirmasi: ${store?['phone'] ?? '-'}',
                      style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
              if (status == 'OPEN')
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('Total belum lunas'),
                  Text(rupiah(outstanding), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ]),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          for (final (v, l) in [('OPEN', 'Belum lunas'), ('OVERDUE', 'Jatuh tempo'), ('PAID', 'Lunas'), (null, 'Semua')])
            ChoiceChip(label: Text(l), selected: status == v, onSelected: (_) {
              status = v;
              page = 1;
              reload();
            }),
        ]),
        const SizedBox(height: 12),
        if (rows.isEmpty) const EmptyState(icon: Icons.request_quote_outlined, message: 'Tidak ada faktur'),
        ResponsiveGrid(minItemWidth: 360, children: [
          for (final i in rows)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(i['invoiceNumber'], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                    StatusChip(statusOf(invoiceStatus, i['displayStatus']), dense: true),
                  ]),
                  Text('PO ${i['poNumber']} · terbit ${fmtDate(i['issueDate'])}', style: const TextStyle(fontSize: 12.5)),
                  const SizedBox(height: 8),
                  Text('Jatuh tempo ${fmtDate(i['dueDate'])}${dueHint(i as Json)}',
                      style: TextStyle(color: i['displayStatus'] == 'OVERDUE' ? toneColor(context, Tone.critical) : null, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TotalRow('Total', rupiah(i['total'])),
                  TotalRow('Dibayar', rupiah(i['amountPaid'])),
                  TotalRow('Sisa', rupiah(i['remaining']), emphasis: true),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () => guard(context, () => context.api.openDownload('/api/b2b/invoices/${i['id']}/pdf')),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Unduh PDF'),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
        Paginator(meta: meta, onPage: (p) {
          page = p;
          reload();
        }),
      ]);
    });
  }
}
