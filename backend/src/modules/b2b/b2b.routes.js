// Portal B2B — endpoint untuk mitra institusi.
import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, requirePartner, requireVerifiedPartner } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, optionalText, z } from '../../lib/validate.js';
import { notFound } from '../../lib/errors.js';
import { sortUnits, baseUnitOf, formatQty } from '../inventory/units.js';
import { textSearch } from '../inventory/serializers.js';
import { resolveTierPrice, sortTiers } from './pricing.js';
import {
  quoteOrder,
  createOrder,
  cancelOrder,
  getOrderForPartner,
  orderDto,
  invoiceDto,
  partnerOutstanding,
  sendOrderPdf,
  ACTIVE_INVOICE,
} from './b2b.service.js';

const router = Router();
router.use(authenticate, authorize('B2B'), requirePartner);

const lineSchema = z
  .object({
    productId: z.number().int().positive().optional(),
    sku: z.string().trim().max(40).optional(),
    unitName: z.string().trim().max(20).optional(),
    qty: z.number().int().min(1).max(1_000_000),
  })
  .refine((l) => l.productId || l.sku, { message: 'Isi productId atau SKU' });
const itemsSchema = z.array(lineSchema).min(1).max(300);

// ───────────── Katalog tertutup ─────────────

router.get('/categories', requireVerifiedPartner, async (_req, res) => {
  const rows = await prisma.category.findMany({ orderBy: { name: 'asc' } });
  res.json({ data: rows });
});

router.get('/catalog', requireVerifiedPartner, async (req, res) => {
  const q = parse(
    pageSchema.extend({
      q: z.string().trim().optional(),
      categoryId: z.coerce.number().int().positive().optional(),
      inStock: z.enum(['true', 'false']).optional(),
    }),
    req.query,
  );
  const where = { isActive: true };
  if (q.categoryId) where.categoryId = q.categoryId;
  if (q.inStock === 'true') where.stock = { gt: 0 };
  const search = textSearch(q.q);
  if (search.length) where.AND = search;

  const [total, rows] = await Promise.all([
    prisma.product.count({ where }),
    prisma.product.findMany({
      where,
      include: { category: true, units: true, priceTiers: true },
      orderBy: { name: 'asc' },
      ...paginate(q),
    }),
  ]);
  const level = req.partner.level;
  res.json({
    data: rows.map((p) => {
      const units = sortUnits(p.units);
      const retail = baseUnitOf(units)?.price ?? 0;
      const tiers = sortTiers(p.priceTiers);
      return {
        id: p.id,
        sku: p.sku,
        name: p.name,
        description: p.description,
        category: p.category?.name,
        baseUnit: p.baseUnit,
        units: units.map((u) => ({
          name: u.name,
          conversion: u.conversion,
          retailPrice: u.price,
          b2bPrice: resolveTierPrice(u.conversion, tiers, retail).unitPrice * u.conversion,
        })),
        retailUnitPrice: retail,
        startingUnitPrice: resolveTierPrice(1, tiers, retail).unitPrice,
        priceTiers: tiers.map((t) => ({
          minQty: t.minQty,
          minQtyDisplay: formatQty(t.minQty, units),
          unitPrice: t.unitPrice,
          savingsPercent: retail ? Math.round((1 - t.unitPrice / retail) * 100) : 0,
        })),
        availability: p.stock <= 0 ? 'HABIS' : p.stock <= p.reorderPoint ? 'TERBATAS' : 'TERSEDIA',
        stockDisplay: formatQty(p.stock, units),
      };
    }),
    meta: { ...pageMeta(total, q), levelName: level?.name ?? null, discountPercent: level?.discountPercent ?? 0 },
  });
});

// ───────────── Quick PO ─────────────

router.post('/quote', requireVerifiedPartner, async (req, res) => {
  const { items } = parse(z.object({ items: itemsSchema }), req.body);
  res.json({ data: await quoteOrder(req.partner, items) });
});

router.post('/orders', requireVerifiedPartner, async (req, res) => {
  const body = parse(
    z.object({ items: itemsSchema, note: optionalText(500), partnerRef: optionalText(60) }),
    req.body,
  );
  const order = await createOrder(req.user, req.partner, body);
  res.status(201).json({ data: orderDto(order) });
});

