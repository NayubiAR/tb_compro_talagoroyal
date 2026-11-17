import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, dateQuery, optionalText, z } from '../../lib/validate.js';
import { badRequest, notFound } from '../../lib/errors.js';
import { nextCode } from '../../lib/sequence.js';
import { addDays } from '../../lib/dates.js';
import { audit } from '../../lib/notify.js';
import { normalizeUnits, baseUnitOf, findUnit, toBase, sumCounts, formatQty } from './units.js';
import { normalizeTiers } from '../b2b/pricing.js';
import { changeStock, announceStockChanges } from './stock.js';
import { productDto, productInclude, movementDto, textSearch } from './serializers.js';
import { computeRestockAlerts, inventorySummary } from './restock.js';

const router = Router();
router.use(authenticate, authorize(...STAFF));

const MOVEMENT_TYPES = ['RECEIPT', 'SALE', 'B2B_ORDER', 'ADJUSTMENT', 'RETURN'];
const HEAVY_TX = { timeout: 30_000, maxWait: 10_000 };

// ───────────── Kategori ─────────────

router.get('/categories', async (_req, res) => {
  const rows = await prisma.category.findMany({
    orderBy: { name: 'asc' },
    include: { _count: { select: { products: true } } },
  });
  res.json({ data: rows.map((c) => ({ id: c.id, name: c.name, productCount: c._count.products })) });
});

const categorySchema = z.object({ name: z.string().trim().min(2).max(80) });

router.post('/categories', async (req, res) => {
  const { name } = parse(categorySchema, req.body);
  const category = await prisma.category.create({ data: { name } });
  res.status(201).json({ data: category });
});

router.patch('/categories/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const { name } = parse(categorySchema, req.body);
  const category = await prisma.category.update({ where: { id }, data: { name } });
  res.json({ data: category });
});

// ───────────── Produk & hierarki satuan ─────────────

const listSchema = pageSchema.extend({
  q: z.string().trim().optional(),
  categoryId: z.coerce.number().int().positive().optional(),
  stockStatus: z.enum(['OK', 'LOW', 'OUT']).optional(),
  active: z.enum(['true', 'false', 'all']).default('true'),
  sort: z.enum(['name', 'sku', 'stock', 'updated']).default('name'),
});

const SORTS = {
  name: { name: 'asc' },
  sku: { sku: 'asc' },
  stock: { stock: 'asc' },
  updated: { updatedAt: 'desc' },
};

router.get('/products', async (req, res) => {
  const q = parse(listSchema, req.query);
  const and = textSearch(q.q);
  const where = {};
  if (q.active !== 'all') where.isActive = q.active === 'true';
  if (q.categoryId) where.categoryId = q.categoryId;
  if (q.stockStatus === 'OUT') where.stock = { lte: 0 };
  if (q.stockStatus === 'LOW') and.push({ stock: { gt: 0 } }, { stock: { lte: prisma.product.fields.reorderPoint } });
  if (q.stockStatus === 'OK') where.stock = { gt: prisma.product.fields.reorderPoint };
  if (and.length) where.AND = and;

  const [total, rows] = await Promise.all([
    prisma.product.count({ where }),
    prisma.product.findMany({ where, include: productInclude, orderBy: SORTS[q.sort], ...paginate(q) }),
  ]);
  res.json({ data: rows.map(productDto), meta: pageMeta(total, q) });
});

router.get('/products/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const product = await prisma.product.findUnique({ where: { id }, include: productInclude });
  if (!product) throw notFound('Produk tidak ditemukan');
  const movements = await prisma.stockMovement.findMany({
    where: { productId: id },
    orderBy: { id: 'desc' },
    take: 20,
    include: { user: { select: { name: true } } },
  });
  res.json({
    data: {
      ...productDto(product),
      movements: movements.map((m) => movementDto({ ...m, product: { ...product, units: product.units } })),
    },
  });
});

const unitSchema = z.object({
  name: z.string().trim().min(1).max(20),
  conversion: z.number().int().min(1),
  price: z.number().int().min(0),
});
const tierSchema = z.object({ minQty: z.number().int().min(1), unitPrice: z.number().int().min(0) });
const productSchema = z.object({
  sku: z
    .string()
    .trim()
    .min(2)
    .max(40)
    .regex(/^[A-Za-z0-9._-]+$/, 'SKU hanya boleh huruf, angka, titik, strip, atau garis bawah')
    .transform((s) => s.toUpperCase()),
  name: z.string().trim().min(2).max(160),
  description: optionalText(2000),
  categoryId: z.number().int().positive(),
  costPrice: z.number().int().min(0).default(0),
  reorderPoint: z.number().int().min(0).default(0),
  leadTimeDays: z.number().int().min(0).max(365).default(3),
  isActive: z.boolean().default(true),
  units: z.array(unitSchema).min(1).max(6),
  priceTiers: z.array(tierSchema).max(10).default([]),
  initialStock: z.number().int().min(0).default(0),
});

