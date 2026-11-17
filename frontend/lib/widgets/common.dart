import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/labels.dart';
import '../core/socket_service.dart';
import '../core/theme.dart';
import '../state/auth_state.dart';

extension AppContext on BuildContext {
  ApiClient get api => read<ApiClient>();
  AuthState get auth => read<AuthState>();
  SocketService get socket => read<SocketService>();
  bool get isWide => MediaQuery.sizeOf(this).width >= 900;
}

// ───────────── Feedback ─────────────

void showSnack(BuildContext context, String message, {bool error = false, SnackBarAction? action}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? scheme.error : null,
      action: action,
      duration: Duration(seconds: error ? 6 : 3),
    ));
}

void showError(BuildContext context, Object e) =>
    showSnack(context, e is ApiException ? e.fullMessage : e.toString(), error: true);

/// Jalankan aksi async; tampilkan error sebagai snackbar dan pesan sukses opsional.
Future<T?> guard<T>(BuildContext context, Future<T> Function() action, {String? success}) async {
  try {
    final result = await action();
    if (success != null && context.mounted) showSnack(context, success);
    return result;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Ya, lanjutkan',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  String initial = '',
  int minLength = 0,
  int maxLines = 1,
  String confirmLabel = 'Simpan',
}) {
  final ctrl = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            maxLines: maxLines,
            decoration: InputDecoration(labelText: label, hintText: hint),
            validator: (v) => (v ?? '').trim().length < minLength ? 'Minimal $minLength karakter' : null,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Navigator.pop(ctx, ctrl.text.trim());
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

// ───────────── Pemuatan data ─────────────

/// Pola standar halaman: implementasikan [load], panggil [reload], bungkus isi dengan [loadedBody].
mixin LoaderMixin<W extends StatefulWidget> on State<W> {
  bool loading = true;
  Object? loadError;
  bool _loadedOnce = false;

  Future<void> load();

  Future<void> reload({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        loading = true;
        loadError = null;
      });
    }
    try {
      await load();
      loadError = null;
      _loadedOnce = true;
    } catch (e) {
      loadError = e;
      if (_loadedOnce && mounted) showError(context, e);
    }
    if (mounted) setState(() => loading = false);
  }

  Widget loadedBody(Widget Function() builder) {
    if (!_loadedOnce && loading) return const LoadingView();
    if (!_loadedOnce && loadError != null) return ErrorView(error: loadError!, onRetry: reload);
    return Stack(
      children: [
        builder(),
        if (loading) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
      ],
    );
  }
}

/// Muat ulang halaman otomatis ketika event real-time tertentu diterima (di-debounce).
mixin RealtimeMixin<W extends StatefulWidget> on State<W> {
  final _subs = <StreamSubscription<RealtimeEvent>>[];
  Timer? _debounce;

  void listenRealtime(List<String> events, VoidCallback onEvent, {bool Function(dynamic data)? where}) {
    final sub = context.read<SocketService>().events.where((e) => events.contains(e.name)).listen((e) {
      if (where != null && !where(e.data)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) onEvent();
      });
    });
    _subs.add(sub);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _debounce?.cancel();
    super.dispose();
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()));
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text(error is ApiException ? (error as ApiException).fullMessage : '$error', textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Coba lagi')),
          ],
        ]),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message, this.action});
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: muted),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center, style: TextStyle(color: muted)),
        if (action != null) ...[const SizedBox(height: 14), action!],
      ]),
    );
  }
}

