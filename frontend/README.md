# Talago Royal — Frontend (Flutter Web)

```bash
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:4000
```

## Struktur

```
lib/
├── main.dart              bootstrap (locale id_ID, provider, sesi tersimpan)
├── router.dart            go_router + guard RBAC per peran
├── core/                  api_client (dio), socket_service (Socket.IO), format Rupiah/tanggal, tema, label status
├── state/                 auth_state (sesi & peran), po_draft (draf PO lintas halaman)
├── widgets/               app_shell (sidebar/drawer + notifikasi), komponen umum, grafik, pencarian produk
└── features/
    ├── auth/              login & registrasi (pelanggan / mitra)
    ├── admin/             dashboard, kasir, antrean cetak, inventaris, PO & faktur B2B, mitra, laporan, pengaturan, pengguna
    ├── b2b/               beranda mitra, katalog grosir, Quick PO, pesanan, faktur
    ├── print/             unggah & konfigurasi cetak, pembayaran QRIS, status pesanan
    ├── public/            layar monitor antrean (tanpa login)
    └── common/            notifikasi, profil
```

Pola halaman: `StatefulWidget` + `LoaderMixin` (muat data & error) + `RealtimeMixin` (muat ulang otomatis saat event WebSocket tertentu masuk).
