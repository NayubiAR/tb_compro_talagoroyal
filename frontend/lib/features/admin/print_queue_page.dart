import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Dasbor antrean cetak kasir/operator — diperbarui real-time (Redis Pub/Sub → WebSocket).
class PrintQueuePage extends StatefulWidget {
  const PrintQueuePage({super.key});

  @override
  State<PrintQueuePage> createState() => _PrintQueuePageState();
}

class _PrintQueuePageState extends State<PrintQueuePage> with LoaderMixin, RealtimeMixin {
  Json q = {};
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['print.job.updated'], () => reload(silent: true));
  }

  @override
  Future<void> load() async => q = (await context.api.get('/api/print/queue'))['data'] as Json;

  Future<void> _setStatus(Json job, String status, {String? pickupCode}) async {
    final ok = await guard(
      context,
      () => context.api.patch('/api/print/queue/${job['id']}', {'status': status, 'pickupCode': ?pickupCode}),
    );
    if (ok != null) reload(silent: true);
  }

  Future<void> _handover(Json job) async {
    final code = await promptText(
      context,
      title: 'Serahkan ${job['queueLabel']} ke pelanggan',
      label: 'Kode ambil 6 digit dari aplikasi pelanggan',
      minLength: 6,
      confirmLabel: 'Verifikasi & Serahkan',
    );
    if (code != null) await _setStatus(job, 'COMPLETED', pickupCode: code);
  }

  Future<void> _lookup() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      showSnack(context, 'Masukkan kode ambil 6 digit', error: true);
      return;
    }
    final res = await guard(context, () => context.api.get('/api/print/queue/pickup/$code'));
    if (res == null || !mounted) return;
    final jobs = res['data'] as List;
    if (jobs.isEmpty) {
      showSnack(context, 'Tidak ada pesanan aktif dengan kode $code', error: true);
      return;
    }
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Kode $code'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final j in jobs)
              ListTile(
                leading: Text(j['queueLabel'], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                title: Text('${j['customer']?['name']} · ${j['code']}'),
                subtitle: Text(statusOf(printStatus, j['status']).label),
                trailing: j['status'] == 'READY'
                    ? FilledButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _setStatus(j as Json, 'COMPLETED', pickupCode: code);
                        },
                        child: const Text('Serahkan'),
                      )
                    : null,
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup'))],
      ),
    );
    _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final stats = q['stats'] as Json;
      final columns = [
        ('Menunggu', Icons.hourglass_top, Tone.info, q['waiting'] as List),
        ('Sedang Dicetak', Icons.print, Tone.serious, q['printing'] as List),
        ('Siap Diambil', Icons.inventory_2_outlined, Tone.good, q['ready'] as List),
      ];
      final wide = MediaQuery.sizeOf(context).width >= 1150;
      return PageBody(maxWidth: 1600, children: [
        PageHeader(
          title: 'Antrean Cetak',
          subtitle: 'Pesanan otomatis masuk setelah pembayaran QRIS tervalidasi · ${stats['paidToday']} dibayar hari ini (${rupiah(stats['revenueToday'])}) · ${stats['completedToday']} selesai',
          actions: [
            SizedBox(
              width: 220,
              child: TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: 'Kode ambil pelanggan',
                  suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _lookup),
                ),
                onSubmitted: (_) => _lookup(),
              ),
            ),
            OutlinedButton.icon(onPressed: () => _showHistory(context), icon: const Icon(Icons.history), label: const Text('Riwayat')),
            OutlinedButton.icon(onPressed: () => context.go('/antrean'), icon: const Icon(Icons.tv), label: const Text('Layar Monitor')),
          ],
        ),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              Expanded(child: _column(context, columns[i])),
            ],
          ])
        else
          for (final c in columns) Padding(padding: const EdgeInsets.only(bottom: 16), child: _column(context, c)),
      ]);
    });
  }

  Widget _column(BuildContext context, (String, IconData, Tone, List) c) {
    final (title, icon, tone, jobs) = c;
    final color = toneColor(context, tone);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 16)),
          const Spacer(),
          CircleAvatar(radius: 14, backgroundColor: color, child: Text('${jobs.length}', style: const TextStyle(color: Colors.white, fontSize: 13))),
        ]),
        const SizedBox(height: 12),
        if (jobs.isEmpty) const EmptyState(icon: Icons.inbox_outlined, message: 'Kosong'),
        for (final j in jobs) Padding(padding: const EdgeInsets.only(bottom: 10), child: _jobCard(context, j as Json)),
      ]),
    );
  }

  Widget _jobCard(BuildContext context, Json j) {
    final muted = TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant);
    final status = j['status'] as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(j['queueLabel'] ?? '-', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(j['customer']?['name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${j['code']} · bayar ${fmtTime(j['paidAt'])}', style: muted),
              ]),
            ),
            Text(rupiah(j['pricing']['total']), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.description_outlined, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text('${j['originalName']} · ${j['pagesToPrint']} hal', overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 4),
          Text(printConfigSummary(j['config'] as Json), style: muted),
          if (j['config']['notes'] != null) ...[
            const SizedBox(height: 4),
            Text('Catatan: ${j['config']['notes']}', style: muted.copyWith(fontStyle: FontStyle.italic)),
          ],
          if (j['customer']?['phone'] != null) Text('HP ${j['customer']['phone']}', style: muted),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: j['fileAvailable'] == true ? () => guard(context, () => context.api.openDownload('/api/print/jobs/${j['id']}/file')) : null,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Unduh berkas'),
            ),
            if (status == 'QUEUED')
              FilledButton.icon(onPressed: () => _setStatus(j, 'PRINTING'), icon: const Icon(Icons.print, size: 18), label: const Text('Mulai cetak')),
            if (status == 'PRINTING') ...[
              FilledButton.icon(onPressed: () => _setStatus(j, 'READY'), icon: const Icon(Icons.done, size: 18), label: const Text('Selesai dicetak')),
              TextButton(onPressed: () => _setStatus(j, 'QUEUED'), child: const Text('Kembalikan')),
            ],
            if (status == 'READY')
              FilledButton.icon(onPressed: () => _handover(j), icon: const Icon(Icons.handshake_outlined, size: 18), label: const Text('Serahkan')),
          ]),
        ]),
      ),
    );
  }

  Future<void> _showHistory(BuildContext context) {
    return showWideDialog(context, maxWidth: 1000, builder: (_) => const _PrintHistory());
  }
}

