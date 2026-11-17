// Dashboard & laporan analitik untuk staf dan pemilik toko.
import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, dateQuery, z } from '../../lib/validate.js';
import { addDays, startOfDay, ymd } from '../../lib/dates.js';
import { computeRestockAlerts, inventorySummary } from '../inventory/restock.js';
import { formatQty } from '../inventory/units.js';
import { receivablesSummary } from '../b2b/b2b.service.js';

const router = Router();
router.use(authenticate, authorize(...STAFF));

const B2B_REVENUE_STATUS = ['APPROVED', 'READY', 'COMPLETED'];

/** Ambil omzet per kanal dalam rentang waktu, sudah dikelompokkan per hari (zona waktu toko). */
async function revenueByDay(from, to) {
  const [sales, orders, prints] = await Promise.all([
    prisma.sale.findMany({ where: { createdAt: { gte: from, lt: to } }, select: { createdAt: true, total: true } }),
    prisma.purchaseOrder.findMany({
      where: { status: { in: B2B_REVENUE_STATUS }, approvedAt: { gte: from, lt: to } },
      select: { approvedAt: true, total: true },
    }),
    prisma.printJob.findMany({
      where: { paidAt: { gte: from, lt: to } },
      select: { paidAt: true, totalPrice: true },
    }),
  ]);
  const days = new Map();
  for (let d = new Date(from); d < to; d = addDays(d, 1)) {
    days.set(ymd(d, '-'), { date: ymd(d, '-'), retail: 0, b2b: 0, print: 0 });
  }
  const add = (date, key, amount) => {
    const row = days.get(ymd(date, '-'));
    if (row) row[key] += amount;
  };
  for (const s of sales) add(s.createdAt, 'retail', s.total);
  for (const o of orders) add(o.approvedAt, 'b2b', o.total);
  for (const p of prints) add(p.paidAt, 'print', p.totalPrice);
  const series = [...days.values()].map((r) => ({ ...r, total: r.retail + r.b2b + r.print }));
  const totals = {
    retail: series.reduce((s, r) => s + r.retail, 0),
    b2b: series.reduce((s, r) => s + r.b2b, 0),
    print: series.reduce((s, r) => s + r.print, 0),
    retailCount: sales.length,
    b2bCount: orders.length,
    printCount: prints.length,
  };
  totals.total = totals.retail + totals.b2b + totals.print;
  return { series, totals };
}

router.get('/dashboard', async (_req, res) => {
  const today = startOfDay();
  const tomorrow = addDays(today, 1);
  const [todayRev, trend, pendingOrders, queue, restock, inventory, receivables, pendingPartners] = await Promise.all([
    revenueByDay(today, tomorrow),
    revenueByDay(addDays(today, -13), tomorrow),
    prisma.purchaseOrder.count({ where: { status: 'SUBMITTED' } }),
    prisma.printJob.groupBy({
      by: ['status'],
      where: { status: { in: ['QUEUED', 'PRINTING', 'READY'] } },
      _count: { _all: true },
    }),
    computeRestockAlerts(),
    inventorySummary(),
    receivablesSummary(),
    prisma.partner.count({ where: { status: 'PENDING' } }),
  ]);
  const q = Object.fromEntries(queue.map((g) => [g.status, g._count._all]));
  res.json({
    data: {
      today: todayRev.totals,
      revenueTrend: trend.series,
      pendingOrders,
      pendingPartners,
      printQueue: { waiting: q.QUEUED ?? 0, printing: q.PRINTING ?? 0, ready: q.READY ?? 0 },
      restock: { counts: restock.counts, top: restock.alerts.slice(0, 8) },
      inventory,
      receivables: {
        outstanding: receivables.outstanding,
        overdue: receivables.overdue,
        invoiceCount: receivables.invoiceCount,
      },
    },
  });
});

const rangeSchema = z.object({ from: dateQuery.optional(), to: dateQuery.optional() });

function resolveRange(q) {
  const to = q.to ? addDays(q.to, 1) : addDays(startOfDay(), 1);
  const from = q.from ?? addDays(to, -30);
  return { from, to };
}

