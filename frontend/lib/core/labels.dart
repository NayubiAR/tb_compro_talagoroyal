import 'package:flutter/material.dart';

import 'theme.dart';

class StatusInfo {
  const StatusInfo(this.label, this.tone, this.icon);
  final String label;
  final Tone tone;
  final IconData icon;
}

const _unknown = StatusInfo('-', Tone.neutral, Icons.help_outline);

const orderStatus = {
  'SUBMITTED': StatusInfo('Menunggu Verifikasi', Tone.warning, Icons.hourglass_top),
  'APPROVED': StatusInfo('Disetujui', Tone.info, Icons.verified_outlined),
  'READY': StatusInfo('Siap Diambil', Tone.good, Icons.inventory_2_outlined),
  'COMPLETED': StatusInfo('Selesai', Tone.good, Icons.check_circle_outline),
  'REJECTED': StatusInfo('Ditolak', Tone.critical, Icons.block),
  'CANCELLED': StatusInfo('Dibatalkan', Tone.neutral, Icons.cancel_outlined),
};

const invoiceStatus = {
  'UNPAID': StatusInfo('Belum Lunas', Tone.warning, Icons.schedule),
  'PARTIAL': StatusInfo('Dibayar Sebagian', Tone.info, Icons.timelapse),
  'PAID': StatusInfo('Lunas', Tone.good, Icons.check_circle_outline),
  'OVERDUE': StatusInfo('Jatuh Tempo', Tone.critical, Icons.error_outline),
  'VOID': StatusInfo('Dibatalkan', Tone.neutral, Icons.cancel_outlined),
};

const printStatus = {
  'DRAFT': StatusInfo('Draf', Tone.neutral, Icons.edit_note),
  'AWAITING_PAYMENT': StatusInfo('Menunggu Pembayaran', Tone.warning, Icons.qr_code_2),
  'QUEUED': StatusInfo('Menunggu', Tone.info, Icons.hourglass_top),
  'PRINTING': StatusInfo('Sedang Dicetak', Tone.serious, Icons.print),
  'READY': StatusInfo('Siap Diambil', Tone.good, Icons.inventory_2_outlined),
  'COMPLETED': StatusInfo('Selesai', Tone.neutral, Icons.check_circle_outline),
  'CANCELLED': StatusInfo('Dibatalkan', Tone.neutral, Icons.cancel_outlined),
  'EXPIRED': StatusInfo('Kedaluwarsa', Tone.critical, Icons.timer_off_outlined),
};

const stockStatus = {
  'OK': StatusInfo('Aman', Tone.good, Icons.check_circle_outline),
  'LOW': StatusInfo('Menipis', Tone.serious, Icons.warning_amber),
  'OUT': StatusInfo('Habis', Tone.critical, Icons.error_outline),
};

const restockLevel = {
  'HABIS': StatusInfo('Habis', Tone.critical, Icons.error_outline),
  'KRITIS': StatusInfo('Kritis', Tone.serious, Icons.warning_amber),
  'WASPADA': StatusInfo('Waspada', Tone.warning, Icons.trending_down),
};

const partnerStatus = {
  'PENDING': StatusInfo('Menunggu Verifikasi', Tone.warning, Icons.hourglass_top),
  'VERIFIED': StatusInfo('Terverifikasi', Tone.good, Icons.verified_outlined),
  'REJECTED': StatusInfo('Ditolak', Tone.critical, Icons.block),
  'SUSPENDED': StatusInfo('Ditangguhkan', Tone.neutral, Icons.pause_circle_outline),
};

const availability = {
  'TERSEDIA': StatusInfo('Tersedia', Tone.good, Icons.check_circle_outline),
  'TERBATAS': StatusInfo('Terbatas', Tone.serious, Icons.warning_amber),
  'HABIS': StatusInfo('Habis', Tone.critical, Icons.error_outline),
};

const movementType = {
  'RECEIPT': StatusInfo('Penerimaan', Tone.good, Icons.move_to_inbox),
  'SALE': StatusInfo('Penjualan Kasir', Tone.info, Icons.point_of_sale),
  'B2B_ORDER': StatusInfo('Pesanan B2B', Tone.info, Icons.business),
  'ADJUSTMENT': StatusInfo('Penyesuaian', Tone.warning, Icons.tune),
  'RETURN': StatusInfo('Retur', Tone.good, Icons.undo),
};

StatusInfo statusOf(Map<String, StatusInfo> map, dynamic key) => map[key] ?? _unknown;

const paymentMethodLabel = {'CASH': 'Tunai', 'QRIS': 'QRIS', 'TRANSFER': 'Transfer Bank'};
const colorModeLabel = {'BW': 'Hitam-Putih', 'COLOR': 'Berwarna'};
const orientationLabel = {'PORTRAIT': 'Potret', 'LANDSCAPE': 'Lanskap'};
const bindingLabel = {'NONE': 'Tanpa Jilid', 'LAKBAN': 'Jilid Lakban', 'SPIRAL': 'Jilid Spiral'};
const roleLabel = {'OWNER': 'Pemilik Toko', 'ADMIN': 'Staf Toko', 'B2B': 'Mitra B2B', 'CUSTOMER': 'Pelanggan'};
const institutionTypeLabel = {
  'SEKOLAH': 'Sekolah',
  'KANTOR': 'Kantor',
  'INSTANSI': 'Instansi Pemerintah',
  'PERUSAHAAN': 'Perusahaan',
  'LAINNYA': 'Lainnya',
};

/// Ringkasan konfigurasi cetak: "A4 · Berwarna · 2 rangkap · Bolak-balik · Jilid Spiral".
String printConfigSummary(Map<String, dynamic> cfg) {
  final parts = <String>[
    '${cfg['paperSize']}',
    colorModeLabel[cfg['colorMode']] ?? '',
    if (cfg['orientation'] == 'LANDSCAPE') 'Lanskap',
    '${cfg['copies']} rangkap',
    if (cfg['duplex'] == true) 'Bolak-balik',
    if (cfg['binding'] != null && cfg['binding'] != 'NONE') bindingLabel[cfg['binding']]!,
    if (cfg['pageRange'] != null) 'Hal. ${cfg['pageRange']}',
  ];
  return parts.where((p) => p.isNotEmpty).join(' · ');
}