class _PrintHistory extends StatefulWidget {
  const _PrintHistory();

  @override
  State<_PrintHistory> createState() => _PrintHistoryState();
}

class _PrintHistoryState extends State<_PrintHistory> with LoaderMixin {
  List rows = [];
  Json? meta;
  int page = 1;
  String? status;
  String q = '';

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/print/admin/jobs', query: {'page': page, 'status': status, 'q': q});
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  @override
  Widget build(BuildContext context) {
    return DialogFrame(
      title: 'Riwayat Pesanan Cetak',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          SearchBox(hint: 'Kode / nama berkas / pelanggan', onChanged: (v) {
            q = v;
            page = 1;
            reload();
          }),
          DropdownButton<String?>(
            value: status,
            hint: const Text('Semua status'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Semua status')),
              for (final s in ['AWAITING_PAYMENT', 'QUEUED', 'PRINTING', 'READY', 'COMPLETED', 'CANCELLED', 'EXPIRED'])
                DropdownMenuItem(value: s, child: Text(printStatus[s]!.label)),
            ],
            onChanged: (v) {
              status = v;
              page = 1;
              reload();
            },
          ),
        ]),
        const SizedBox(height: 12),
        loadedBody(() => ScrollTable(
              minWidth: 860,
              columns: const [
                DataColumn(label: Text('Kode')),
                DataColumn(label: Text('Pelanggan')),
                DataColumn(label: Text('Berkas')),
                DataColumn(label: Text('Spesifikasi')),
                DataColumn(label: Text('Total'), numeric: true),
                DataColumn(label: Text('Status')),
              ],
              rows: [
                for (final j in rows)
                  DataRow(cells: [
                    DataCell(Text('${j['code']}\n${fmtDateTime(j['createdAt'])}', style: const TextStyle(fontSize: 12.5))),
                    DataCell(Text(j['customer']?['name'] ?? '-')),
                    DataCell(SizedBox(width: 180, child: Text('${j['originalName']} (${j['pagesToPrint']} hal)', overflow: TextOverflow.ellipsis))),
                    DataCell(SizedBox(width: 220, child: Text(printConfigSummary(j['config'] as Json), style: const TextStyle(fontSize: 12.5)))),
                    DataCell(Text(rupiah(j['pricing']['total']))),
                    DataCell(StatusChip(statusOf(printStatus, j['status']), dense: true)),
                  ]),
              ],
            )),
        Paginator(meta: meta, onPage: (p) {
          page = p;
          reload();
        }),
      ]),
    );
  }
}
