import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../state/auth_state.dart';
import '../../widgets/common.dart';

class B2bHomePage extends StatefulWidget {
  const B2bHomePage({super.key});

  @override
  State<B2bHomePage> createState() => _B2bHomePageState();
}

class _B2bHomePageState extends State<B2bHomePage> with LoaderMixin, RealtimeMixin {
  Json? s;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['order.updated', 'invoice.updated'], () => reload(silent: true));
    // Status verifikasi bisa berubah saat mitra sedang login (diverifikasi staf).
    listenRealtime(['notification'], () async {
      await context.auth.refreshMe();
      reload(silent: true);
    }, where: (d) => d is Map && d['type'] == 'PARTNER');
  }

  @override
  Future<void> load() async {
    s = context.auth.partnerVerified ? (await context.api.get('/api/b2b/summary'))['data'] as Json : null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final partner = auth.partner ?? {};
    if (!auth.partnerVerified) {
      return _PartnerStatus(partner: partner, onRefresh: () async {
        await auth.refreshMe();
        reload();
      });
    }
    return loadedBody(() {
      final d = s!;
      final orders = d['ordersByStatus'] as Json;
      return PageBody(children: [
        PageHeader(
          title: partner['institutionName'] ?? 'Portal B2B',
          subtitle: 'Level ${d['level'] ?? '-'} · diskon tambahan ${d['discountPercent']}% · termin ${d['paymentTermDays']} hari',
          actions: [
            OutlinedButton.icon(onPressed: () => context.go('/b2b/catalog'), icon: const Icon(Icons.storefront_outlined), label: const Text('Katalog')),
            FilledButton.icon(onPressed: () => context.go('/b2b/quick-po'), icon: const Icon(Icons.table_view_outlined), label: const Text('Buat Quick PO')),
          ],
        ),
        if ((d['overdueCount'] as int) > 0) ...[
          Card(
            color: toneColor(context, Tone.critical).withValues(alpha: 0.08),
            child: ListTile(
              leading: Icon(Icons.error_outline, color: toneColor(context, Tone.critical)),
              title: Text('${d['overdueCount']} faktur telah jatuh tempo · ${rupiah(d['overdueAmount'])}'),
              subtitle: const Text('Mohon segera lakukan pembayaran agar pemesanan tidak terhambat.'),
              trailing: TextButton(onPressed: () => context.go('/b2b/invoices'), child: const Text('Lihat faktur')),
            ),
          ),
          const SizedBox(height: 16),
        ],
        ResponsiveGrid(minItemWidth: 240, children: [
          StatCard(label: 'Tagihan berjalan', value: rupiah(d['outstanding']), icon: Icons.request_quote_outlined, onTap: () => context.go('/b2b/invoices')),
          StatCard(
            label: 'Sisa limit kredit',
            value: d['creditAvailable'] == null ? 'Tanpa batas' : rupiah(d['creditAvailable']),
            icon: Icons.account_balance_wallet_outlined,
            caption: (d['creditLimit'] as int) > 0 ? 'Limit ${rupiah(d['creditLimit'])}' : null,
          ),
          StatCard(label: 'Menunggu verifikasi', value: '${orders['SUBMITTED'] ?? 0} PO', icon: Icons.hourglass_top, onTap: () => context.go('/b2b/orders')),
          StatCard(
            label: 'Siap diambil',
            value: '${orders['READY'] ?? 0} PO',
            icon: Icons.inventory_2_outlined,
            tone: (orders['READY'] ?? 0) > 0 ? Tone.good : null,
            onTap: () => context.go('/b2b/orders'),
          ),
        ]),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Pesanan terbaru',
          trailing: TextButton(onPressed: () => context.go('/b2b/orders'), child: const Text('Semua')),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(children: [
            if ((d['recentOrders'] as List).isEmpty)
              EmptyState(
                icon: Icons.receipt_long_outlined,
                message: 'Belum ada pesanan. Buat PO pertama Anda dengan Quick PO.',
                action: FilledButton(onPressed: () => context.go('/b2b/quick-po'), child: const Text('Buat Quick PO')),
              ),
            for (final o in d['recentOrders'] as List)
              ListTile(
                title: Text('${o['poNumber']} · ${o['itemCount']} item'),
                subtitle: Text('${fmtDateTime(o['createdAt'])}${o['partnerRef'] != null ? ' · ${o['partnerRef']}' : ''}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(rupiah(o['total']), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  StatusChip(statusOf(orderStatus, o['status']), dense: true),
                ]),
                onTap: () => context.go('/b2b/orders?id=${o['id']}'),
              ),
          ]),
        ),
      ]);
    });
  }
}

