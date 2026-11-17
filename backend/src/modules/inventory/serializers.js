import { breakdown, describeHierarchy, formatQty, sortUnits, baseUnitOf } from './units.js';
import { sortTiers } from '../b2b/pricing.js';
import { stockStatusOf } from './stock.js';

export const productInclude = { category: true, units: true, priceTiers: true };

export function productDto(p) {
  const units = sortUnits(p.units ?? []);
  const base = baseUnitOf(units);
  return {
    id: p.id,
    sku: p.sku,
    name: p.name,
    description: p.description,
    categoryId: p.categoryId,
    category: p.category ? { id: p.category.id, name: p.category.name } : null,
    baseUnit: p.baseUnit,
    stock: p.stock,
    stockDisplay: formatQty(p.stock, units),
    stockBreakdown: breakdown(p.stock, units),
    stockStatus: stockStatusOf(p),
    reorderPoint: p.reorderPoint,
    reorderDisplay: formatQty(p.reorderPoint, units),
    leadTimeDays: p.leadTimeDays,
    costPrice: p.costPrice,
    retailPrice: base?.price ?? 0,
    stockValue: p.stock * p.costPrice,
    hierarchy: describeHierarchy(units),
    units: units.map((u) => ({ name: u.name, conversion: u.conversion, price: u.price })),
    priceTiers: sortTiers(p.priceTiers ?? []).map((t) => ({ minQty: t.minQty, unitPrice: t.unitPrice })),
    isActive: p.isActive,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  };
}

export function movementDto(m) {
  const units = m.product?.units ?? [];
  return {
    id: m.id,
    createdAt: m.createdAt,
    type: m.type,
    qty: m.qty,
    qtyDisplay: formatQty(m.qty, units),
    balanceAfter: m.balanceAfter,
    balanceDisplay: formatQty(m.balanceAfter, units),
    unitName: m.unitName,
    unitQty: m.unitQty,
    refType: m.refType,
    refId: m.refId,
    refCode: m.refCode,
    note: m.note,
    product: m.product ? { id: m.product.id, sku: m.product.sku, name: m.product.name } : undefined,
    user: m.user ? m.user.name : null,
  };
}

/**
 * Pencarian multi-kata: "hvs a4" cocok dengan "Kertas HVS A4 70gsm".
 * Setiap kata harus ada di nama ATAU SKU.
 */
export function textSearch(q) {
  const words = String(q ?? '')
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 6);
  return words.map((w) => ({ OR: [{ name: { contains: w } }, { sku: { contains: w } }] }));
}
