import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { authenticate, STAFF } from '../../middleware/auth.js';
import { conflict, forbidden, notFound } from '../../lib/errors.js';
import { paymentProvider } from './providers/index.js';
import { mapMidtransStatus } from './providers/midtrans.js';
import { processPaymentUpdate, printJobDto } from '../printing/printing.service.js';

const router = Router();

router.get('/config', (_req, res) => {
  res.json({
    data: {
      provider: paymentProvider.name,
      expiryMinutes: env.payment.expiryMinutes,
      simulation: paymentProvider.name === 'MOCK',
    },
  });
});

/**
 * Webhook notifikasi Midtrans (atur "Payment Notification URL" di dashboard Midtrans ke
 * {PUBLIC_BASE_URL}/api/payments/midtrans/notification). Untuk development lokal gunakan ngrok.
 */
router.post('/midtrans/notification', async (req, res) => {
  if (paymentProvider.name !== 'MIDTRANS') throw notFound();
  const n = req.body ?? {};
  if (!paymentProvider.verifyNotification(n)) {
    console.warn('[midtrans] signature tidak valid untuk', n.order_id);
    throw forbidden('Signature tidak valid');
  }
  // Defense in depth: konfirmasi status langsung ke API Midtrans, jangan hanya percaya body.
  const remote = await paymentProvider.fetchStatus(n.order_id).catch(() => null);
  const status = remote?.status ?? mapMidtransStatus(n.transaction_status);
  await processPaymentUpdate(n.order_id, status, n);
  res.json({ ok: true });
});

/** Mode simulasi: tandai QRIS sebagai lunas melalui jalur yang sama dengan webhook. */
router.post('/mock/:orderId/pay', authenticate, async (req, res) => {
  if (paymentProvider.name !== 'MOCK') throw notFound('Simulasi pembayaran hanya tersedia pada mode mock');
  const payment = await prisma.payment.findUnique({
    where: { orderId: req.params.orderId },
    include: { printJob: true },
  });
  if (!payment) throw notFound('Transaksi tidak ditemukan');
  if (payment.printJob.customerId !== req.user.id && !STAFF.includes(req.user.role)) throw forbidden();
  if (payment.status !== 'PENDING') throw conflict(`Status pembayaran sudah ${payment.status}`);
  if (payment.expiresAt < new Date()) throw conflict('QRIS sudah kedaluwarsa');
  const result = await processPaymentUpdate(payment.orderId, 'PAID', {
    simulated: true,
    gross_amount: String(payment.amount),
  });
  const job = await prisma.printJob.findUnique({
    where: { id: payment.printJobId },
    include: { payments: { orderBy: { id: 'desc' } } },
  });
  res.json({ data: printJobDto(job), queued: Boolean(result.job) });
});

export default router;