/// Tampilan untuk mitra yang belum terverifikasi / ditolak / ditangguhkan.
class _PartnerStatus extends StatefulWidget {
  const _PartnerStatus({required this.partner, required this.onRefresh});
  final Json partner;
  final Future<void> Function() onRefresh;

  @override
  State<_PartnerStatus> createState() => _PartnerStatusState();
}

class _PartnerStatusState extends State<_PartnerStatus> {
  late final name = TextEditingController(text: widget.partner['institutionName']);
  late final address = TextEditingController(text: widget.partner['address']);
  late final npwp = TextEditingController(text: widget.partner['npwp'] ?? '');
  late String type = widget.partner['institutionType'] ?? 'SEKOLAH';

  Future<void> _resubmit() async {
    final res = await guard(
      context,
      () => context.api.put('/api/auth/partner', {'institutionName': name.text, 'institutionType': type, 'address': address.text, 'npwp': npwp.text}),
      success: 'Data dikirim ulang untuk diverifikasi',
    );
    if (res != null && mounted) context.auth.updateUser(res['data'] as Json);
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.partner['status'];
    final info = statusOf(partnerStatus, status);
    final messages = {
      'PENDING': 'Pendaftaran ${widget.partner['institutionName']} sedang ditinjau oleh Talago Royal. Anda akan menerima notifikasi setelah diverifikasi. Sementara itu, layanan cetak dokumen sudah bisa digunakan.',
      'REJECTED': 'Pendaftaran ditolak: ${widget.partner['rejectionReason'] ?? '-'}. Perbaiki data institusi di bawah lalu ajukan ulang.',
      'SUSPENDED': 'Akses pemesanan B2B Anda sedang ditangguhkan. Riwayat pesanan & faktur tetap bisa dilihat. Hubungi Talago Royal untuk informasi.',
    };
    return PageBody(maxWidth: 760, children: [
      PageHeader(title: 'Portal B2B', subtitle: widget.partner['institutionName']),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            StatusChip(info),
            const SizedBox(height: 12),
            Text(messages[status] ?? ''),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: widget.onRefresh, icon: const Icon(Icons.refresh), label: const Text('Periksa status')),
              FilledButton.tonalIcon(onPressed: () => context.go('/print'), icon: const Icon(Icons.print_outlined), label: const Text('Cetak dokumen')),
              if (status == 'SUSPENDED') ...[
                TextButton(onPressed: () => context.go('/b2b/orders'), child: const Text('Riwayat pesanan')),
                TextButton(onPressed: () => context.go('/b2b/invoices'), child: const Text('Faktur')),
              ],
            ]),
          ]),
        ),
      ),
      if (status == 'REJECTED') ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Perbaiki data institusi',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama institusi')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Jenis'),
              items: [for (final e in institutionTypeLabel.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => type = v!,
            ),
            const SizedBox(height: 12),
            TextField(controller: address, maxLines: 2, decoration: const InputDecoration(labelText: 'Alamat')),
            const SizedBox(height: 12),
            TextField(controller: npwp, decoration: const InputDecoration(labelText: 'NPWP')),
            const SizedBox(height: 16),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _resubmit, child: const Text('Ajukan ulang'))),
          ]),
        ),
      ],
    ]);
  }
}