async function ensureCategory(categoryId) {
  const c = await prisma.category.findUnique({ where: { id: categoryId } });
  if (!c) throw badRequest('Kategori tidak ditemukan');
}

router.post('/products', async (req, res) => {
  const body = parse(productSchema, req.body);
  const units = normalizeUnits(body.units);
  const tiers = normalizeTiers(body.priceTiers);
  await ensureCategory(body.categoryId);

  const { product, change } = await prisma.$transaction(async (tx) => {
    const created = await tx.product.create({
      data: {
        sku: body.sku,
        name: body.name,
        description: body.description,
        categoryId: body.categoryId,
        baseUnit: baseUnitOf(units).name,
        costPrice: body.costPrice,
        reorderPoint: body.reorderPoint,
        leadTimeDays: body.leadTimeDays,
        isActive: body.isActive,
        units: { create: units },
        priceTiers: { create: tiers },
      },
    });
    let change = null;
    if (body.initialStock > 0) {
      change = await changeStock(tx, {
        productId: created.id,
        qty: body.initialStock,
        type: 'ADJUSTMENT',
        refType: 'INITIAL',
        note: 'Stok awal',
        userId: req.user.id,
      });
    }
    const product = await tx.product.findUnique({ where: { id: created.id }, include: productInclude });
    return { product, change };
  });
  if (change) announceStockChanges([change]);
  audit(req.user.id, 'PRODUCT_CREATE', 'product', product.id, { sku: product.sku });
  res.status(201).json({ data: productDto(product) });
});

router.put('/products/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const body = parse(productSchema.omit({ initialStock: true }), req.body);
  const units = normalizeUnits(body.units);
  const tiers = normalizeTiers(body.priceTiers);
  await ensureCategory(body.categoryId);

  const existing = await prisma.product.findUnique({ where: { id }, include: { _count: { select: { movements: true } } } });
  if (!existing) throw notFound('Produk tidak ditemukan');
  const newBase = baseUnitOf(units).name;
  if (existing.baseUnit.toLowerCase() !== newBase.toLowerCase() && existing._count.movements > 0) {
    throw badRequest(
      `Satuan terkecil tidak boleh diganti (${existing.baseUnit} → ${newBase}) karena produk sudah memiliki riwayat stok`,
    );
  }

  const product = await prisma.$transaction(async (tx) => {
    await tx.product.update({
      where: { id },
      data: {
        sku: body.sku,
        name: body.name,
        description: body.description,
        categoryId: body.categoryId,
        baseUnit: newBase,
        costPrice: body.costPrice,
        reorderPoint: body.reorderPoint,
        leadTimeDays: body.leadTimeDays,
        isActive: body.isActive,
      },
    });
    await tx.productUnit.deleteMany({ where: { productId: id } });
    await tx.productUnit.createMany({ data: units.map((u) => ({ ...u, productId: id })) });
    await tx.priceTier.deleteMany({ where: { productId: id } });
    if (tiers.length) await tx.priceTier.createMany({ data: tiers.map((t) => ({ ...t, productId: id })) });
    return tx.product.findUnique({ where: { id }, include: productInclude });
  });
  audit(req.user.id, 'PRODUCT_UPDATE', 'product', id, { sku: product.sku });
  res.json({ data: productDto(product) });
});

// ───────────── Penerimaan barang (stok masuk) ─────────────

const receiptSchema = z.object({
  supplier: optionalText(120),
  reference: optionalText(60),
  note: optionalText(255),
  items: z
    .array(
      z.object({
        productId: z.number().int().positive(),
        unitName: z.string().trim().min(1),
        qty: z.number().int().min(1),
        unitCost: z.number().int().min(0).default(0),
      }),
    )
    .min(1)
    .max(200),
});

