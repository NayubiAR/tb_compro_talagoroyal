# Talago Royal — Sistem Informasi Terintegrasi Toko ATK

Implementasi proposal Computing Project **Talago Royal** (Telkom University, 2025/2026): satu aplikasi web dengan tiga modul.

| Modul | Isi |
|---|---|
| **Inventaris Cerdas** | Hierarki multi-satuan dinamis (1 Dus = 5 Pak = 60 Pcs), konversi & pemotongan stok otomatis, Smart Restock Alert berbasis kecepatan jual, penerimaan barang, stock opname, ledger mutasi, valuasi aset |
| **Portal B2B** | Pendaftaran & verifikasi mitra, katalog tertutup + harga tiering, Quick PO bergaya spreadsheet (tempel dari Excel), faktur PDF otomatis, pelacakan piutang (Lunas / Jatuh Tempo) |
| **Cloud Printing** | Unggah PDF/Word, hitung halaman otomatis, konfigurasi cetak + kalkulasi biaya, pembayaran QRIS (Midtrans), antrean real-time (Redis Pub/Sub → WebSocket), layar monitor antrean |

Dokumentasi arsitektur, keputusan desain, dan saran pengembangan: **[docs/ARSITEKTUR.md](docs/ARSITEKTUR.md)**.

## Struktur repositori

```
backend/    Node.js + Express 5 + Prisma (MySQL/PostgreSQL) + Socket.IO + Redis
frontend/   Flutter Web (go_router, provider, dio, socket_io_client, fl_chart)
docs/       Dokumen arsitektur
```

## Prasyarat

- Node.js **≥ 22.9** (diuji dengan 24.x)
- Flutter **3.3x+** (diuji dengan 3.44, Dart 3.12)
- MySQL 8 (mis. bawaan **Laragon**) — atau PostgreSQL (lihat docs)
- Redis 5+ (bawaan Laragon) — *opsional*, tanpa Redis event bus otomatis memakai mode memori

> Belum punya Laragon? `docker compose up -d` di root repo menjalankan MySQL (port 3316) & Redis.

## Menjalankan secara lokal

### 1. Backend

```bash
cd backend
cp .env.example .env          # sesuaikan DATABASE_URL, JWT_SECRET, dsb.
npm install
npx prisma migrate dev        # membuat database & tabel, lalu otomatis menjalankan seed
npm run dev                   # http://localhost:4000  (cek: /api/health)
```

`npm run db:seed` dapat dijalankan ulang kapan saja untuk **mereset** data demo (menghapus semua data!).
Seed membuat 1.020 SKU multi-satuan, riwayat transaksi 30 hari, PO & faktur berbagai status, antrean cetak aktif, serta berkas sampel uji di `backend/samples/`.

### 2. Frontend

```bash
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:4000
```

Build produksi: `flutter build web --release --dart-define=API_BASE_URL=https://api.domain-anda.id`.
Alternatif satu server: isi `WEB_DIR=../frontend/build/web` di `.env` backend — backend akan menyajikan aplikasi web sekaligus API (tanpa `API_BASE_URL`).

### Akun demo (password semua: `password123`)

| Email | Peran | Untuk mencoba |
|---|---|---|
| `owner@talago.test` | Pemilik Toko | Semua menu + laporan, pengaturan, pengguna |
| `admin@talago.test` / `kasir@talago.test` | Staf Toko | Kasir, antrean cetak, inventaris, verifikasi PO |
| `mitra@talago.test` | Mitra B2B (Gold, terverifikasi) | Katalog, Quick PO, faktur (ada yang jatuh tempo) |
| `mitra2@talago.test` | Mitra B2B (Silver) | Faktur dibayar sebagian |
| `mitra3@talago.test` | Mitra B2B (menunggu verifikasi) | Alur verifikasi mitra |
| `pelanggan@talago.test` | Pelanggan umum | Cloud printing, pesanan siap diambil |

Layar monitor antrean untuk TV toko: `/#/antrean` (tanpa login).

## Pembayaran QRIS

- **Default `PAYMENT_PROVIDER=mock`**: QR contoh + tombol *"Simulasikan pembayaran"* — cocok untuk demo, UAT, dan pengembangan. Jalur pemrosesannya sama persis dengan webhook asli.
- **Midtrans sandbox**: isi `PAYMENT_PROVIDER=midtrans` dan `MIDTRANS_SERVER_KEY=SB-Mid-server-...`. Atur *Payment Notification URL* di dashboard Midtrans ke `{PUBLIC_BASE_URL}/api/payments/midtrans/notification`. Untuk server lokal gunakan `ngrok http 4000` (ngrok tersedia di Laragon). Tanpa webhook pun pembayaran tetap terdeteksi lewat tombol *Cek status* dan polling otomatis.

## Pengujian

```bash
cd backend
npm test            # 15 unit test logika inti (konversi satuan, tiering, tarif cetak, signature Midtrans)
npm run smoke       # 17 skenario end-to-end (HTTP + WebSocket + Redis) — jalankan setelah `npm run db:seed` dan saat server hidup

cd frontend
flutter analyze
```

Catatan: login yang **gagal** dibatasi 20 kali / 15 menit per IP (anti brute-force).

## Konfigurasi penting (`backend/.env`)

| Variabel | Keterangan |
|---|---|
| `DATABASE_URL` | `mysql://root:@127.0.0.1:3316/talago_royal` (Laragon) |
| `JWT_SECRET` | wajib, ≥ 32 karakter acak di production |
| `REDIS_URL` | kosongkan untuk mode memori (1 instance) |
| `PAYMENT_PROVIDER` | `mock` / `midtrans` |
| `SOFFICE_PATH` | path `soffice` LibreOffice untuk konversi .doc/.docx → PDF (lebih akurat). Tanpa ini .docx memakai metadata halaman, .doc ditolak |
| `FILE_RETENTION_DAYS` | berkas pelanggan dihapus otomatis setelah N hari pesanan selesai |
| `WEB_DIR` | opsional, sajikan build Flutter dari backend |
