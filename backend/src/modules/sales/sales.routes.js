// Penjualan eceran di kasir (Point of Sale sederhana).
// Ditambahkan karena proposal menyebut stok dipotong otomatis dari transaksi B2B MAUPUN retail —
// tanpa modul ini stok hanya akan berkurang dari pesanan B2B.
import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, dateQuery, optionalText, z } from '../../lib/validate.js';
import { badRequest, notFound } from '../../lib/errors.js';
import { nextCode } from '../../lib/sequence.js';
import { addDays } from '../../lib/dates.js';
import { publish } from '../../lib/events.js';
import { findUnit, toBase } from '../inventory/units.js';
import { changeStock, announceStockChanges } from '../inventory/stock.js';

const router = Router();
router.use(authenticate, authorize(...STAFF));

const saleSchema = z.object({
  items: z
    .array(
      z.object({
        productId: z.number().int().positive(),
        unitName: z.string().trim().min(1),
        qty: z.number().int().min(1),
      }),
    )
    .min(1)
    .max(100),
  paymentMethod: z.enum(['CASH', 'QRIS', 'TRANSFER']),
  paidAmount: z.number().int().min(0).optional(),
  note: optionalText(255),
});

router.post('/', async (req, res) => {
  const body = parse(saleSchema, req.body);
  const { sale, changes } = await prisma.$transaction(
    async (tx) => {
      const code = await nextCode(tx, 'POS', { period: 'day' });
      const lines = [];
      for (const item of body.items) {
        const product = await tx.product.findUnique({ where: { id: item.productId }, include: { units: true } });
        if (!product || !product.isActive) throw notFound(`Produk #${item.productId} tidak ditemukan / nonaktif`);
        const unit = findUnit(product.units, item.unitName);
        if (!unit) throw badRequest(`Satuan "${item.unitName}" tidak tersedia untuk ${product.name}`);
        lines.push({ product, unit, qty: item.qty, baseQty: toBase(item.qty, unit), subtotal: unit.price * item.qty });
      }
      const total = lines.reduce((s, l) => s + l.subtotal, 0);
      const paidAmount = body.paymentMethod === 'CASH' ? (body.paidAmount ?? total) : total;
      if (paidAmount < total) throw badRequest('Uang yang dibayarkan kurang dari total belanja');

      const sale = await tx.sale.create({
        data: {
          code,
          cashierId: req.user.id,
          total,
          paymentMethod: body.paymentMethod,
          paidAmount,
          changeAmount: paidAmount - total,
          note: body.note,
          items: {
            create: lines.map((l) => ({
              productId: l.product.id,
              unitName: l.unit.name,
              unitQty: l.qty,
              conversion: l.unit.conversion,
              baseQty: l.baseQty,
              unitPrice: l.unit.price,
              subtotal: l.subtotal,
            })),
          },
        },
      });
      const changes = [];
      for (const l of lines) {
        changes.push(
          await changeStock(tx, {
            productId: l.product.id,
            qty: -l.baseQty,
            type: 'SALE',
            unitName: l.unit.name,
            unitQty: l.qty,
            refType: 'SALE',
            refId: sale.id,
            refCode: code,
            userId: req.user.id,
          }),
        );
      }
      return { sale, changes };
    },
    { timeout: 20_000 },
  );
  announceStockChanges(changes);
  publish('sales.created', { id: sale.id, code: sale.code, total: sale.total }, ['staff']);
  res.status(201).json({ data: await saleDetail(sale.id) });
});

async function saleDetail(id) {
  const s = await prisma.sale.findUnique({
    where: { id },
    include: { cashier: { select: { name: true } }, items: { include: { product: { select: { sku: true, name: true } } } } },
  });
  if (!s) throw notFound('Transaksi tidak ditemukan');
  return {
    id: s.id,
    code: s.code,
    cashier: s.cashier.name,
    total: s.total,
    paymentMethod: s.paymentMethod,
    paidAmount: s.paidAmount,
    changeAmount: s.changeAmount,
    note: s.note,
    createdAt: s.createdAt,
    items: s.items.map((i) => ({
      productId: i.productId,
      sku: i.product.sku,
      name: i.product.name,
      unitName: i.unitName,
      unitQty: i.unitQty,
      unitPrice: i.unitPrice,
      subtotal: i.subtotal,
    })),
  };
}

router.get('/', async (req, res) => {
  const q = parse(pageSchema.extend({ from: dateQuery.optional(), to: dateQuery.optional() }), req.query);
  const where = {};
  if (q.from || q.to) where.createdAt = { ...(q.from && { gte: q.from }), ...(q.to && { lt: addDays(q.to, 1) }) };
  const [total, agg, rows] = await Promise.all([
    prisma.sale.count({ where }),
    prisma.sale.aggregate({ where, _sum: { total: true } }),
    prisma.sale.findMany({
      where,
      orderBy: { id: 'desc' },
      include: { cashier: { select: { name: true } }, _count: { select: { items: true } } },
      ...paginate(q),
    }),
  ]);
  res.json({
    data: rows.map((s) => ({
      id: s.id,
      code: s.code,
      cashier: s.cashier.name,
      total: s.total,
      paymentMethod: s.paymentMethod,
      itemCount: s._count.items,
      createdAt: s.createdAt,
    })),
    meta: { ...pageMeta(total, q), revenue: agg._sum.total ?? 0 },
  });
});

router.get('/:id', async (req, res) => {
  res.json({ data: await saleDetail(parseId(req.params.id)) });
});

export default router;
