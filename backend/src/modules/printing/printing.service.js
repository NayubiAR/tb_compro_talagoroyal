import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { badRequest, conflict, notFound } from '../../lib/errors.js';
import { nextCode, nextSequence } from '../../lib/sequence.js';
import { ymd, startOfDay } from '../../lib/dates.js';
import { getSetting } from '../../lib/settings.js';
import { publish } from '../../lib/events.js';
import { notifyUser, audit } from '../../lib/notify.js';
import { paymentProvider } from '../payments/providers/index.js';
import { analyzeDocument } from './pagecount.js';
import { quotePrint } from './pricing.js';

export const printDir = () => path.join(env.uploadDir, 'print');
export const ACTIVE_QUEUE = ['QUEUED', 'PRINTING', 'READY'];
export const queueLabel = (n) => (n ? `C${String(n).padStart(3, '0')}` : null);
const withPayments = { payments: { orderBy: { id: 'desc' } } };

// ───────────── Serializer ─────────────

export function printJobDto(job, { forStaff = false } = {}) {
  const payment = job.payments?.[0];
  return {
    id: job.id,
    code: job.code,
    status: job.status,
    originalName: job.originalName,
    mimeType: job.mimeType,
    fileSize: job.fileSize,
    fileAvailable: !job.fileDeletedAt,
    pageCount: job.pageCount,
    pageCountNote: job.pageCountNote,
    pagesToPrint: job.pagesToPrint,
    config: {
      colorMode: job.colorMode,
      paperSize: job.paperSize,
      orientation: job.orientation,
      duplex: job.duplex,
      copies: job.copies,
      binding: job.binding,
      pageRange: job.pageRange,
      notes: job.notes,
    },
    pricing: {
      pricePerPage: job.pricePerPage,
      printCost: job.printCost,
      bindingCost: job.bindingCost,
      total: job.totalPrice,
    },
    queueNumber: job.queueNumber,
    queueLabel: queueLabel(job.queueNumber),
    queueDate: job.queueDate,
    // Kode ambil hanya untuk pelanggan; staf harus menanyakannya saat serah terima.
    pickupCode: forStaff ? undefined : job.pickupCode,
    createdAt: job.createdAt,
    paidAt: job.paidAt,
    startedAt: job.startedAt,
    readyAt: job.readyAt,
    completedAt: job.completedAt,
    cancelledAt: job.cancelledAt,
    customer:
      forStaff && job.customer
        ? { id: job.customer.id, name: job.customer.name, phone: job.customer.phone, email: job.customer.email }
        : undefined,
    payment: payment
      ? {
          orderId: payment.orderId,
          provider: payment.provider,
          method: payment.method,
          amount: payment.amount,
          status: payment.status,
          qrString: payment.status === 'PENDING' ? payment.qrString : null,
          qrUrl: payment.status === 'PENDING' ? payment.qrUrl : null,
          expiresAt: payment.expiresAt,
          paidAt: payment.paidAt,
        }
      : null,
  };
}

function publishJob(job) {
  const summary = {
    id: job.id,
    code: job.code,
    status: job.status,
    queueNumber: job.queueNumber,
    queueLabel: queueLabel(job.queueNumber),
  };
  publish('print.job.updated', summary, [`user:${job.customerId}`, 'staff']);
  publish('print.queue.updated', summary, ['public']);
}

// ───────────── Pelanggan ─────────────

/** Perbaiki nama berkas UTF-8 yang dibaca multer sebagai latin1. */
function decodeName(name) {
  const decoded = Buffer.from(name, 'latin1').toString('utf8');
  return decoded.includes('�') ? name : decoded;
}