router.get('/sales', async (req, res) => {
  const { from, to } = resolveRange(parse(rangeSchema, req.query));
  const [revenue, saleItems, poItems, methods, partners] = await Promise.all([
    revenueByDay(from, to),
    prisma.saleItem.groupBy({
      by: ['productId'],
      where: { sale: { createdAt: { gte: from, lt: to } } },
      _sum: { baseQty: true, subtotal: true },
    }),
    prisma.purchaseOrderItem.groupBy({
      by: ['productId'],
      where: { po: { status: { in: B2B_REVENUE_STATUS }, approvedAt: { gte: from, lt: to } } },
      _sum: { baseQty: true, subtotal: true },
    }),
    prisma.sale.groupBy({
      by: ['paymentMethod'],
      where: { createdAt: { gte: from, lt: to } },
      _sum: { total: true },
      _count: { _all: true },
    }),
    prisma.purchaseOrder.groupBy({
      by: ['partnerId'],
      where: { status: { in: B2B_REVENUE_STATUS }, approvedAt: { gte: from, lt: to } },
      _sum: { total: true },
      _count: { _all: true },
      orderBy: { _sum: { total: 'desc' } },
      take: 10,
    }),
  ]);

  const merged = new Map();
  for (const [channel, rows] of [['retail', saleItems], ['b2b', poItems]]) {
    for (const r of rows) {
      const m = merged.get(r.productId) ?? { productId: r.productId, qty: 0, revenue: 0, retailQty: 0, b2bQty: 0 };
      m.qty += r._sum.baseQty ?? 0;
      m.revenue += r._sum.subtotal ?? 0;
      m[`${channel}Qty`] += r._sum.baseQty ?? 0;
      merged.set(r.productId, m);
    }
  }
  const top = [...merged.values()].sort((a, b) => b.revenue - a.revenue).slice(0, 15);
  const products = await prisma.product.findMany({
    where: { id: { in: top.map((t) => t.productId) } },
    include: { units: true, category: true },
  });
  const byId = new Map(products.map((p) => [p.id, p]));
  const partnerRows = await prisma.partner.findMany({
    where: { id: { in: partners.map((p) => p.partnerId) } },
    select: { id: true, institutionName: true },
  });
  const partnerName = new Map(partnerRows.map((p) => [p.id, p.institutionName]));

  res.json({
    data: {
      range: { from, to: addDays(to, -1) },
      totals: revenue.totals,
      series: revenue.series,
      topProducts: top.map((t) => {
        const p = byId.get(t.productId);
        return {
          ...t,
          sku: p?.sku,
          name: p?.name,
          category: p?.category?.name,
          qtyDisplay: p ? formatQty(t.qty, p.units) : String(t.qty),
        };
      }),
      paymentMethods: methods.map((m) => ({ method: m.paymentMethod, total: m._sum.total ?? 0, count: m._count._all })),
      topPartners: partners.map((p) => ({
        partnerId: p.partnerId,
        institutionName: partnerName.get(p.partnerId),
        total: p._sum.total ?? 0,
        orders: p._count._all,
      })),
    },
  });
});

router.get('/inventory', async (_req, res) => {
  const since30 = addDays(new Date(), -30);
  const since60 = addDays(new Date(), -60);
  const [summary, byCategory, movementTotals, moved] = await Promise.all([
    inventorySummary(),
    prisma.$queryRaw`
      SELECT c.name AS category, COUNT(p.id) AS skuCount, COALESCE(SUM(p.stock * p.costPrice), 0) AS stockValue
      FROM categories c
      LEFT JOIN products p ON p.categoryId = c.id AND p.isActive = true
      GROUP BY c.id, c.name
      ORDER BY stockValue DESC`,
    prisma.stockMovement.groupBy({
      by: ['type'],
      where: { createdAt: { gte: since30 } },
      _sum: { qty: true },
      _count: { _all: true },
    }),
    prisma.stockMovement.groupBy({
      by: ['productId'],
      where: { type: { in: ['SALE', 'B2B_ORDER'] }, createdAt: { gte: since60 } },
    }),
  ]);
  // Barang tidak bergerak (dead stock): ada stok tetapi tidak terjual 60 hari terakhir.
  const dead = await prisma.product.findMany({
    where: { isActive: true, stock: { gt: 0 }, id: { notIn: moved.map((m) => m.productId) } },
    include: { units: true, category: true },
  });
  const deadStock = dead
    .map((p) => ({
      productId: p.id,
      sku: p.sku,
      name: p.name,
      category: p.category.name,
      stockDisplay: formatQty(p.stock, p.units),
      stockValue: p.stock * p.costPrice,
    }))
    .sort((a, b) => b.stockValue - a.stockValue);

  res.json({
    data: {
      summary,
      byCategory: byCategory.map((r) => ({
        category: r.category,
        skuCount: Number(r.skuCount),
        stockValue: Number(r.stockValue),
      })),
      movements30d: movementTotals.map((m) => ({ type: m.type, count: m._count._all, qty: m._sum.qty ?? 0 })),
      deadStock: {
        count: deadStock.length,
        value: deadStock.reduce((s, d) => s + d.stockValue, 0),
        top: deadStock.slice(0, 10),
      },
    },
  });
});

export default router;
