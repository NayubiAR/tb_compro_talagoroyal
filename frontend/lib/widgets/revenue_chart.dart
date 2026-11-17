import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';

const _channels = [('retail', 'Eceran (Kasir)'), ('b2b', 'B2B'), ('print', 'Cetak')];

double niceStep(double max, {int ticks = 4}) {
  if (max <= 0) return 1;
  final raw = max / ticks;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final n = raw / mag;
  final step = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
  return step * mag;
}

/// Grafik batang bertumpuk omzet harian per kanal (Eceran, B2B, Cetak).
/// Legend selalu tampil, tooltip saat hover, dan tersedia tampilan tabel (aksesibilitas).
class RevenueChart extends StatefulWidget {
  const RevenueChart({super.key, required this.series, this.height = 260});
  final List<dynamic> series;
  final double height;

  @override
  State<RevenueChart> createState() => _RevenueChartState();
}

class _RevenueChartState extends State<RevenueChart> {
  bool table = false;

  @override
  Widget build(BuildContext context) {
    final colors = ChartPalette.series(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Wrap(spacing: 16, runSpacing: 4, children: [
            for (var i = 0; i < _channels.length; i++)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: colors[i], borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 6),
                Text(_channels[i].$2, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ]),
          ]),
        ),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.bar_chart, size: 18), tooltip: 'Grafik'),
            ButtonSegment(value: true, icon: Icon(Icons.table_rows_outlined, size: 18), tooltip: 'Tabel'),
          ],
          selected: {table},
          onSelectionChanged: (s) => setState(() => table = s.first),
        ),
      ]),
      const SizedBox(height: 12),
      SizedBox(height: widget.height, child: table ? _table(context) : _chart(context, colors)),
    ]);
  }

  Widget _chart(BuildContext context, List<Color> colors) {
    final scheme = Theme.of(context).colorScheme;
    final rows = widget.series;
    final maxTotal = rows.fold<double>(0, (m, r) => math.max(m, (r['total'] as num).toDouble()));
    final step = niceStep(maxTotal);
    final maxY = maxTotal <= 0 ? step * 4 : (maxTotal / step).ceil() * step;
    final barWidth = rows.length <= 16 ? 18.0 : rows.length <= 31 ? 10.0 : 6.0;
    final labelEvery = (rows.length / 8).ceil().clamp(1, 100);
    final muted = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);

    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: step,
          getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              interval: step,
              getTitlesWidget: (v, meta) => SideTitleWidget(meta: meta, child: Text(compactRupiah(v), style: muted)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= rows.length || (i % labelEvery != 0 && i != rows.length - 1)) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(meta: meta, child: Text(fmtDayShort(rows[i]['date']), style: muted));
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItem: (group, _, rod, _) {
              final r = rows[group.x];
              final style = TextStyle(color: scheme.onInverseSurface, fontSize: 12);
              return BarTooltipItem(
                '${fmtDate(r['date'])}\n',
                style.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.left,
                children: [
                  for (final c in _channels) TextSpan(text: '${c.$2}: ${rupiah(r[c.$1])}\n', style: style),
                  TextSpan(text: 'Total: ${rupiah(r['total'])}', style: style.copyWith(fontWeight: FontWeight.w700)),
                ],
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < rows.length; i++) _group(i, rows[i], colors, barWidth, scheme.surface),
        ],
      ),
    );
  }

  BarChartGroupData _group(int x, dynamic r, List<Color> colors, double width, Color surface) {
    double from = 0;
    final items = <BarChartRodStackItem>[];
    for (var i = 0; i < _channels.length; i++) {
      final v = (r[_channels[i].$1] as num).toDouble();
      if (v <= 0) continue;
      // Garis tepi warna permukaan = celah 2px antar segmen tumpukan.
      items.add(BarChartRodStackItem(from, from + v, colors[i], borderSide: BorderSide(color: surface, width: 1)));
      from += v;
    }
    return BarChartGroupData(x: x, barRods: [
      BarChartRodData(
        toY: from,
        width: width,
        rodStackItems: items,
        color: Colors.transparent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      ),
    ]);
  }

  Widget _table(BuildContext context) {
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 36,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 36,
          columns: const [
            DataColumn(label: Text('Tanggal')),
            DataColumn(label: Text('Eceran'), numeric: true),
            DataColumn(label: Text('B2B'), numeric: true),
            DataColumn(label: Text('Cetak'), numeric: true),
            DataColumn(label: Text('Total'), numeric: true),
          ],
          rows: [
            for (final r in widget.series.reversed)
              DataRow(cells: [
                DataCell(Text(fmtDate(r['date']))),
                DataCell(Text(rupiah(r['retail']))),
                DataCell(Text(rupiah(r['b2b']))),
                DataCell(Text(rupiah(r['print']))),
                DataCell(Text(rupiah(r['total']), style: const TextStyle(fontWeight: FontWeight.w700))),
              ]),
          ],
        ),
      ),
    );
  }
}

/// Daftar batang horizontal berlabel langsung (satu seri → satu warna, tanpa legend).
class BarList extends StatelessWidget {
  const BarList({super.key, required this.items, this.format = rupiah});
  final List<(String, num)> items;
  final String Function(num) format;

  @override
  Widget build(BuildContext context) {
    final max = items.fold<num>(0, (m, e) => math.max(m, e.$2));
    final color = ChartPalette.sequential(context);
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(children: [
      for (final (label, value) in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
              Text(format(value), style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max <= 0 ? 0 : value / max,
                minHeight: 8,
                color: color,
                backgroundColor: track,
              ),
            ),
          ]),
        ),
    ]);
  }
}
