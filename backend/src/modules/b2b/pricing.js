// Aturan harga bertingkat (tiering) B2B — fungsi murni.
// Harga tier dinyatakan per satuan terkecil. Tier dipilih berdasarkan TOTAL kuantitas
// produk tersebut dalam satu PO (gabungan semua baris dengan satuan berbeda).
import { badRequest } from '../../lib/errors.js';

export const sortTiers = (tiers) => [...tiers].sort((a, b) => a.minQty - b.minQty);

export function normalizeTiers(tiers = []) {
  const sorted = sortTiers(
    tiers.map((t) => ({ minQty: Number(t.minQty), unitPrice: Number(t.unitPrice) })),
  );
  for (let i = 0; i < sorted.length; i++) {
    const t = sorted[i];
    if (!Number.isInteger(t.minQty) || t.minQty < 1) throw badRequest('Minimal kuantitas tier harus ≥ 1');
    if (!Number.isInteger(t.unitPrice) || t.unitPrice < 0) throw badRequest('Harga tier tidak valid');
    if (i > 0 && t.minQty === sorted[i - 1].minQty) throw badRequest(`Tier dengan minimal ${t.minQty} duplikat`);
    if (i > 0 && t.unitPrice > sorted[i - 1].unitPrice) {
      throw badRequest('Harga tier harus semakin murah (atau sama) untuk kuantitas yang lebih besar');
    }
  }
  return sorted;
}

/**
 * Harga per satuan terkecil untuk kuantitas tertentu.
 * @returns {{unitPrice:number, tier:object|null, nextTier:{minQty:number,unitPrice:number,needed:number}|null}}
 */
export function resolveTierPrice(baseQty, tiers, fallbackUnitPrice) {
  const sorted = sortTiers(tiers ?? []);
  let current = null;
  for (const t of sorted) if (t.minQty <= baseQty) current = t;
  const next = sorted.find((t) => t.minQty > baseQty) ?? null;
  return {
    unitPrice: current ? current.unitPrice : fallbackUnitPrice,
    tier: current,
    nextTier: next ? { minQty: next.minQty, unitPrice: next.unitPrice, needed: next.minQty - baseQty } : null,
  };
}

/** Harga awal B2B (kuantitas terkecil) untuk ditampilkan di katalog. */
export function startingPrice(tiers, fallbackUnitPrice) {
  return resolveTierPrice(1, tiers, fallbackUnitPrice).unitPrice;
}

/**
 * Hitung total PO: subtotal (harga tier) → diskon level mitra → PPN.
 * @param {{baseQty:number, unitPrice:number}[]} lines unitPrice per satuan terkecil
 */
export function priceOrder(lines, { discountPercent = 0, taxPercent = 0 } = {}) {
  const priced = lines.map((l) => ({ ...l, subtotal: l.unitPrice * l.baseQty }));
  const subtotal = priced.reduce((s, l) => s + l.subtotal, 0);
  const discount = Math.round((subtotal * discountPercent) / 100);
  const taxBase = subtotal - discount;
  const tax = Math.round((taxBase * taxPercent) / 100);
  return { lines: priced, subtotal, discount, taxBase, tax, total: taxBase + tax };
}