export async function createDraft(user, file) {
  const originalName = decodeName(file.originalname).slice(0, 255);
  let analysis;
  try {
    analysis = await analyzeDocument(file.path, originalName, { sofficePath: env.sofficePath });
  } catch (err) {
    await fs.rm(file.path, { force: true });
    throw err;
  }
  let storedPath = file.path;
  let mimeType = file.mimetype;
  if (analysis.pdfPath) {
    // Simpan versi PDF hasil konversi: tata letak terkunci & jumlah halaman = yang ditagihkan.
    await fs.rm(file.path, { force: true });
    storedPath = analysis.pdfPath;
    mimeType = 'application/pdf';
  }
  const { size } = await fs.stat(storedPath);
  return prisma.$transaction(async (tx) => {
    const code = await nextCode(tx, 'PRN', { period: 'day' });
    return tx.printJob.create({
      data: {
        code,
        customerId: user.id,
        originalName,
        storedName: path.basename(storedPath),
        mimeType,
        fileSize: size,
        pageCount: analysis.pageCount,
        pageCountNote: analysis.method,
        pagesToPrint: analysis.pageCount,
      },
      include: withPayments,
    });
  });
}

export async function getOwnJob(user, id) {
  const job = await prisma.printJob.findUnique({ where: { id }, include: withPayments });
  if (!job || job.customerId !== user.id) throw notFound('Pesanan cetak tidak ditemukan');
  return job;
}

export async function quoteJob(job, cfg) {
  const pricing = await getSetting('print_pricing');
  return quotePrint(cfg, job.pageCount, pricing);
}

export async function checkout(user, jobId, cfg) {
  const job = await getOwnJob(user, jobId);
  const now = new Date();
  if (job.status === 'AWAITING_PAYMENT') {
    if (job.payments.some((p) => p.status === 'PENDING' && p.expiresAt > now)) {
      throw conflict('Pesanan ini masih menunggu pembayaran. Selesaikan atau batalkan pembayaran sebelumnya.');
    }
  } else if (!['DRAFT', 'EXPIRED'].includes(job.status)) {
    throw conflict('Pesanan ini sudah diproses dan tidak dapat diubah');
  }
  if (job.fileDeletedAt) throw conflict('Berkas sudah dihapus dari server, silakan unggah ulang');

  const q = await quoteJob(job, cfg);
  if (q.total <= 0) throw badRequest('Total biaya tidak valid');
  const expiryMinutes = env.payment.expiryMinutes;
  const orderId = `${job.code}-${job.payments.length + 1}-${Date.now().toString(36).toUpperCase()}`;
  const charge = await paymentProvider.createQris({
    orderId,
    amount: q.total,
    expiryMinutes,
    customer: user,
    itemName: `Jasa cetak ${job.code}`,
  });

  await prisma.$transaction(async (tx) => {
    const upd = await tx.printJob.updateMany({
      where: { id: job.id, status: job.status },
      data: {
        status: 'AWAITING_PAYMENT',
        colorMode: cfg.colorMode,
        paperSize: cfg.paperSize,
        orientation: cfg.orientation,
        duplex: cfg.duplex,
        copies: cfg.copies,
        binding: cfg.binding,
        notes: cfg.notes,
        pageRange: q.pageRange,
        pagesToPrint: q.pagesToPrint,
        pricePerPage: q.pricePerPage,
        printCost: q.printCost,
        bindingCost: q.bindingCost,
        totalPrice: q.total,
      },
    });
    if (!upd.count) throw conflict('Status pesanan berubah, muat ulang halaman');
    await tx.payment.updateMany({ where: { printJobId: job.id, status: 'PENDING' }, data: { status: 'EXPIRED' } });
    await tx.payment.create({
      data: {
        orderId,
        provider: paymentProvider.name,
        amount: q.total,
        qrString: charge.qrString,
        qrUrl: charge.qrUrl,
        expiresAt: new Date(now.getTime() + expiryMinutes * 60_000),
        printJobId: job.id,
      },
    });
  });
  const updated = await getOwnJob(user, jobId);
  publishJob(updated);
  return updated;
}