router.get('/orders', async (req, res) => {
  const q = parse(
    pageSchema.extend({
      status: z.enum(['SUBMITTED', 'APPROVED', 'READY', 'COMPLETED', 'REJECTED', 'CANCELLED']).optional(),
    }),
    req.query,
  );
  const where = { partnerId: req.partner.id, ...(q.status && { status: q.status }) };
  const [total, rows] = await Promise.all([
    prisma.purchaseOrder.count({ where }),
    prisma.purchaseOrder.findMany({
      where,
      orderBy: { id: 'desc' },
      include: { invoice: true, _count: { select: { items: true } } },
      ...paginate(q),
    }),
  ]);
  res.json({ data: rows.map(orderDto), meta: pageMeta(total, q) });
});

router.get('/orders/:id', async (req, res) => {
  const order = await getOrderForPartner(parseId(req.params.id), req.partner.id);
  res.json({ data: orderDto(order) });
});

router.post('/orders/:id/cancel', async (req, res) => {
  const { reason } = parse(z.object({ reason: optionalText(255) }), req.body);
  const order = await cancelOrder(req.user, parseId(req.params.id), reason, { byPartner: true });
  res.json({ data: orderDto(order) });
});

router.get('/orders/:id/pdf', async (req, res) => {
  const order = await getOrderForPartner(parseId(req.params.id), req.partner.id);
  await sendOrderPdf(res, order, 'PO');
});

// ───────────── Faktur ─────────────

router.get('/invoices', async (req, res) => {
  const q = parse(
    pageSchema.extend({ status: z.enum(['UNPAID', 'PARTIAL', 'PAID', 'VOID', 'OVERDUE', 'OPEN']).optional() }),
    req.query,
  );
  const where = { partnerId: req.partner.id };
  if (q.status === 'OVERDUE') Object.assign(where, { status: { in: ACTIVE_INVOICE }, dueDate: { lt: new Date() } });
  else if (q.status === 'OPEN') where.status = { in: ACTIVE_INVOICE };
  else if (q.status) where.status = q.status;
  const [total, rows] = await Promise.all([
    prisma.invoice.count({ where }),
    prisma.invoice.findMany({ where, orderBy: { id: 'desc' }, include: { po: true }, ...paginate(q) }),
  ]);
  res.json({ data: rows.map(invoiceDto), meta: pageMeta(total, q) });
});

router.get('/invoices/:id', async (req, res) => {
  const inv = await prisma.invoice.findFirst({
    where: { id: parseId(req.params.id), partnerId: req.partner.id },
    include: { po: true, payments: { orderBy: { paidAt: 'asc' } } },
  });
  if (!inv) throw notFound('Faktur tidak ditemukan');
  res.json({ data: invoiceDto(inv) });
});

router.get('/invoices/:id/pdf', async (req, res) => {
  const inv = await prisma.invoice.findFirst({ where: { id: parseId(req.params.id), partnerId: req.partner.id } });
  if (!inv) throw notFound('Faktur tidak ditemukan');
  const order = await getOrderForPartner(inv.poId, req.partner.id);
  await sendOrderPdf(res, order, 'INVOICE');
});

// ───────────── Ringkasan dashboard mitra ─────────────

router.get('/summary', async (req, res) => {
  const partner = req.partner;
  const [outstanding, overdue, byStatus, recent] = await Promise.all([
    partnerOutstanding(partner.id),
    prisma.invoice.findMany({
      where: { partnerId: partner.id, status: { in: ACTIVE_INVOICE }, dueDate: { lt: new Date() } },
      select: { total: true, amountPaid: true },
    }),
    prisma.purchaseOrder.groupBy({ by: ['status'], where: { partnerId: partner.id }, _count: { _all: true } }),
    prisma.purchaseOrder.findMany({
      where: { partnerId: partner.id },
      orderBy: { id: 'desc' },
      take: 5,
      include: { invoice: true, _count: { select: { items: true } } },
    }),
  ]);
  res.json({
    data: {
      status: partner.status,
      level: partner.level?.name ?? null,
      discountPercent: partner.level?.discountPercent ?? 0,
      paymentTermDays: partner.paymentTermDays,
      creditLimit: partner.creditLimit,
      creditAvailable: partner.creditLimit > 0 ? Math.max(0, partner.creditLimit - outstanding) : null,
      outstanding,
      overdueCount: overdue.length,
      overdueAmount: overdue.reduce((s, i) => s + i.total - i.amountPaid, 0),
      ordersByStatus: Object.fromEntries(byStatus.map((g) => [g.status, g._count._all])),
      recentOrders: recent.map(orderDto),
    },
  });
});

export default router;