// ───────────── Tata letak ─────────────

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1400});
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final pad = context.isWide ? 24.0 : 16.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(subtitle!, style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
          ]),
          if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.subtitle, this.trailing, required this.child, this.padding = const EdgeInsets.all(16)});
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (subtitle != null)
                    Text(subtitle!, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
              ?trailing,
            ]),
          ),
        Padding(padding: padding, child: child),
      ]),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.icon, this.caption, this.tone, this.onTap});
  final String label;
  final String value;
  final IconData icon;
  final String? caption;
  final Tone? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone == null ? scheme.primary : toneColor(context, tone!);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (caption != null) ...[
                  const SizedBox(height: 4),
                  Text(caption!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Grid kartu responsif (1–4 kolom tergantung lebar).
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minItemWidth = 240, this.spacing = 16});
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minItemWidth).floor().clamp(1, children.length.clamp(1, 6));
      final width = (c.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final child in children) SizedBox(width: width, child: child)],
      );
    });
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.info, {super.key, this.dense = false});
  final StatusInfo info;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(context, info.tone);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(info.icon, size: dense ? 13 : 15, color: color),
        const SizedBox(width: 4),
        Text(info.label, style: TextStyle(fontSize: dense ? 11.5 : 12.5, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}

/// DataTable yang bisa digulir horizontal di layar sempit.
class ScrollTable extends StatelessWidget {
  const ScrollTable({super.key, required this.columns, required this.rows, this.minWidth = 760, this.showCheckboxColumn = false});
  final List<DataColumn> columns;
  final List<DataRow> rows;
  final double minWidth;
  final bool showCheckboxColumn;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: c.maxWidth < minWidth ? minWidth : c.maxWidth),
          child: DataTable(columns: columns, rows: rows, showCheckboxColumn: showCheckboxColumn),
        ),
      );
    });
  }
}

class Paginator extends StatelessWidget {
  const Paginator({super.key, required this.meta, required this.onPage});
  final Map<String, dynamic>? meta;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    if (meta == null) return const SizedBox.shrink();
    final page = meta!['page'] as int;
    final pages = meta!['totalPages'] as int;
    final total = meta!['total'];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Text('$total data · Halaman $page dari $pages', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Sebelumnya',
          onPressed: page > 1 ? () => onPage(page - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: 'Berikutnya',
          onPressed: page < pages ? () => onPage(page + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ]),
    );
  }
}

class SearchBox extends StatefulWidget {
  const SearchBox({super.key, required this.onChanged, this.hint = 'Cari...', this.initial = '', this.width = 320, this.autofocus = false});
  final ValueChanged<String> onChanged;
  final String hint;
  final String initial;
  final double width;
  final bool autofocus;

  @override
  State<SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<SearchBox> {
  late final _ctrl = TextEditingController(text: widget.initial);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _ctrl,
        autofocus: widget.autofocus,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _ctrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _ctrl.clear();
                    widget.onChanged('');
                    setState(() {});
                  },
                ),
        ),
        onChanged: (v) {
          setState(() {});
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), () => widget.onChanged(v.trim()));
        },
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.bold = false, this.labelWidth = 150});
  final String label;
  final String value;
  final bool bold;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: labelWidth, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child: Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500))),
      ]),
    );
  }
}

/// Baris total (label kiri, nilai kanan) untuk ringkasan harga.
class TotalRow extends StatelessWidget {
  const TotalRow(this.label, this.value, {super.key, this.emphasis = false, this.color});
  final String label;
  final String value;
  final bool emphasis;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: emphasis ? 17 : 14, fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
    );
  }
}

/// Dialog lebar responsif (full-screen di layar sempit).
Future<T?> showWideDialog<T>(BuildContext context, {required WidgetBuilder builder, double maxWidth = 860}) {
  final narrow = MediaQuery.sizeOf(context).width < 700;
  return showDialog<T>(
    context: context,
    builder: (ctx) => narrow
        ? Dialog.fullscreen(child: builder(ctx))
        : Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: MediaQuery.sizeOf(ctx).height * 0.9),
              child: builder(ctx),
            ),
          ),
  );
}

/// Kerangka isi dialog: judul + tombol tutup, konten bergulir, aksi di bawah.
class DialogFrame extends StatelessWidget {
  const DialogFrame({super.key, required this.title, required this.child, this.actions = const [], this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              if (subtitle != null) Text(subtitle!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close), tooltip: 'Tutup'),
        ]),
      ),
      const Divider(height: 1),
      Flexible(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: child)),
      if (actions.isNotEmpty) ...[
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
        ),
      ],
    ]);
  }
}
