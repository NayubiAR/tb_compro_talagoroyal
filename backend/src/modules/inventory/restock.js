import { prisma } from '../../lib/prisma.js';
import { addDays } from '../../lib/dates.js';
import { formatQty, sortUnits } from './units.js';

const LEVEL_RANK = { HABIS: 0, KRITIS: 1, WASPADA: 2 };

/**
 * Smart Restock Alert.
 *  - Kecepatan jual dihitung dari ledger 30 hari terakhir (penjualan kasir + PO B2B − retur).
 *  - Fast-moving = 20% produk teratas berdasarkan volume keluar (prinsip Pareto).
 *  - Level:
 *      HABIS   : stok 0
 *      KRITIS  : stok ≤ reorder point
 *      WASPADA : stok masih di atas reorder point, tetapi diperkirakan habis sebelum
 *                pasokan baru datang (hari ketersediaan ≤ lead time + 3 hari)
 *  - Saran jumlah pesan ulang = kebutuhan (lead time + 14 hari) + reorder point − stok,
 *    dibulatkan ke satuan terbesar (mis. per Dus) agar mudah dipesan ke pemasok.
 */
export async function computeRestockAlerts({ days = 30 } = {}) {
  const since = addDays(new Date(), -days);
  const usage = await prisma.stockMovement.groupBy({
    by: ['productId'],
    where: { type: { in: ['SALE', 'B2B_ORDER', 'RETURN'] }, createdAt: { gte: since } },
    _sum: { qty: true },
  });
  const usageMap = new Map(usage.map((u) => [u.productId, Math.max(0, -(u._sum.qty ?? 0))]));
  const velocities = [...usageMap.values()].filter((v) => v > 0).sort((a, b) => b - a);
  const fastCut = velocities.length ? velocities[Math.max(0, Math.ceil(velocities.length * 0.2) - 1)] : Infinity;

  const products = await prisma.product.findMany({
    where: { isActive: true },
    select: {
      id: true,
      sku: true,
      name: true,
      stock: true,
      reorderPoint: true,
      leadTimeDays: true,
      costPrice: true,
      category: { select: { name: true } },
      units: true,
    },
  });

  const alerts = [];
  for (const p of products) {
    const sold = usageMap.get(p.id) ?? 0;
    const avgDaily = sold / days;
    const daysOfCover = avgDaily > 0 ? p.stock / avgDaily : null;
    const fastMoving = sold > 0 && sold >= fastCut;
    let level = null;
    if (p.stock <= 0) level = 'HABIS';
    else if (p.stock <= p.reorderPoint) level = 'KRITIS';
    else if (daysOfCover !== null && daysOfCover <= p.leadTimeDays + 3) level = 'WASPADA';
    if (!level) continue;

    const target = Math.max(p.reorderPoint * 2, Math.ceil(avgDaily * (p.leadTimeDays + 14)) + p.reorderPoint);
    let suggested = Math.max(0, target - p.stock);
    const top = sortUnits(p.units)[0];
    if (suggested > 0 && top) suggested = Math.ceil(suggested / top.conversion) * top.conversion;

    alerts.push({
      productId: p.id,
      sku: p.sku,
      name: p.name,
      category: p.category?.name ?? null,
      level,
      fastMoving,
      stock: p.stock,
      stockDisplay: formatQty(p.stock, p.units),
      reorderPoint: p.reorderPoint,
      reorderDisplay: formatQty(p.reorderPoint, p.units),
      leadTimeDays: p.leadTimeDays,
      soldLast30Days: sold,
      soldDisplay: formatQty(sold, p.units),
      avgDailyUsage: Math.round(avgDaily * 100) / 100,
      daysOfCover: daysOfCover === null ? null : Math.round(daysOfCover * 10) / 10,
      suggestedOrderQty: suggested,
      suggestedOrderDisplay: formatQty(suggested, p.units),
      estimatedCost: suggested * p.costPrice,
    });
  }

  alerts.sort(
    (a, b) =>
      LEVEL_RANK[a.level] - LEVEL_RANK[b.level] ||
      Number(b.fastMoving) - Number(a.fastMoving) ||
      (a.daysOfCover ?? 0) - (b.daysOfCover ?? 0) ||
      b.soldLast30Days - a.soldLast30Days,
  );

  const counts = { HABIS: 0, KRITIS: 0, WASPADA: 0, fastMoving: 0 };
  for (const a of alerts) {
    counts[a.level]++;
    if (a.fastMoving) counts.fastMoving++;
  }
  return { alerts, counts, generatedAt: new Date() };
}

/** Ringkasan gudang: jumlah SKU, valuasi aset (HPP) & potensi omzet. */
export async function inventorySummary() {
  const [row] = await prisma.$queryRaw`
    SELECT
      COUNT(*) AS totalSku,
      COALESCE(SUM(p.stock * p.costPrice), 0) AS stockValue,
      COALESCE(SUM(p.stock * u.price), 0) AS retailValue,
      COALESCE(SUM(CASE WHEN p.stock <= 0 THEN 1 ELSE 0 END), 0) AS outCount,
      COALESCE(SUM(CASE WHEN p.stock > 0 AND p.stock <= p.reorderPoint THEN 1 ELSE 0 END), 0) AS lowCount
    FROM products p
    LEFT JOIN product_units u ON u.productId = p.id AND u.conversion = 1
    WHERE p.isActive = true`;
  return {
    totalSku: Number(row.totalSku),
    stockValue: Number(row.stockValue),
    retailValue: Number(row.retailValue),
    outCount: Number(row.outCount),
    lowCount: Number(row.lowCount),
  };
}
