import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Layar monitor antrean cetak untuk TV di toko (tanpa login, tanpa data pribadi).
/// Diperbarui real-time lewat WebSocket room "public".
class QueueMonitorPage extends StatefulWidget {
  const QueueMonitorPage({super.key});

  @override
  State<QueueMonitorPage> createState() => _QueueMonitorPageState();
}

class _QueueMonitorPageState extends State<QueueMonitorPage> with RealtimeMixin {
  Map<String, dynamic>? data;
  String store = 'Talago Royal';
  late Timer _clock;
  late Timer _poll;
  DateTime now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
    context.api.get('/api/settings/store').then((r) {
      if (mounted) setState(() => store = r['data']['name']);
    }).catchError((_) {});
    listenRealtime(['print.queue.updated'], _load);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => now = DateTime.now()));
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load()); // cadangan bila koneksi WS putus
  }

  @override
  void dispose() {
    _clock.cancel();
    _poll.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await context.api.get('/api/print/queue/public');
      if (mounted) setState(() => data = res['data'] as Map<String, dynamic>);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF111A3D);
    final ready = (data?['ready'] as List?) ?? [];
    final printing = (data?['printing'] as List?) ?? [];
    final waiting = (data?['waiting'] as List?) ?? [];
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconButton(
                onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                icon: const Icon(Icons.arrow_back, color: Colors.white54),
                tooltip: 'Kembali',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(store, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                  const Text('Antrean Layanan Cetak Dokumen', style: TextStyle(color: Brand.gold, fontSize: 16)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(DateFormat('HH:mm:ss').format(now),
                    style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                Text(DateFormat('EEEE, d MMMM yyyy', 'id_ID').format(now), style: const TextStyle(color: Colors.white70)),
              ]),
            ]),
            const SizedBox(height: 28),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final panels = [
                  _Panel(title: 'SIAP DIAMBIL', icon: Icons.inventory_2_outlined, color: const Color(0xFF5CC46A), items: ready, big: true),
                  _Panel(title: 'SEDANG DICETAK', icon: Icons.print, color: const Color(0xFFF08A4B), items: printing),
                  _Panel(title: 'MENUNGGU', icon: Icons.hourglass_top, color: const Color(0xFF7FA8F5), items: waiting),
                ];
                return c.maxWidth > 900
                    ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(flex: 4, child: panels[0]),
                        const SizedBox(width: 20),
                        Expanded(flex: 3, child: panels[1]),
                        const SizedBox(width: 20),
                        Expanded(flex: 3, child: panels[2]),
                      ])
                    : ListView(children: [for (final p in panels) Padding(padding: const EdgeInsets.only(bottom: 16), child: SizedBox(height: 260, child: p))]);
              }),
            ),
            const SizedBox(height: 16),
            const Text(
              'Pesan cetak dari rumah: unggah dokumen, bayar QRIS, lalu ambil saat nomor Anda muncul di kolom SIAP DIAMBIL. Tunjukkan kode ambil ke kasir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.color, required this.items, this.big = false});
  final String title;
  final IconData icon;
  final Color color;
  final List items;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 10),
          Text(title, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
          const Spacer(),
          Text('${items.length}', style: const TextStyle(color: Colors.white54, fontSize: 18)),
        ]),
        const SizedBox(height: 16),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('—', style: TextStyle(color: Colors.white24, fontSize: 40)))
              : SingleChildScrollView(
                  child: Wrap(spacing: 14, runSpacing: 14, children: [
                    for (final label in items)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: big ? 22 : 16, vertical: big ? 14 : 10),
                        decoration: BoxDecoration(
                          color: big ? color : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('$label',
                            style: TextStyle(
                              color: big ? const Color(0xFF0B1A0D) : Colors.white,
                              fontSize: big ? 44 : 30,
                              fontWeight: FontWeight.w800,
                            )),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }
}
