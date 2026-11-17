import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';
import '../b2b/order_detail.dart';

/// Verifikasi & pemrosesan Purchase Order mitra B2B.
class AdminOrdersPage extends StatefulWidget {
  const AdminOrdersPage({super.key, this.initialId});
  final int? initialId;

  @override
  State<AdminOrdersPage> createState() => _AdminOrdersPageState();
}

class _AdminOrdersPageState extends State<AdminOrdersPage> with LoaderMixin, RealtimeMixin {
  List rows = [];
  Json? meta;
  String? status = 'SUBMITTED';
  String q = '';
  int page = 1;

  @override
  void initState() {
    super.initState();
    if (widget.initialId != null) status = null;
    reload().then((_) {
      if (widget.initialId != null && mounted) _open(widget.initialId!);
    });
    listenRealtime(['order.updated'], () => reload(silent: true));
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/admin/b2b/orders', query: {'status': status, 'q': q, 'page': page});
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  Future<void> _open(int id) async {
    final res = await guard(context, () => context.api.get('/api/admin/b2b/orders/$id'));
    if (res == null || !mounted) return;
    await showWideDialog<void>(context, maxWidth: 940, builder: (_) => _OrderDialog(order: res['data'] as Json));
    if (mounted) reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final counts = (meta?['counts'] as Json?) ?? {};
      return PageBody(children: [
        const PageHeader(
          title: 'Pesanan B2B',
          subtitle: 'Verifikasi PO → stok terpotong otomatis & faktur PDF terbit. Harga terkunci saat PO diajukan.',
        ),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ChoiceChip(label: const Text('Semua'), selected: status == null, onSelected: (_) => _setStatus(null)),
          for (final e in orderStatus.entries)
            ChoiceChip(label: Text('${e.value.label} (${counts[e.key] ?? 0})'), selected: status == e.key, onSelected: (_) => _setStatus(e.key)),
          const SizedBox(width: 8),
          SearchBox(hint: 'No. PO / instansi / ref', onChanged: (v) {
            q = v;
            page = 1;
            reload();
          }),
        ]),
        const SizedBox(height: 16),
        Card(
          child: rows.isEmpty
              ? const EmptyState(icon: Icons.receipt_long_outlined, message: 'Tidak ada PO')
              : ScrollTable(
                  minWidth: 960,
                  columns: const [
                    DataColumn(label: Text('No. PO')),
                    DataColumn(label: Text('Mitra')),
                    DataColumn(label: Text('Diajukan')),
                    DataColumn(label: Text('Item'), numeric: true),
                    DataColumn(label: Text('Total'), numeric: true),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Faktur')),
                  ],
                  rows: [
                    for (final o in rows)
                      DataRow(onSelectChanged: (_) => _open(o['id'] as int), cells: [
                        DataCell(Text('${o['poNumber']}${o['partnerRef'] != null ? '\n${o['partnerRef']}' : ''}', style: const TextStyle(fontSize: 13))),
                        DataCell(Text(o['partner']?['institutionName'] ?? '-')),
                        DataCell(Text(fmtDateTime(o['createdAt']))),
                        DataCell(Text('${o['itemCount']}')),
                        DataCell(Text(rupiah(o['total']), style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(StatusChip(statusOf(orderStatus, o['status']), dense: true)),
                        DataCell(o['invoice'] == null
                            ? const Text('-')
                            : StatusChip(statusOf(invoiceStatus, o['invoice']['displayStatus']), dense: true)),
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

  void _setStatus(String? s) {
    status = s;
    page = 1;
    reload();
  }
}

class _OrderDialog extends StatefulWidget {
  const _OrderDialog({required this.order});
  final Json order;

  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  late Json order = widget.order;
  bool busy = false;

  Future<void> _act(String action, {Object? body, String? success}) async {
    setState(() => busy = true);
    final res = await guard(context, () => context.api.post('/api/admin/b2b/orders/${order['id']}/$action', body), success: success);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (res != null) order = res['data'] as Json;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = order['status'];
    final id = order['id'];
    return DialogFrame(
        title: 'PO ${order['poNumber']}',
        subtitle: order['partner']?['institutionName'],
        actions: [
          OutlinedButton.icon(
            onPressed: () => guard(context, () => context.api.openDownload('/api/admin/b2b/orders/$id/pdf')),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('PDF PO'),
          ),
          if (order['invoice'] != null)
            OutlinedButton.icon(
              onPressed: () => guard(context, () => context.api.openDownload('/api/admin/b2b/invoices/${order['invoice']['id']}/pdf')),
              icon: const Icon(Icons.request_quote_outlined),
              label: const Text('PDF Faktur'),
            ),
          if (s == 'SUBMITTED') ...[
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final reason = await promptText(context, title: 'Tolak PO', label: 'Alasan penolakan (dikirim ke mitra)', minLength: 3, confirmLabel: 'Tolak');
                      if (reason != null) await _act('reject', body: {'reason': reason}, success: 'PO ditolak');
                    },
              child: const Text('Tolak'),
            ),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final ok = await confirmDialog(
                        context,
                        title: 'Setujui PO?',
                        message: 'Stok akan dipotong sesuai pesanan dan faktur ${rupiah(order['total'])} terbit otomatis dengan jatuh tempo sesuai termin mitra.',
                        confirmLabel: 'Setujui & terbitkan faktur',
                      );
                      if (ok) await _act('approve', success: 'PO disetujui, faktur terbit');
                    },
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Setujui & Terbitkan Faktur'),
            ),
          ],
          if (s == 'APPROVED' || s == 'READY')
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final reason = await promptText(context, title: 'Batalkan PO', label: 'Alasan pembatalan', minLength: 3, confirmLabel: 'Batalkan PO');
                      if (reason != null) await _act('cancel', body: {'reason': reason}, success: 'PO dibatalkan, stok dikembalikan');
                    },
              child: const Text('Batalkan'),
            ),
          if (s == 'APPROVED')
            FilledButton.icon(
              onPressed: busy ? null : () => _act('ready', success: 'Mitra diberi tahu pesanan siap diambil'),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Tandai Siap Diambil'),
            ),
          if (s == 'READY')
            FilledButton.icon(
              onPressed: busy ? null : () => _act('complete', success: 'PO selesai'),
              icon: const Icon(Icons.done_all),
              label: const Text('Sudah Diambil'),
            ),
        ],
        child: OrderDetailView(order: order, showPartner: true),
    );
  }
}
