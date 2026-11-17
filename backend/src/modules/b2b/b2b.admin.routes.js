// Portal B2B — endpoint staf: verifikasi PO, faktur, pembayaran & piutang.
import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, optionalText, dateQuery, z } from '../../lib/validate.js';
import { notFound } from '../../lib/errors.js';
import {
  approveOrder,
  rejectOrder,
  markReady,
  markCompleted,
  cancelOrder,
  loadOrder,
  orderDto,
  invoiceDto,
  recordInvoicePayment,
  receivablesSummary,
  sendOrderPdf,
  ACTIVE_INVOICE,
} from './b2b.service.js';

const router = Router();
router.use(authenticate, authorize(...STAFF));

const ORDER_STATUS = ['SUBMITTED', 'APPROVED', 'READY', 'COMPLETED', 'REJECTED', 'CANCELLED'];

router.get('/orders', async (req, res) => {
  const q = parse(
    pageSchema.extend({
      status: z.enum(ORDER_STATUS).optional(),
      partnerId: z.coerce.number().int().positive().optional(),
      q: z.string().trim().optional(),
    }),
    req.query,
  );
  const where = {};
  if (q.status) where.status = q.status;
  if (q.partnerId) where.partnerId = q.partnerId;
  if (q.q) {
    where.OR = [
      { poNumber: { contains: q.q } },
      { partnerRef: { contains: q.q } },
      { partner: { institutionName: { contains: q.q } } },
    ];
  }
  const [total, rows, counts] = await Promise.all([
    prisma.purchaseOrder.count({ where }),
    prisma.purchaseOrder.findMany({
      where,
      orderBy: { id: 'desc' },
      include: { partner: { include: { user: true } }, invoice: true, _count: { select: { items: true } } },
      ...paginate(q),
    }),
    prisma.purchaseOrder.groupBy({ by: ['status'], _count: { _all: true } }),
  ]);
  res.json({
    data: rows.map(orderDto),
    meta: { ...pageMeta(total, q), counts: Object.fromEntries(counts.map((c) => [c.status, c._count._all])) },
  });
});

router.get('/orders/:id', async (req, res) => {
  res.json({ data: orderDto(await loadOrder(parseId(req.params.id))) });
});

router.post('/orders/:id/approve', async (req, res) => {
  res.json({ data: orderDto(await approveOrder(req.user, parseId(req.params.id))) });
});

router.post('/orders/:id/reject', async (req, res) => {
  const { reason } = parse(z.object({ reason: z.string().trim().min(3).max(255) }), req.body);
  res.json({ data: orderDto(await rejectOrder(req.user, parseId(req.params.id), reason)) });
});

router.post('/orders/:id/ready', async (req, res) => {
  res.json({ data: orderDto(await markReady(req.user, parseId(req.params.id))) });
});

router.post('/orders/:id/complete', async (req, res) => {
  res.json({ data: orderDto(await markCompleted(req.user, parseId(req.params.id))) });
});

router.post('/orders/:id/cancel', async (req, res) => {
  const { reason } = parse(z.object({ reason: optionalText(255) }), req.body);
  res.json({ data: orderDto(await cancelOrder(req.user, parseId(req.params.id), reason, { byPartner: false })) });
});

router.get('/orders/:id/pdf', async (req, res) => {
  await sendOrderPdf(res, await loadOrder(parseId(req.params.id)), 'PO');
});

// ───────────── Faktur & piutang ─────────────

router.get('/invoices', async (req, res) => {
  const q = parse(
    pageSchema.extend({
      status: z.enum(['UNPAID', 'PARTIAL', 'PAID', 'VOID', 'OVERDUE', 'OPEN']).optional(),
      partnerId: z.coerce.number().int().positive().optional(),
      q: z.string().trim().optional(),
    }),
    req.query,
  );
  const where = {};
  if (q.partnerId) where.partnerId = q.partnerId;
  if (q.status === 'OVERDUE') Object.assign(where, { status: { in: ACTIVE_INVOICE }, dueDate: { lt: new Date() } });
  else if (q.status === 'OPEN') where.status = { in: ACTIVE_INVOICE };
  else if (q.status) where.status = q.status;
  if (q.q) {
    where.OR = [
      { invoiceNumber: { contains: q.q } },
      { po: { poNumber: { contains: q.q } } },
      { partner: { institutionName: { contains: q.q } } },
    ];
  }
  const [total, rows] = await Promise.all([
    prisma.invoice.count({ where }),
    prisma.invoice.findMany({
      where,
      orderBy: [{ dueDate: 'asc' }, { id: 'desc' }],
      include: { po: true, partner: true },
      ...paginate(q),
    }),
  ]);
  res.json({ data: rows.map(invoiceDto), meta: pageMeta(total, q) });
});

router.get('/invoices/:id', async (req, res) => {
  const inv = await prisma.invoice.findUnique({
    where: { id: parseId(req.params.id) },
    include: { po: true, partner: true, payments: { orderBy: { paidAt: 'asc' } } },
  });
  if (!inv) throw notFound('Faktur tidak ditemukan');
  res.json({ data: invoiceDto(inv) });
});

router.post('/invoices/:id/payments', async (req, res) => {
  const body = parse(
    z.object({
      amount: z.number().int().min(1),
      method: z.enum(['CASH', 'QRIS', 'TRANSFER']),
      reference: optionalText(80),
      note: optionalText(255),
      paidAt: dateQuery.optional(),
    }),
    req.body,
  );
  const inv = await recordInvoicePayment(req.user, parseId(req.params.id), body);
  res.status(201).json({ data: invoiceDto(inv) });
});

router.get('/invoices/:id/pdf', async (req, res) => {
  const inv = await prisma.invoice.findUnique({ where: { id: parseId(req.params.id) } });
  if (!inv) throw notFound('Faktur tidak ditemukan');
  await sendOrderPdf(res, await loadOrder(inv.poId), 'INVOICE');
});

router.get('/receivables', async (req, res) => {
  const { partnerId } = parse(z.object({ partnerId: z.coerce.number().int().positive().optional() }), req.query);
  res.json({ data: await receivablesSummary(partnerId) });
});

export default router;