/**
 * Satu-satunya jalur yang mengubah status pembayaran (dipakai webhook Midtrans,
 * pengecekan manual, scheduler, dan simulasi). Idempoten: notifikasi ganda aman.
 * Aturan bisnis: pekerjaan cetak BARU masuk antrean setelah pembayaran tervalidasi.
 */
export async function processPaymentUpdate(orderId, status, raw = null) {
  const payment = await prisma.payment.findUnique({ where: { orderId } });
  if (!payment) {
    console.warn(`[payment] order_id ${orderId} tidak dikenal, diabaikan`);
    return { ignored: true };
  }
  if (payment.status === 'PAID') return { payment, alreadyPaid: true };

  if (status === 'PAID') {
    if (raw?.gross_amount !== undefined && Math.round(Number(raw.gross_amount)) !== payment.amount) {
      console.error(`[payment] nominal tidak cocok untuk ${orderId}: ${raw.gross_amount} vs ${payment.amount}`);
      throw badRequest('Nominal pembayaran tidak sesuai');
    }
    const job = await prisma.$transaction(async (tx) => {
      const upd = await tx.payment.updateMany({
        where: { id: payment.id, status: { not: 'PAID' } },
        data: { status: 'PAID', paidAt: new Date(), rawNotification: raw ?? undefined },
      });
      if (!upd.count) return null;
      const current = await tx.printJob.findUnique({ where: { id: payment.printJobId } });
      if (ACTIVE_QUEUE.includes(current.status) || current.status === 'COMPLETED') return null;
      const queueDate = ymd(new Date(), '-');
      const queueNumber = await nextSequence(tx, `QUEUE-${queueDate}`);
      return tx.printJob.update({
        where: { id: current.id },
        data: {
          status: 'QUEUED',
          paidAt: new Date(),
          queueNumber,
          queueDate,
          pickupCode: String(crypto.randomInt(0, 1_000_000)).padStart(6, '0'),
          cancelledAt: null,
        },
        include: withPayments,
      });
    });
    if (job) {
      publishJob(job);
      notifyUser(job.customerId, {
        type: 'PRINT',
        title: `Pembayaran berhasil · Antrean ${queueLabel(job.queueNumber)}`,
        body: `Pesanan ${job.code} masuk antrean cetak. Simpan kode ambil Anda: ${job.pickupCode}.`,
        link: `/print/jobs/${job.id}`,
      });
    }
    return { payment, job };
  }

  if (status === 'EXPIRED' || status === 'FAILED') {
    await prisma.$transaction(async (tx) => {
      const upd = await tx.payment.updateMany({
        where: { id: payment.id, status: 'PENDING' },
        data: { status, rawNotification: raw ?? undefined },
      });
      if (!upd.count) return;
      const stillOpen = await tx.payment.count({
        where: { printJobId: payment.printJobId, status: { in: ['PENDING', 'PAID'] } },
      });
      if (!stillOpen) {
        await tx.printJob.updateMany({
          where: { id: payment.printJobId, status: 'AWAITING_PAYMENT' },
          data: { status: 'EXPIRED' },
        });
      }
    });
    const job = await prisma.printJob.findUnique({ where: { id: payment.printJobId }, include: withPayments });
    publishJob(job);
    return { payment, job };
  }
  return { payment, pending: true };
}

/** Cek status ke gateway (untuk tombol "Cek pembayaran" bila webhook belum masuk). */
export async function checkPayment(user, jobId) {
  const job = await getOwnJob(user, jobId);
  const pending = job.payments.find((p) => p.status === 'PENDING');
  if (pending) {
    const remote = await paymentProvider.fetchStatus(pending.orderId);
    if (remote && remote.status !== 'PENDING') await processPaymentUpdate(pending.orderId, remote.status, remote.raw);
  }
  return getOwnJob(user, jobId);
}

