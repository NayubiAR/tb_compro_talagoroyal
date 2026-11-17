// Kalkulator tarif cetak — fungsi murni.
import { badRequest } from '../../lib/errors.js';

export const PAPER_SIZES = ['A4', 'F4', 'A3'];
export const COLOR_MODES = ['BW', 'COLOR'];
export const BINDINGS = ['NONE', 'LAKBAN', 'SPIRAL'];
export const ORIENTATIONS = ['PORTRAIT', 'LANDSCAPE'];

/**
 * Hitung jumlah halaman dari rentang seperti "1-5, 8, 10-12".
 * Kosong → semua halaman. Halaman duplikat hanya dihitung sekali.
 */
export function countRangePages(range, pageCount) {
  if (!range || !String(range).trim()) return { pages: pageCount, normalized: null };
  const pages = new Set();
  for (const raw of String(range).split(',')) {
    const part = raw.trim();
    if (!part) continue;
    const m = /^(\d+)(?:\s*-\s*(\d+))?$/.exec(part);
    if (!m) throw badRequest(`Format rentang halaman "${part}" tidak valid. Contoh: 1-5, 8, 10-12`);
    const from = Number(m[1]);
    const to = m[2] ? Number(m[2]) : from;
    if (from < 1 || to < from || to > pageCount) {
      throw badRequest(`Rentang "${part}" di luar jumlah halaman dokumen (1–${pageCount})`);
    }
    for (let p = from; p <= to; p++) pages.add(p);
  }
  if (!pages.size) return { pages: pageCount, normalized: null };
  return { pages: pages.size, normalized: compressPages([...pages].sort((a, b) => a - b)) };
}

function compressPages(sorted) {
  const out = [];
  let start = sorted[0];
  let prev = sorted[0];
  for (const p of sorted.slice(1).concat(Infinity)) {
    if (p === prev + 1) {
      prev = p;
      continue;
    }
    out.push(start === prev ? `${start}` : `${start}-${prev}`);
    start = prev = p;
  }
  return out.join(',');
}

/**
 * @param {{paperSize:string,colorMode:string,binding:string,copies:number,duplex:boolean,pageRange?:string}} cfg
 * @param {number} pageCount jumlah halaman dokumen
 * @param {{pricePerPage:object, binding:object}} pricing tarif dari pengaturan toko
 */
export function quotePrint(cfg, pageCount, pricing) {
  const { pages, normalized } = countRangePages(cfg.pageRange, pageCount);
  const pricePerPage = pricing.pricePerPage?.[cfg.paperSize]?.[cfg.colorMode];
  if (!Number.isInteger(pricePerPage)) throw badRequest('Kombinasi ukuran kertas & warna tidak tersedia');
  const copies = cfg.copies;
  const bindingUnitPrice = cfg.binding === 'NONE' ? 0 : (pricing.binding?.[cfg.binding] ?? 0);
  const printCost = pages * copies * pricePerPage;
  const bindingCost = bindingUnitPrice * copies;
  const sheetsPerCopy = cfg.duplex ? Math.ceil(pages / 2) : pages;
  return {
    pagesToPrint: pages,
    pageRange: normalized,
    copies,
    pricePerPage,
    printCost,
    bindingUnitPrice,
    bindingCost,
    sheets: sheetsPerCopy * copies,
    total: printCost + bindingCost,
  };
}
