import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Status pesanan cetak: QRIS + hitung mundur, lalu nomor antrean & kode ambil (real-time).
class PrintJobPage extends StatefulWidget {
  const PrintJobPage({super.key, required this.id});
  final int id;

  @override
  State<PrintJobPage> createState() => _PrintJobPageState();
}

class _PrintJobPageState extends State<PrintJobPage> with LoaderMixin, RealtimeMixin {
  Json job = {};
  Json? paymentConfig;
  Json? publicQueue;
  Timer? _tick;
  Timer? _poll;
  Duration remaining = Duration.zero;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    reload();
    listenRealtime(['print.job.updated'], () => reload(silent: true), where: (d) => d is Map && d['id'] == widget.id);
    listenRealtime(['print.queue.updated'], _loadQueue);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _updateCountdown());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Future<void> load() async {
    final results = await Future.wait([
      context.api.get('/api/print/jobs/${widget.id}'),
      if (paymentConfig == null) context.api.get('/api/payments/config'),
    ]);
    job = results[0]['data'] as Json;
    if (results.length > 1) paymentConfig = results[1]['data'] as Json;
    _updateCountdown();
    _setupPolling();
    if (job['status'] == 'QUEUED') await _loadQueue();
  }

  Future<void> _loadQueue() async {
    try {
      final res = await context.api.get('/api/print/queue/public');
      if (mounted) setState(() => publicQueue = res['data'] as Json);
    } catch (_) {}
  }

  /// Cadangan bila webhook payment gateway tidak sampai (mis. server lokal tanpa ngrok).
  void _setupPolling() {
    _poll?.cancel();
    if (job['status'] == 'AWAITING_PAYMENT' && paymentConfig?['simulation'] != true) {
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => _checkPayment(silent: true));
    }
  }

  void _updateCountdown() {
    final expires = parseDate(job['payment']?['expiresAt']);
    if (!mounted || expires == null) return;
    final left = expires.difference(DateTime.now());
    setState(() => remaining = left.isNegative ? Duration.zero : left);
  }

  Future<void> _checkPayment({bool silent = false}) async {
    try {
      final res = await context.api.post('/api/print/jobs/${widget.id}/check-payment');
      if (!mounted) return;
      setState(() => job = res['data'] as Json);
      _setupPolling();
      if (!silent && job['status'] == 'AWAITING_PAYMENT') showSnack(context, 'Pembayaran belum diterima');
    } catch (e) {
      if (!silent && mounted) showError(context, e);
    }
  }

  Future<void> _simulate() async {
    setState(() => busy = true);
    await guard(context, () => context.api.post('/api/payments/mock/${job['payment']['orderId']}/pay'), success: 'Pembayaran simulasi berhasil');
    if (mounted) setState(() => busy = false);
    reload(silent: true);
  }

  Future<void> _cancel() async {
    final ok = await confirmDialog(context, title: 'Batalkan pesanan?', message: 'QRIS akan dinonaktifkan dan pesanan dibatalkan.', destructive: true, confirmLabel: 'Batalkan');
    if (!ok || !mounted) return;
    await guard(context, () => context.api.post('/api/print/jobs/${widget.id}/cancel'), success: 'Pesanan dibatalkan');
    reload(silent: true);
  }

  Future<void> _payAgain() async {
    final cfg = Map<String, dynamic>.from(job['config'] as Json)..removeWhere((k, v) => v == null);
    setState(() => busy = true);
    final res = await guard(context, () => context.api.post('/api/print/jobs/${widget.id}/checkout', cfg));
    if (!mounted) return;
    setState(() {
      busy = false;
      if (res != null) job = res['data'] as Json;
    });
    _setupPolling();
  }

  @override
  Widget build(BuildContext context) {
    return loadedBody(() {
      final status = job['status'] as String;
      final wide = MediaQuery.sizeOf(context).width >= 1000;
      final main = _mainCard(context, status);
      final detail = _detailCard(context);
      return PageBody(maxWidth: 1100, children: [
        PageHeader(
          title: 'Pesanan ${job['code']}',
          subtitle: job['originalName'],
          actions: [OutlinedButton.icon(onPressed: () => context.go('/print/jobs'), icon: const Icon(Icons.list), label: const Text('Semua pesanan'))],
        ),
        _stepper(context, status),
        const SizedBox(height: 16),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: main), const SizedBox(width: 16), Expanded(flex: 2, child: detail)])
        else ...[main, const SizedBox(height: 16), detail],
      ]);
    });
  }

  Widget _stepper(BuildContext context, String status) {
    const steps = ['Bayar', 'Antre', 'Dicetak', 'Siap Diambil', 'Selesai'];
    const index = {'AWAITING_PAYMENT': 0, 'QUEUED': 1, 'PRINTING': 2, 'READY': 3, 'COMPLETED': 4};
    final current = index[status];
    if (current == null) return StatusChip(statusOf(printStatus, status));
    final good = toneColor(context, Tone.good);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(children: [
          for (var i = 0; i < steps.length; i++) ...[
            Expanded(
              child: Column(children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: i <= current ? good : Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: i < current
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text('${i + 1}', style: TextStyle(fontSize: 12, color: i == current ? Colors.white : null)),
                ),
                const SizedBox(height: 6),
                Text(steps[i], textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: i == current ? FontWeight.w700 : FontWeight.w400)),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _mainCard(BuildContext context, String status) {
    final payment = job['payment'] as Json?;
    switch (status) {
      case 'AWAITING_PAYMENT':
        final mm = remaining.inMinutes.toString().padLeft(2, '0');
        final ss = (remaining.inSeconds % 60).toString().padLeft(2, '0');
        return SectionCard(
          title: 'Bayar dengan QRIS',
          child: Column(children: [
            Text(rupiah(payment?['amount']), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (payment?['qrString'] != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: payment!['qrString'] as String, size: 240, backgroundColor: Colors.white),
              ),
            const SizedBox(height: 12),
            Text(
              remaining == Duration.zero ? 'QRIS kedaluwarsa' : 'Berlaku $mm:$ss lagi',
              style: TextStyle(fontWeight: FontWeight.w700, color: toneColor(context, remaining.inMinutes < 3 ? Tone.critical : Tone.warning)),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pindai dengan aplikasi m-banking atau e-wallet yang mendukung QRIS. Status akan diperbarui otomatis.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(onPressed: () => _checkPayment(), icon: const Icon(Icons.refresh), label: const Text('Cek status pembayaran')),
              if (paymentConfig?['simulation'] == true)
                FilledButton.icon(
                  onPressed: busy || remaining == Duration.zero ? null : _simulate,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Simulasikan pembayaran (demo)'),
                ),
              TextButton(onPressed: _cancel, child: const Text('Batalkan pesanan')),
            ]),
          ]),
        );
      case 'QUEUED':
      case 'PRINTING':
      case 'READY':
        final waiting = (publicQueue?['waiting'] as List?) ?? [];
        final ahead = waiting.indexOf(job['queueLabel']);
        final info = {
          'QUEUED': ahead > 0 ? 'Ada $ahead antrean sebelum Anda.' : 'Anda berikutnya! Dokumen segera dicetak.',
          'PRINTING': 'Dokumen Anda sedang dicetak.',
          'READY': 'Dokumen siap diambil di kasir. Tunjukkan kode ambil di bawah.',
        }[status]!;
        final tone = status == 'READY' ? Tone.good : Tone.info;
        return SectionCard(
          title: 'Nomor antrean',
          child: Column(children: [
            Text(job['queueLabel'] ?? '-', style: TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: toneColor(context, tone))),
            StatusChip(statusOf(printStatus, status)),
            const SizedBox(height: 10),
            Text(info, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Brand.gold, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(children: [
                const Text('KODE AMBIL', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700)),
                Text(job['pickupCode'] ?? '------', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 8)),
                const Text('Jangan bagikan kode ini kepada orang lain', style: TextStyle(fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 12),
            TextButton.icon(onPressed: () => context.go('/antrean'), icon: const Icon(Icons.tv), label: const Text('Lihat layar antrean toko')),
          ]),
        );
      case 'COMPLETED':
        return SectionCard(
          child: EmptyState(icon: Icons.check_circle_outline, message: 'Pesanan selesai diambil pada ${fmtDateTime(job['completedAt'])}. Terima kasih!'),
        );
      case 'EXPIRED':
        return SectionCard(
          title: 'Pembayaran kedaluwarsa',
          child: Column(children: [
            const Text('QRIS sudah tidak berlaku. Anda dapat membuat QRIS baru dengan spesifikasi yang sama.'),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [
              FilledButton.icon(onPressed: busy || job['fileAvailable'] != true ? null : _payAgain, icon: const Icon(Icons.qr_code_2), label: const Text('Bayar ulang')),
              TextButton(onPressed: _cancel, child: const Text('Batalkan')),
            ]),
          ]),
        );
      default:
        return SectionCard(child: EmptyState(icon: Icons.cancel_outlined, message: 'Pesanan ${statusOf(printStatus, status).label.toLowerCase()}.'));
    }
  }

  Widget _detailCard(BuildContext context) {
    final cfg = job['config'] as Json;
    final pricing = job['pricing'] as Json;
    return SectionCard(
      title: 'Detail pesanan',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InfoRow('Berkas', job['originalName'], labelWidth: 110),
        InfoRow('Halaman', '${job['pagesToPrint']} dari ${job['pageCount']} halaman', labelWidth: 110),
        InfoRow('Spesifikasi', printConfigSummary(cfg), labelWidth: 110),
        if (cfg['notes'] != null) InfoRow('Catatan', cfg['notes'], labelWidth: 110),
        const Divider(),
        TotalRow('Biaya cetak', rupiah(pricing['printCost'])),
        if ((pricing['bindingCost'] as int) > 0) TotalRow('Biaya jilid', rupiah(pricing['bindingCost'])),
        TotalRow('Total', rupiah(pricing['total']), emphasis: true),
        const Divider(),
        InfoRow('Dibuat', fmtDateTime(job['createdAt']), labelWidth: 110),
        if (job['paidAt'] != null) InfoRow('Dibayar', fmtDateTime(job['paidAt']), labelWidth: 110),
        if (job['readyAt'] != null) InfoRow('Siap', fmtDateTime(job['readyAt']), labelWidth: 110),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: job['fileAvailable'] == true ? () => guard(context, () => context.api.openDownload('/api/print/jobs/${widget.id}/file')) : null,
          icon: const Icon(Icons.download),
          label: Text(job['fileAvailable'] == true ? 'Lihat berkas yang dikirim' : 'Berkas sudah dihapus (retensi)'),
        ),
      ]),
    );
  }
}