router.post('/receipts', async (req, res) => {
  const body = parse(receiptSchema, req.body);
  const { receipt, changes } = await prisma.$transaction(async (tx) => {
    const code = await nextCode(tx, 'RCV');
    const receipt = await tx.stockReceipt.create({
      data: { code, supplier: body.supplier, reference: body.reference, note: body.note, userId: req.user.id },
    });
    const changes = [];
    for (const item of body.items) {
      const product = await tx.product.findUnique({ where: { id: item.productId }, include: { units: true } });
      if (!product) throw notFound(`Produk #${item.productId} tidak ditemukan`);
      const unit = findUnit(product.units, item.unitName);
      if (!unit) throw badRequest(`Satuan "${item.unitName}" tidak tersedia untuk ${product.name}`);
      const baseQty = toBase(item.qty, unit);
      if (item.unitCost > 0) {
        // HPP rata-rata tertimbang (moving average) agar valuasi aset tetap akurat.
        const oldStock = Math.max(0, product.stock);
        const costPerBase = item.unitCost / unit.conversion;
        const newCost = Math.round((oldStock * product.costPrice + baseQty * costPerBase) / (oldStock + baseQty));
        await tx.product.update({ where: { id: product.id }, data: { costPrice: newCost } });
      }
      await tx.stockReceiptItem.create({
        data: { receiptId: receipt.id, productId: product.id, unitName: unit.name, unitQty: item.qty, baseQty, unitCost: item.unitCost },
      });
      changes.push(
        await changeStock(tx, {
          productId: product.id,
          qty: baseQty,
          type: 'RECEIPT',
          unitName: unit.name,
          unitQty: item.qty,
          refType: 'RECEIPT',
          refId: receipt.id,
          refCode: code,
          note: body.supplier ? `Dari ${body.supplier}` : null,
          userId: req.user.id,
        }),
      );
    }
    return { receipt, changes };
  }, HEAVY_TX);
  announceStockChanges(changes);
  res.status(201).json({ data: await receiptDetail(receipt.id) });
});

async function receiptDetail(id) {
  const r = await prisma.stockReceipt.findUnique({
    where: { id },
    include: { user: { select: { name: true } }, items: { include: { product: { include: { units: true } } } } },
  });
  if (!r) throw notFound('Penerimaan tidak ditemukan');
  return {
    id: r.id,
    code: r.code,
    supplier: r.supplier,
    reference: r.reference,
    note: r.note,
    user: r.user.name,
    createdAt: r.createdAt,
    items: r.items.map((i) => ({
      productId: i.productId,
      sku: i.product.sku,
      name: i.product.name,
      unitName: i.unitName,
      unitQty: i.unitQty,
      baseQty: i.baseQty,
      qtyDisplay: formatQty(i.baseQty, i.product.units),
      unitCost: i.unitCost,
    })),
  };
}

router.get('/receipts', async (req, res) => {
  const q = parse(pageSchema, req.query);
  const [total, rows] = await Promise.all([
    prisma.stockReceipt.count(),
    prisma.stockReceipt.findMany({
      orderBy: { id: 'desc' },
      include: { user: { select: { name: true } }, _count: { select: { items: true } } },
      ...paginate(q),
    }),
  ]);
  res.json({
    data: rows.map((r) => ({
      id: r.id,
      code: r.code,
      supplier: r.supplier,
      reference: r.reference,
      note: r.note,
      user: r.user.name,
      itemCount: r._count.items,
      createdAt: r.createdAt,
    })),
    meta: pageMeta(total, q),
  });
});

router.get('/receipts/:id', async (req, res) => {
  res.json({ data: await receiptDetail(parseId(req.params.id)) });
});

// ───────────── Stock opname (hitung fisik) ─────────────

const opnameSchema = z.object({
  note: optionalText(255),
  items: z
    .array(
      z.object({
        productId: z.number().int().positive(),
        counts: z
          .array(z.object({ unitName: z.string().trim().min(1), qty: z.number().int().min(0) }))
          .min(1),
      }),
    )
    .min(1)
    .max(500),
});

router.post('/opnames', async (req, res) => {
  const body = parse(opnameSchema, req.body);
  const ids = body.items.map((i) => i.productId);
  if (new Set(ids).size !== ids.length) throw badRequest('Produk yang sama tidak boleh muncul dua kali dalam satu opname');

  const { opname, changes } = await prisma.$transaction(async (tx) => {
    const code = await nextCode(tx, 'OPN');
    const opname = await tx.stockOpname.create({ data: { code, note: body.note, userId: req.user.id } });
    const changes = [];
    for (const item of body.items) {
      // Kunci baris produk agar stok sistem tidak berubah selama dibandingkan.
      const locked = await tx.$queryRaw`SELECT stock FROM products WHERE id = ${item.productId} FOR UPDATE`;
      if (!locked.length) throw notFound(`Produk #${item.productId} tidak ditemukan`);
      const product = await tx.product.findUnique({ where: { id: item.productId }, include: { units: true } });
      const counted = sumCounts(item.counts, product.units);
      const systemQty = Number(locked[0].stock);
      const difference = counted - systemQty;
      await tx.stockOpnameItem.create({
        data: { opnameId: opname.id, productId: product.id, systemQty, countedQty: counted, difference },
      });
      if (difference !== 0) {
        changes.push(
          await changeStock(tx, {
            productId: product.id,
            qty: difference,
            type: 'ADJUSTMENT',
            refType: 'OPNAME',
            refId: opname.id,
            refCode: code,
            note: `Stock opname: sistem ${formatQty(systemQty, product.units)}, fisik ${formatQty(counted, product.units)}`,
            userId: req.user.id,
          }),
        );
      }
    }
    return { opname, changes };
  }, HEAVY_TX);
  announceStockChanges(changes);
  audit(req.user.id, 'STOCK_OPNAME', 'stock_opname', opname.id, { code: opname.code, adjusted: changes.length });
  res.status(201).json({ data: await opnameDetail(opname.id) });
});

