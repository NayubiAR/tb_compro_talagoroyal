import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Detail Purchase Order (dipakai staf & mitra): item, harga tier, total, faktur, linimasa.
class OrderDetailView extends StatelessWidget {
  const OrderDetailView({super.key, required this.order, this.showPartner = false});
  final Json order;
  final bool showPartner;

  @override
  Widget build(BuildContext context) {
    final items = order['items'] as List;
    final invoice = order['invoice'] as Json?;
    final savings = items.fold<int>(0, (s, i) => s + (i['savings'] as int)) + (order['discount'] as int);
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusChip(statusOf(orderStatus, order['status'])),
        Text('Diajukan ${fmtDateTime(order['createdAt'])}', style: muted),
        if (order['partnerRef'] != null) Text('Ref. instansi: ${order['partnerRef']}', style: muted),
      ]),
      if (order['rejectionReason'] != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: toneColor(context, Tone.critical).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
          child: Text('Alasan: ${order['rejectionReason']}'),
        ),
      ],
      if (showPartner && order['partner'] != null) ...[
        const SizedBox(height: 16),
        _partner(context, order['partner'] as Json),
      ],
      if (order['note'] != null) ...[
        const SizedBox(height: 12),
        Text('Catatan pemesan: ${order['note']}', style: const TextStyle(fontStyle: FontStyle.italic)),
      ],
      const SizedBox(height: 16),
      ScrollTable(
        minWidth: 680,
        columns: const [
          DataColumn(label: Text('SKU')),
          DataColumn(label: Text('Barang')),
          DataColumn(label: Text('Qty')),
          DataColumn(label: Text('Harga satuan'), numeric: true),
          DataColumn(label: Text('Subtotal'), numeric: true),
        ],
        rows: [
          for (final i in items)
            DataRow(cells: [
              DataCell(Text(i['sku'])),
              DataCell(SizedBox(width: 240, child: Text(i['productName'], overflow: TextOverflow.ellipsis))),
              DataCell(Text('${number(i['unitQty'])} ${i['unitName']}')),
              DataCell(Text('${rupiah(i['unitPrice'])}\n${rupiah(i['tierUnitPrice'])}/satuan terkecil', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
              DataCell(Text(rupiah(i['subtotal']))),
            ]),
        ],
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 360,
          child: Column(children: [
            TotalRow('Subtotal (harga tier)', rupiah(order['subtotal'])),
            if ((order['discount'] as int) > 0)
              TotalRow('Diskon level ${order['levelName']} (${order['levelDiscountPercent']}%)', '- ${rupiah(order['discount'])}'),
            if ((order['tax'] as int) > 0) TotalRow('PPN (${order['taxPercent']}%)', rupiah(order['tax'])),
            const Divider(),
            TotalRow('Total', rupiah(order['total']), emphasis: true),
            if (savings > 0) TotalRow('Hemat dibanding harga eceran', rupiah(savings), color: toneColor(context, Tone.good)),
          ]),
        ),
      ),
      if (invoice != null) ...[
        const SizedBox(height: 16),
        _invoice(context, invoice),
      ],
      const SizedBox(height: 16),
      _timeline(context),
    ]);
  }

  Widget _partner(BuildContext context, Json p) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p['institutionName'], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text('${institutionTypeLabel[p['institutionType']] ?? ''} · ${p['address'] ?? ''}'),
          Text('PIC: ${p['pic'] ?? '-'} · ${p['phone'] ?? '-'} · ${p['email'] ?? '-'}'),
          if (p['npwp'] != null) Text('NPWP: ${p['npwp']}'),
        ]),
      ),
    );
  }

  Widget _invoice(BuildContext context, Json inv) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.request_quote_outlined),
            const SizedBox(width: 8),
            Text('Faktur ${inv['invoiceNumber']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            StatusChip(statusOf(invoiceStatus, inv['displayStatus'])),
          ]),
          const SizedBox(height: 8),
          InfoRow('Terbit', fmtDate(inv['issueDate'])),
          InfoRow('Jatuh tempo', '${fmtDate(inv['dueDate'])}${dueHint(inv)}'),
          InfoRow('Dibayar', rupiah(inv['amountPaid'])),
          InfoRow('Sisa tagihan', rupiah(inv['remaining']), bold: true),
          for (final p in (inv['payments'] as List?) ?? [])
            Text('• ${fmtDate(p['paidAt'])} ${paymentMethodLabel[p['method']]} ${rupiah(p['amount'])} ${p['reference'] ?? ''}', style: const TextStyle(fontSize: 12.5)),
        ]),
      ),
    );
  }

  Widget _timeline(BuildContext context) {
    final steps = [
      ('Diajukan mitra', order['createdAt']),
      ('Diverifikasi & faktur terbit', order['approvedAt']),
      ('Siap diambil', order['readyAt']),
      ('Selesai diambil', order['completedAt']),
      if (order['cancelledAt'] != null) ('Dibatalkan', order['cancelledAt']),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (label, at) in steps)
        Row(children: [
          Icon(at != null ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: at != null ? toneColor(context, Tone.good) : Theme.of(context).disabledColor),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: at != null ? null : Theme.of(context).disabledColor)),
          const SizedBox(width: 8),
          if (at != null) Text(fmtDateTime(at), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
    ]);
  }
}

/// " · 3 hari lagi" / " · terlambat 5 hari" untuk faktur yang belum lunas.
String dueHint(Json inv) {
  if (inv['displayStatus'] == 'OVERDUE') return ' · terlambat ${inv['daysOverdue']} hari';
  final d = inv['daysUntilDue'];
  if (d == null) return '';
  return d == 0 ? ' · hari ini' : ' · $d hari lagi';
}
