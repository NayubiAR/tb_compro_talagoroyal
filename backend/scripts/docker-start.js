// Entrypoint kontainer backend:
//   1. menunggu database siap lalu menjalankan migrasi (prisma migrate deploy)
//   2. jika SEED_IF_EMPTY=true dan belum ada pengguna → isi data demo (tidak pernah menimpa data yang ada)
//   3. menjalankan server
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const PRISMA = './node_modules/.bin/prisma';

function migrate() {
  for (let attempt = 1; attempt <= 10; attempt++) {
    const r = spawnSync(PRISMA, ['migrate', 'deploy'], { stdio: 'inherit' });
    if (r.status === 0) return;
    console.warn(`[start] migrasi gagal (percobaan ${attempt}/10), mencoba lagi dalam 3 detik...`);
    spawnSync(process.execPath, ['-e', 'setTimeout(()=>{},3000)']);
  }
  console.error('[start] migrasi database gagal, kontainer berhenti');
  process.exit(1);
}

console.log('[start] menjalankan migrasi database...');
migrate();

// LibreOffice terpasang (build arg WITH_LIBREOFFICE=true) → aktifkan konversi Word → PDF otomatis.
if (!process.env.SOFFICE_PATH && fs.existsSync('/usr/bin/soffice')) {
  process.env.SOFFICE_PATH = '/usr/bin/soffice';
  console.log('[start] LibreOffice terdeteksi, konversi .doc/.docx → PDF aktif');
}

if (process.env.SEED_IF_EMPTY === 'true') {
  const { PrismaClient } = await import('@prisma/client');
  const prisma = new PrismaClient();
  const users = await prisma.user.count();
  await prisma.$disconnect();
  if (users === 0) {
    console.log('[start] database masih kosong → mengisi data demo (npm run db:seed)...');
    const r = spawnSync(process.execPath, ['prisma/seed.js'], {
      stdio: 'inherit',
      env: { ...process.env, FORCE_SEED: 'true' },
    });
    if (r.status !== 0) process.exit(r.status ?? 1);
  } else {
    console.log(`[start] database sudah berisi ${users} pengguna, seed dilewati`);
  }
}

await import('../src/server.js');
