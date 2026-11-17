import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../state/po_draft.dart';
import '../../widgets/common.dart';
import 'order_detail.dart';

class PartnerOrdersPage extends StatefulWidget {
  const PartnerOrdersPage({super.key, this.initialId});
  final int? initialId;

  @override
  State<PartnerOrdersPage> createState() => _PartnerOrdersPageState();
}

class _PartnerOrdersPageState extends State<PartnerOrdersPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  String? status;
  int page = 1;

  @override
  void initState() {
    super.initState();
    reload().then((_) {
      if (widget.initialId != null && mounted) _open(widget.initialId!);
    });
    listenRealtime(['order.updated'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/b2b/orders', query: {'status': status, 'page': page});
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  Future<void> _open(int id) async {
    final res = await guard(context, () => context.api.get('/api/b2b/orders/$id'));
    if (res == null || !mounted) return;
    final order = res['data'] as Json;
    await showWideDialog(
      context,
      maxWidth: 900,
      builder: (ctx) => DialogFrame(
        title: 'PO ${order['poNumber']}',
        actions: [
          OutlinedButton.icon(
            onPressed: () => guard(context, () => context.api.openDownload('/api/b2b/orders/$id/pdf')),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Unduh PO'),
          ),
          if (order['invoice'] != null)
            OutlinedButton.icon(
              onPressed: () => guard(context, () => context.api.openDownload('/api/b2b/invoices/${order['invoice']['id']}/pdf')),
              icon: const Icon(Icons.request_quote_outlined),
              label: const Text('Unduh Faktur'),
            ),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _reorder(order);
            },
            icon: const Icon(Icons.replay),
            label: const Text('Pesan ulang'),
          ),
          if (order['status'] == 'SUBMITTED')
            TextButton(
              onPressed: () async {
                final ok = await confirmDialog(ctx, title: 'Batalkan PO?', message: 'PO yang belum diverifikasi akan dibatalkan.', destructive: true, confirmLabel: 'Batalkan PO');
                if (!ok || !ctx.mounted) return;
                final res = await guard(ctx, () => context.api.post('/api/b2b/orders/$id/cancel', {}), success: 'PO dibatalkan');
                if (res != null && ctx.mounted) Navigator.pop(ctx);
                reload(silent: true);
              },
              child: const Text('Batalkan PO'),
            ),
        ],
        child: OrderDetailView(order: order),
      ),
    );
  }

  void _reorder(Json order) {
    context.read<PoDraft>().replaceAll([
      for (final i in order['items'] as List) PoDraftLine(sku: i['sku'], unitName: i['unitName'], qty: i['unitQty'] as int),
    ]);
    context.go('/b2b/quick-po');
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Pesanan Saya',
            subtitle: 'Pantau status PO, unduh dokumen PO & faktur, atau pesan ulang dengan sekali klik.',
            actions: [FilledButton.icon(onPressed: () => context.go('/b2b/quick-po'), icon: const Icon(Icons.add), label: const Text('PO baru'))],
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('Semua'), selected: status == null, onSelected: (_) => _filter(null)),
            for (final e in orderStatus.entries) ChoiceChip(label: Text(e.value.label), selected: status == e.key, onSelected: (_) => _filter(e.key)),
          ]),
          const SizedBox(height: 12),
          Card(
            child: rows.isEmpty
                ? const EmptyState(icon: Icons.receipt_long_outlined, message: 'Belum ada pesanan')
                : ScrollTable(
                    minWidth: 820,
                    columns: const [
                      DataColumn(label: Text('No. PO')),
                      DataColumn(label: Text('Tanggal')),
                      DataColumn(label: Text('Item'), numeric: true),
                      DataColumn(label: Text('Total'), numeric: true),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Faktur')),
                    ],
                    rows: [
                      for (final o in rows)
                        DataRow(onSelectChanged: (_) => _open(o['id'] as int), cells: [
                          DataCell(Text('${o['poNumber']}${o['partnerRef'] != null ? '\n${o['partnerRef']}' : ''}', style: const TextStyle(fontSize: 13))),
                          DataCell(Text(fmtDateTime(o['createdAt']))),
                          DataCell(Text('${o['itemCount']}')),
                          DataCell(Text(rupiah(o['total']), style: const TextStyle(fontWeight: FontWeight.w600))),
                          DataCell(StatusChip(statusOf(orderStatus, o['status']), dense: true)),
                          DataCell(o['invoice'] == null ? const Text('-') : StatusChip(statusOf(invoiceStatus, o['invoice']['displayStatus']), dense: true)),
                        ]),
                    ],
                  ),
          ),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }

  void _filter(String? s) {
    status = s;
    page = 1;
    reload();
  }
}
