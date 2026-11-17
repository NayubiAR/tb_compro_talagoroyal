// Logika konversi multi-satuan (murni, tanpa database) — mudah diuji unit test.
// Konsep: setiap produk punya satu satuan terkecil (conversion = 1). Satuan lain
// dinyatakan sebagai kelipatan satuan terkecil, mis. Dus=60, Pak=12, Pcs=1.
import { badRequest } from '../../lib/errors.js';

export const sortUnits = (units) => [...units].sort((a, b) => b.conversion - a.conversion);

/**
 * Validasi & normalisasi hierarki satuan. Aturan:
 *  - nama unik (tidak peka huruf besar/kecil), konversi bilangan bulat ≥ 1 dan unik
 *  - wajib ada satuan terkecil dengan konversi 1
 *  - bertingkat: konversi satuan yang lebih besar habis dibagi satuan di bawahnya
 *    (1 Dus = 5 Pak = 60 Pcs valid; Dus=50 & Pak=12 tidak valid)
 */
export function normalizeUnits(units) {
  if (!Array.isArray(units) || units.length === 0) throw badRequest('Minimal harus ada satu satuan');
  const seen = new Set();
  const cleaned = units.map((u) => {
    const name = String(u.name ?? '').trim();
    const conversion = Number(u.conversion);
    const price = Number(u.price ?? 0);
    if (!name) throw badRequest('Nama satuan wajib diisi');
    const key = name.toLowerCase();
    if (seen.has(key)) throw badRequest(`Nama satuan "${name}" duplikat`);
    seen.add(key);
    if (!Number.isInteger(conversion) || conversion < 1) {
      throw badRequest(`Konversi satuan "${name}" harus bilangan bulat ≥ 1`);
    }
    if (!Number.isInteger(price) || price < 0) throw badRequest(`Harga satuan "${name}" tidak valid`);
    return { name, conversion, price };
  });
  const sorted = sortUnits(cleaned);
  if (sorted.at(-1).conversion !== 1) throw badRequest('Harus ada satuan terkecil dengan konversi 1');
  for (let i = 0; i < sorted.length - 1; i++) {
    const big = sorted[i];
    const small = sorted[i + 1];
    if (big.conversion === small.conversion) {
      throw badRequest(`Satuan "${big.name}" dan "${small.name}" memiliki konversi yang sama`);
    }
    if (big.conversion % small.conversion !== 0) {
      throw badRequest(
        `Hierarki tidak bertingkat: 1 ${big.name} (${big.conversion}) tidak habis dibagi ${small.name} (${small.conversion})`,
      );
    }
  }
  return sorted;
}

export const baseUnitOf = (units) => units.find((u) => u.conversion === 1);

/** Cari satuan berdasarkan nama (tanpa nama → satuan terkecil). */
export function findUnit(units, name) {
  if (name === undefined || name === null || name === '') return baseUnitOf(units);
  const key = String(name).trim().toLowerCase();
  return units.find((u) => u.name.toLowerCase() === key);
}

export function toBase(qty, unit) {
  return qty * unit.conversion;
}

/** Pecah jumlah satuan terkecil menjadi satuan bertingkat, mis. 125 → 2 Dus 5 Pcs. */
export function breakdown(baseQty, units) {
  const sign = baseQty < 0 ? -1 : 1;
  let rest = Math.abs(baseQty);
  const parts = [];
  for (const u of sortUnits(units)) {
    const q = Math.floor(rest / u.conversion);
    rest -= q * u.conversion;
    if (q > 0) parts.push({ unit: u.name, qty: q * sign });
  }
  return parts;
}

export function formatQty(baseQty, units) {
  if (!units?.length) return String(baseQty);
  const parts = breakdown(baseQty, units);
  if (!parts.length) return `0 ${baseUnitOf(units)?.name ?? ''}`.trim();
  return (baseQty < 0 ? '-' : '') + parts.map((p) => `${Math.abs(p.qty)} ${p.unit}`).join(' ');
}

/** Deskripsi hierarki, mis. "1 Dus = 5 Pak = 60 Pcs". */
export function describeHierarchy(units) {
  const sorted = sortUnits(units);
  if (!sorted.length) return '';
  const top = sorted[0];
  return sorted.map((u, i) => (i === 0 ? `1 ${u.name}` : `${top.conversion / u.conversion} ${u.name}`)).join(' = ');
}

/** Jumlahkan hitungan campuran satuan (mis. hasil stock opname 2 Dus + 3 Pak + 4 Pcs). */
export function sumCounts(counts, units) {
  let total = 0;
  for (const c of counts) {
    const unit = findUnit(units, c.unitName);
    if (!unit) throw badRequest(`Satuan "${c.unitName}" tidak dikenal`);
    if (!Number.isInteger(c.qty) || c.qty < 0) throw badRequest('Jumlah hitungan harus bilangan bulat ≥ 0');
    total += toBase(c.qty, unit);
  }
  return total;
}
