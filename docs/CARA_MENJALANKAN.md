# Panduan Menjalankan Talago Royal

Panduan untuk seluruh anggota tim. Ada dua cara:

| Cara | Cocok untuk | Yang perlu dipasang |
|---|---|---|
| **A. Docker** (disarankan) | Mencoba aplikasi, UAT, demo, presentasi, QA | Docker Desktop + Git saja |
| **B. Manual** | Mengembangkan kode (hot reload) | Node.js 24, Flutter 3.44.1, MySQL & Redis (Laragon) |

---

## A. Menjalankan dengan Docker

### 1. Pasang Docker Desktop (sekali saja)
1. Unduh di <https://www.docker.com/products/docker-desktop/> dan pasang.
2. Windows: saat diminta, aktifkan **WSL 2** lalu restart laptop.
3. Buka Docker Desktop dan tunggu sampai statusnya **Engine running** (ikon paus di taskbar tidak bergerak).

Minimal RAM 8 GB; sisakan ±10 GB ruang disk untuk build pertama.

### 2. Ambil kode
```bash
git clone https://github.com/NayubiAR/tb_compro_talagoroyal.git
cd tb_compro_talagoroyal
```

### 3. Jalankan
```bash
docker compose up -d --build
```
- Build **pertama** butuh ±10–15 menit (mengunduh Node, Flutter SDK, MySQL). Berikutnya hanya hitungan detik–menit.
- Saat database masih kosong, data demo terisi otomatis (1.020 SKU, transaksi 30 hari, PO, faktur, antrean cetak).

Buka **<http://localhost:8080>**. Cek status semua layanan:
```bash
docker compose ps        # keempat layanan harus "healthy"
```

### 4. Akun demo (password semua: `password123`)
| Email | Peran |
|---|---|
| `owner@talago.test` | Pemilik Toko (semua menu) |
| `admin@talago.test`, `kasir@talago.test` | Staf toko / kasir |
| `mitra@talago.test` | Mitra B2B terverifikasi (Gold) |
| `mitra2@talago.test` | Mitra B2B (Silver) |
| `mitra3@talago.test` | Mitra B2B menunggu verifikasi |
| `pelanggan@talago.test` | Pelanggan cloud printing |

Layar monitor antrean untuk TV toko: <http://localhost:8080/#/antrean>.

### 5. Perintah sehari-hari
| Kebutuhan | Perintah |
|---|---|
| Menyalakan lagi setelah laptop restart | `docker compose up -d` |
| Mematikan (data tetap aman) | `docker compose down` |
| Setelah `git pull` (ada kode baru) | `docker compose up -d --build` |
| Melihat log backend | `docker compose logs -f backend` |
| **Reset data demo** ke kondisi awal | `docker compose exec -e FORCE_SEED=true backend node prisma/seed.js` |
| Hapus total termasuk database & berkas | `docker compose down -v` |
| Membuka database (HeidiSQL/DBeaver) | host `127.0.0.1`, port `3317`, user `root`, password `talago_root`, database `talago_royal` |

### 6. Konfigurasi (opsional)
Semua pengaturan punya nilai bawaan. Untuk mengubahnya, salin `.env.example` menjadi `.env` di folder root lalu edit, contohnya:
- `APP_PORT=9000` jika port 8080 sudah dipakai aplikasi lain.
- `PAYMENT_PROVIDER=midtrans` + `MIDTRANS_SERVER_KEY=SB-Mid-server-...` untuk QRIS Midtrans sandbox.
- `WITH_LIBREOFFICE=true` agar berkas `.doc`/`.docx` dikonversi ke PDF (hitung halaman akurat; image lebih besar ±600 MB).

Setelah mengubah `.env`, jalankan `docker compose up -d --build` lagi.

### 7. Masalah umum
| Gejala | Solusi |
|---|---|
| `failed to connect to the docker API` / `cannot find the file specified` | Docker Desktop belum menyala. Buka Docker Desktop, tunggu *Engine running*. |
| `port is already allocated` | Port 8080/3317/6380 dipakai aplikasi lain → ubah `APP_PORT`/`MYSQL_PORT`/`REDIS_PORT` di `.env`. |
| Halaman blank / masih versi lama setelah update | Tekan **Ctrl+Shift+R** (hard refresh) di browser. |
| Backend `unhealthy` | Lihat `docker compose logs backend`. Biasanya database belum siap — tunggu 1 menit lalu `docker compose up -d`. |
| Build gagal karena internet putus | Ulangi `docker compose up -d --build`; bagian yang sudah terunduh disimpan di cache. |
| Login ditolak "Terlalu banyak percobaan" | 20 kali login gagal dalam 15 menit memicu blokir sementara. Tunggu atau `docker compose restart backend`. |

---

## B. Menjalankan manual (untuk pengembangan)

Gunakan cara ini saat mengubah kode supaya ada hot reload.

### 1. Database & Redis
Pilih salah satu:
- **Laragon**: nyalakan MySQL & Redis. Sesuaikan port MySQL Laragon Anda (default 3306).
- **Docker** (tanpa Laragon): `docker compose up -d mysql redis` → MySQL di port **3317** (password `talago_root`), Redis di port **6380**.