export async function cancelJob(user, jobId) {
  const job = await getOwnJob(user, jobId);
  if (!['DRAFT', 'AWAITING_PAYMENT', 'EXPIRED'].includes(job.status)) {
    throw conflict('Pesanan yang sudah dibayar tidak dapat dibatalkan dari aplikasi. Silakan hubungi kasir.');
  }
  for (const p of job.payments.filter((x) => x.status === 'PENDING')) await paymentProvider.expire(p.orderId);
  await prisma.$transaction(async (tx) => {
    await tx.payment.updateMany({ where: { printJobId: job.id, status: 'PENDING' }, data: { status: 'FAILED' } });
    const upd = await tx.printJob.updateMany({
      where: { id: job.id, status: job.status },
      data: { status: 'CANCELLED', cancelledAt: new Date() },
    });
    if (!upd.count) throw conflict('Status pesanan berubah, muat ulang halaman');
  });
  if (job.status === 'DRAFT') {
    await fs.rm(path.join(printDir(), job.storedName), { force: true });
    await prisma.printJob.update({ where: { id: job.id }, data: { fileDeletedAt: new Date() } });
  }
  const updated = await getOwnJob(user, jobId);
  publishJob(updated);
  return updated;
}

// ───────────── Staf / kasir ─────────────

const staffInclude = {
  customer: { select: { id: true, name: true, phone: true, email: true } },
  payments: { orderBy: { id: 'desc' }, take: 1 },
};

export async function staffQueue() {
  const today = startOfDay();
  const [jobs, completedToday, paidToday] = await Promise.all([
    prisma.printJob.findMany({
      where: { status: { in: ACTIVE_QUEUE } },
      orderBy: [{ paidAt: 'asc' }],
      include: staffInclude,
    }),
    prisma.printJob.count({ where: { status: 'COMPLETED', completedAt: { gte: today } } }),
    prisma.printJob.aggregate({ where: { paidAt: { gte: today } }, _sum: { totalPrice: true }, _count: { _all: true } }),
  ]);
  const dto = (j) => printJobDto(j, { forStaff: true });
  return {
    waiting: jobs.filter((j) => j.status === 'QUEUED').map(dto),
    printing: jobs.filter((j) => j.status === 'PRINTING').map(dto),
    ready: jobs.filter((j) => j.status === 'READY').map(dto),
    stats: {
      completedToday,
      paidToday: paidToday._count._all,
      revenueToday: paidToday._sum.totalPrice ?? 0,
    },
  };
}

const TRANSITIONS = {
  QUEUED: ['PRINTING'],
  PRINTING: ['READY', 'QUEUED'],
  READY: ['COMPLETED', 'PRINTING'],
};

export async function updateQueueStatus(staff, id, { status, pickupCode }) {
  const job = await prisma.printJob.findUnique({ where: { id } });
  if (!job) throw notFound('Pesanan cetak tidak ditemukan');
  if (!TRANSITIONS[job.status]?.includes(status)) {
    throw conflict(`Status ${job.status} tidak dapat diubah menjadi ${status}`);
  }
  if (status === 'COMPLETED' && pickupCode !== job.pickupCode) {
    throw badRequest('Kode ambil tidak cocok. Minta pelanggan menunjukkan kode 6 digit di aplikasinya.');
  }
  const now = new Date();
  const data = { status, handledById: staff.id };
  if (status === 'PRINTING' && job.status === 'QUEUED') data.startedAt = now;
  if (status === 'READY') data.readyAt = now;
  if (status === 'COMPLETED') data.completedAt = now;
  const upd = await prisma.printJob.updateMany({ where: { id, status: job.status }, data });
  if (!upd.count) throw conflict('Status pesanan sudah diubah oleh staf lain');

  const updated = await prisma.printJob.findUnique({ where: { id }, include: staffInclude });
  publishJob(updated);
  if (status === 'READY') {
    notifyUser(updated.customerId, {
      type: 'PRINT',
      title: `Dokumen siap diambil · ${queueLabel(updated.queueNumber)}`,
      body: `Pesanan ${updated.code} sudah selesai dicetak. Tunjukkan kode ambil ${updated.pickupCode} ke kasir.`,
      link: `/print/jobs/${updated.id}`,
    });
  }
  if (status === 'COMPLETED') {
    notifyUser(updated.customerId, {
      type: 'PRINT',
      title: `Pesanan ${updated.code} selesai`,
      body: 'Terima kasih telah menggunakan layanan cetak Talago Royal.',
      link: `/print/jobs/${updated.id}`,
    });
  }
  audit(staff.id, `PRINT_${status}`, 'print_job', id);
  return updated;
}

