import 'package:intl/intl.dart';

final _idr = NumberFormat.decimalPattern('id_ID');

String rupiah(num? n) => 'Rp ${_idr.format((n ?? 0).round())}';

String number(num? n) => _idr.format(n ?? 0);

/// Ringkas untuk sumbu grafik: 1,2 jt / 350 rb.
String compactRupiah(num n) {
  if (n.abs() >= 1e9) return '${(n / 1e9).toStringAsFixed(1).replaceAll('.', ',')} M';
  if (n.abs() >= 1e6) return '${(n / 1e6).toStringAsFixed(1).replaceAll('.', ',')} jt';
  if (n.abs() >= 1e3) return '${(n / 1e3).round()} rb';
  return n.round().toString();
}

DateTime? parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v.toLocal();
  return DateTime.tryParse(v.toString())?.toLocal();
}

String fmtDate(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('d MMM yyyy', 'id_ID').format(d);
}

String fmtDateTime(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('d MMM yyyy, HH:mm', 'id_ID').format(d);
}

String fmtTime(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('HH:mm', 'id_ID').format(d);
}

String fmtDayShort(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('d/M', 'id_ID').format(d);
}

String ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String fileSize(num bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}

int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