### 2. Backend
```bash
cd backend
cp .env.example .env
```
Edit `DATABASE_URL` & `REDIS_URL` di `.env` sesuai pilihan di atas, contoh untuk Docker:
```
DATABASE_URL=mysql://root:talago_root@127.0.0.1:3317/talago_royal
REDIS_URL=redis://127.0.0.1:6380
```
Lalu:
```bash
npm install
npx prisma migrate dev     # buat tabel + isi data demo
npm run dev                # http://localhost:4000 (auto-restart saat file berubah)
```

### 3. Frontend
Pastikan versi Flutter **3.44.1** (`flutter --version`), sama dengan CI.
```bash
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:4000
```

### 4. Sebelum push
```bash
cd backend && npm test                    # unit test
cd frontend && flutter analyze            # tidak boleh ada error/warning
```
Smoke test end-to-end (opsional, saat backend menyala dan data baru di-seed): `npm run db:seed && npm run smoke`.

---

## C. Alur kerja Git tim

1. Buat branch per fitur: `git checkout -b fitur/quick-po-export`.
2. Commit kecil-kecil dengan pesan jelas, lalu `git push -u origin fitur/quick-po-export`.
3. Buka **Pull Request** ke `main` di GitHub → CI berjalan otomatis.
4. Merge hanya jika CI hijau dan sudah direview minimal 1 anggota.

Disarankan mengaktifkan *Settings → Branches → Branch protection* untuk `main`: wajib PR + status check CI lulus.

---

## D. CI/CD (GitHub Actions)

File: `.github/workflows/ci-cd.yml`. Lihat hasilnya di tab **Actions** repo.

| Job | Kapan | Isi |
|---|---|---|
| Backend · unit test | setiap push & PR | `npm ci`, validasi skema Prisma, 15 unit test |
| Frontend · analyze | setiap push & PR | `flutter analyze` dengan Flutter 3.44.1 |
| Docker · smoke test end-to-end | setiap push & PR | Build kedua image, jalankan stack Docker lengkap, lalu 17 skenario uji lewat Nginx (HTTP + WebSocket + Redis) |
| Publish image | push ke `main` / tag `v*` | Push image ke `ghcr.io/<pemilik>/<repo>/backend` & `/frontend` dengan tag `latest`, `sha-xxxxxxx`, dan versi |
| Deploy ke server | push ke `main`, **hanya jika `DEPLOY_HOST` diisi** | SSH ke server → tarik image baru → restart kontainer |

Rilis versi (untuk sidang/milestone): `git tag v1.0.0 && git push origin v1.0.0` → image bertag `1.0.0`.

### Mengaktifkan deploy otomatis (minggu 15)
1. **Siapkan server** Linux (VPS Ubuntu 22.04+, minimal 2 GB RAM) dengan Docker:
   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker $USER      # login ulang setelahnya
   mkdir -p ~/talago-royal
   ```
2. **Buat `~/talago-royal/.env` di server** (salin dari `.env.example`) dan ubah minimal:
   ```
   APP_PORT=80
   JWT_SECRET=<hasil: openssl rand -hex 32>
   MYSQL_ROOT_PASSWORD=<password kuat>
   PUBLIC_BASE_URL=https://domain-anda
   SEED_IF_EMPTY=false          # true jika ingin data demo di server demo
   PAYMENT_PROVIDER=midtrans
   MIDTRANS_SERVER_KEY=...
   ```
   Untuk keamanan, di server sebaiknya port MySQL/Redis tidak dibuka ke internet (blokir 3317 & 6380 dengan firewall, mis. `ufw`).
3. **Buat SSH key khusus deploy** di laptop: `ssh-keygen -t ed25519 -f deploy_key -N ""`. Tambahkan isi `deploy_key.pub` ke `~/.ssh/authorized_keys` di server.
4. **Di GitHub repo → Settings → Secrets and variables → Actions**:
   - *Secrets*: `DEPLOY_SSH_KEY` = isi file `deploy_key` (private key).
   - *Variables*: `DEPLOY_HOST` (IP/domain server), `DEPLOY_USER` (user SSH), opsional `DEPLOY_PATH` (default `~/talago-royal`) dan `DEPLOY_PORT` (default 22).
5. Push ke `main` → job **Deploy ke server** berjalan. Aplikasi tersedia di `http://IP-server`.
6. HTTPS: pasang domain di Cloudflare (proxy aktif) atau pasang Caddy/Nginx + Let's Encrypt di depan port aplikasi.

Catatan: image di GHCR bersifat privat mengikuti repo; server login memakai token sementara dari GitHub Actions saat deploy. Jika ingin menarik image secara manual di server, buat *Personal Access Token* (scope `read:packages`) lalu `docker login ghcr.io`.

---

## E. Ringkasan arsitektur kontainer

```
Browser ──► frontend (Nginx :8080) ──► /            Flutter Web
                                  ├──► /api/*       ─┐
                                  └──► /socket.io/* ─┴─► backend (Node.js :4000) ──► mysql (data)
                                                                                └──► redis (Pub/Sub real-time)
Volume: mysql-data (database), uploads (berkas cetak pelanggan)
```

Detail arsitektur aplikasi: [ARSITEKTUR.md](ARSITEKTUR.md).