async function opnameDetail(id) {
  const o = await prisma.stockOpname.findUnique({
    where: { id },
    include: { user: { select: { name: true } }, items: { include: { product: { include: { units: true } } } } },
  });
  if (!o) throw notFound('Data opname tidak ditemukan');
  return {
    id: o.id,
    code: o.code,
    note: o.note,
    user: o.user.name,
    createdAt: o.createdAt,
    items: o.items.map((i) => ({
      productId: i.productId,
      sku: i.product.sku,
      name: i.product.name,
      systemQty: i.systemQty,
      countedQty: i.countedQty,
      difference: i.difference,
      systemDisplay: formatQty(i.systemQty, i.product.units),
      countedDisplay: formatQty(i.countedQty, i.product.units),
      differenceDisplay: formatQty(i.difference, i.product.units),
      differenceValue: i.difference * i.product.costPrice,
    })),
  };
}

router.get('/opnames', async (req, res) => {
  const q = parse(pageSchema, req.query);
  const [total, rows] = await Promise.all([
    prisma.stockOpname.count(),
    prisma.stockOpname.findMany({
      orderBy: { id: 'desc' },
      include: { user: { select: { name: true } }, items: { select: { difference: true } } },
      ...paginate(q),
    }),
  ]);
  res.json({
    data: rows.map((o) => ({
      id: o.id,
      code: o.code,
      note: o.note,
      user: o.user.name,
      createdAt: o.createdAt,
      itemCount: o.items.length,
      adjustedCount: o.items.filter((i) => i.difference !== 0).length,
    })),
    meta: pageMeta(total, q),
  });
});

router.get('/opnames/:id', async (req, res) => {
  res.json({ data: await opnameDetail(parseId(req.params.id)) });
});

// ───────────── Riwayat mutasi stok ─────────────

const movementQuery = pageSchema.extend({
  productId: z.coerce.number().int().positive().optional(),
  type: z.enum(MOVEMENT_TYPES).optional(),
  from: dateQuery.optional(),
  to: dateQuery.optional(),
  q: z.string().trim().optional(),
});

router.get('/movements', async (req, res) => {
  const q = parse(movementQuery, req.query);
  const where = {};
  if (q.productId) where.productId = q.productId;
  if (q.type) where.type = q.type;
  if (q.from || q.to) where.createdAt = { ...(q.from && { gte: q.from }), ...(q.to && { lt: addDays(q.to, 1) }) };
  const search = textSearch(q.q);
  if (search.length) where.product = { AND: search };
  const [total, rows] = await Promise.all([
    prisma.stockMovement.count({ where }),
    prisma.stockMovement.findMany({
      where,
      orderBy: { id: 'desc' },
      include: { product: { include: { units: true } }, user: { select: { name: true } } },
      ...paginate(q),
    }),
  ]);
  res.json({ data: rows.map(movementDto), meta: pageMeta(total, q) });
});

// ───────────── Smart Restock Alert & ringkasan ─────────────

router.get('/restock-alerts', async (req, res) => {
  const q = parse(
    z.object({
      level: z.enum(['HABIS', 'KRITIS', 'WASPADA']).optional(),
      fastOnly: z.enum(['true', 'false']).optional(),
      limit: z.coerce.number().int().min(1).max(1000).default(200),
    }),
    req.query,
  );
  const result = await computeRestockAlerts();
  let alerts = result.alerts;
  if (q.level) alerts = alerts.filter((a) => a.level === q.level);
  if (q.fastOnly === 'true') alerts = alerts.filter((a) => a.fastMoving);
  res.json({ data: alerts.slice(0, q.limit), counts: result.counts, total: alerts.length, generatedAt: result.generatedAt });
});

router.get('/summary', async (_req, res) => {
  res.json({ data: await inventorySummary() });
});

export default router;