export async function findByPickupCode(code) {
  const jobs = await prisma.printJob.findMany({
    where: { pickupCode: code, status: { in: ACTIVE_QUEUE } },
    orderBy: { paidAt: 'desc' },
    include: staffInclude,
  });
  return jobs.map((j) => printJobDto(j, { forStaff: true }));
}

/** Data untuk layar monitor antrean di toko (tanpa data pribadi). */
export async function publicQueue() {
  const jobs = await prisma.printJob.findMany({
    where: { status: { in: ACTIVE_QUEUE } },
    select: { queueNumber: true, status: true },
    orderBy: { paidAt: 'asc' },
  });
  const labels = (s) => jobs.filter((j) => j.status === s).map((j) => queueLabel(j.queueNumber));
  return { printing: labels('PRINTING'), ready: labels('READY'), waiting: labels('QUEUED'), updatedAt: new Date() };
}

// ───────────── Tugas terjadwal ─────────────

/** Kedaluwarsakan QRIS yang lewat batas waktu (cek dulu ke gateway, siapa tahu sudah dibayar). */
export async function expireStalePayments() {
  const stale = await prisma.payment.findMany({
    where: { status: 'PENDING', expiresAt: { lt: new Date(Date.now() - 60_000) } },
    take: 100,
  });
  for (const p of stale) {
    try {
      const remote = await paymentProvider.fetchStatus(p.orderId);
      if (remote?.status === 'PAID') {
        await processPaymentUpdate(p.orderId, 'PAID', remote.raw);
      } else {
        await paymentProvider.expire(p.orderId);
        await processPaymentUpdate(p.orderId, 'EXPIRED', remote?.raw ?? null);
      }
    } catch (err) {
      console.error(`[scheduler] gagal memproses pembayaran ${p.orderId}:`, err.message);
    }
  }
  return stale.length;
}

/** Hapus berkas pelanggan setelah masa retensi (privasi & ruang disk). */
export async function cleanupPrintFiles() {
  const now = Date.now();
  const drafts = await prisma.printJob.findMany({
    where: { status: 'DRAFT', createdAt: { lt: new Date(now - 24 * 3_600_000) } },
    select: { id: true, storedName: true },
    take: 500,
  });
  const retentionCut = new Date(now - env.fileRetentionDays * 86_400_000);
  const finished = await prisma.printJob.findMany({
    where: {
      fileDeletedAt: null,
      status: { in: ['COMPLETED', 'CANCELLED', 'EXPIRED'] },
      updatedAt: { lt: retentionCut },
    },
    select: { id: true, storedName: true },
    take: 500,
  });
  for (const j of [...drafts, ...finished]) {
    await fs.rm(path.join(printDir(), j.storedName), { force: true });
  }
  if (drafts.length) {
    await prisma.printJob.updateMany({
      where: { id: { in: drafts.map((d) => d.id) } },
      data: { status: 'CANCELLED', cancelledAt: new Date(), fileDeletedAt: new Date() },
    });
  }
  if (finished.length) {
    await prisma.printJob.updateMany({
      where: { id: { in: finished.map((d) => d.id) } },
      data: { fileDeletedAt: new Date() },
    });
  }
  return drafts.length + finished.length;
}
