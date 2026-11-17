// Seeder data demo Talago Royal.
// Menghasilkan: >1.000 SKU multi-satuan, riwayat 30 hari (penjualan kasir, PO B2B, cetak),
// faktur dengan status lunas / sebagian / jatuh tempo, antrean cetak aktif, dan
// kondisi stok yang memicu Smart Restock Alert. Seluruh data AKAN DIHAPUS lalu dibuat ulang.
import '../src/config/timezone.js';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import bcrypt from 'bcryptjs';
import { PrismaClient } from '@prisma/client';
import { CATALOG, UNITSETS } from './seed-data/catalog.js';
import { resolveTierPrice, priceOrder } from '../src/modules/b2b/pricing.js';
import { quotePrint } from '../src/modules/printing/pricing.js';
import { SETTING_DEFAULTS } from '../src/lib/settings.js';
import { generateSamples, SAMPLE_PDFS, SAMPLE_DOCX } from '../scripts/generate-samples.js';

if (process.env.NODE_ENV === 'production' && process.env.FORCE_SEED !== 'true') {
  console.error('Seeder menghapus seluruh data. Set FORCE_SEED=true jika benar-benar ingin menjalankan di production.');
  process.exit(1);
}

const prisma = new PrismaClient();
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PRINT_DIR = path.resolve(ROOT, process.env.UPLOAD_DIR || 'uploads', 'print');
const SAMPLE_DIR = path.join(ROOT, 'samples');

// ───────────── Utilitas ─────────────

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(20261118);
const randInt = (a, b) => a + Math.floor(rand() * (b - a + 1));
const pick = (arr) => arr[Math.floor(rand() * arr.length)];
const pad = (n, len = 4) => String(n).padStart(len, '0');
const roundTo = (n, step) => Math.max(step, Math.round(n / step) * step);
const ymd = (d, sep = '') =>
  [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join(sep);
const NOW = new Date();
const minutesAgo = (m) => new Date(NOW.getTime() - m * 60_000);
function daysAgoAt(days, hour, minute = 0) {
  const d = new Date(NOW);
  d.setDate(d.getDate() - days);
  d.setHours(hour, minute, randInt(0, 59), 0);
  return d;
}
async function chunked(rows, size, fn) {
  for (let i = 0; i < rows.length; i += size) await fn(rows.slice(i, i + size));
}

const counters = new Map();
function docCode(prefix, date, period = 'month') {
  const stamp = period === 'day' ? ymd(date).slice(2) : ymd(date).slice(2, 6);
  const key = `${prefix}-${stamp}`;
  const n = (counters.get(key) ?? 0) + 1;
  counters.set(key, n);
  return `${key}-${pad(n)}`;
}

// ───────────── 1. Bersihkan data ─────────────

async function wipe() {
  const order = [
    'notification', 'auditLog', 'payment', 'printJob', 'invoicePayment', 'invoice', 'purchaseOrderItem',
    'purchaseOrder', 'saleItem', 'sale', 'stockOpnameItem', 'stockOpname', 'stockReceiptItem', 'stockReceipt',
    'stockMovement', 'priceTier', 'productUnit', 'product', 'category', 'partner', 'partnerLevel', 'user',
    'setting', 'counter',
  ];
  for (const model of order) await prisma[model].deleteMany();
  await fs.rm(PRINT_DIR, { recursive: true, force: true });
  await fs.mkdir(PRINT_DIR, { recursive: true });
}

// ───────────── 2. Katalog produk ─────────────

function unitPrices(unitset, basePrice) {
  const discounts = unitset.length === 3 ? [0.9, 0.95, 1] : unitset.length === 2 ? [0.92, 1] : [1];
  return unitset.map(([name, conversion], i) => ({
    name,
    conversion,
    price: conversion === 1 ? basePrice : roundTo(basePrice * conversion * discounts[i], conversion >= 100 ? 500 : 100),
  }));
}

function tierPrices(unitset, basePrice) {
  const top = unitset[0][1];
  const step = basePrice >= 1000 ? 50 : basePrice >= 100 ? 5 : 1;
  const thresholds = top > 1 ? [1, top, top * 10] : [1, 5, 20];
  const factors = [0.93, 0.87, 0.82];
  let last = Infinity;
  return thresholds.map((minQty, i) => {
    const unitPrice = Math.min(last, roundTo(basePrice * factors[i], step));
    last = unitPrice;
    return { minQty, unitPrice };
  });
}

function buildCatalog(categoryIds) {
  const products = [];
  for (const cat of CATALOG) {
    let n = 0;
    for (const t of cat.items) {
      t.brands.forEach((brand, bi) => {
        for (const v of t.variants) {
          const [label, mult] = Array.isArray(v) ? v : [v, 1];
          n++;
          const brandMult = [1, 1.08, 0.94, 1.12, 1.2, 0.97][bi % 6];
          const raw = t.price * mult * brandMult;
          const basePrice = roundTo(raw, raw >= 1000 ? 100 : raw >= 100 ? 10 : 1);
          const unitset = UNITSETS[t.units];
          const top = unitset[0][1];
          products.push({
            sku: `${cat.code}-${pad(n)}`,
            name: t.name.replace('{b}', brand).replace('{v}', label).replace(/\s+/g, ' ').trim(),
            categoryId: categoryIds[cat.category],
            baseUnit: unitset.at(-1)[0],
            costPrice: Math.round(basePrice * (0.72 + rand() * 0.08)),
            reorderPoint: top > 1 ? top * (t.pop >= 6 ? 2 : 1) : 2,
            leadTimeDays: t.lead ?? randInt(3, 5),
            units: unitPrices(unitset, basePrice),
            tiers: tierPrices(unitset, basePrice),
            pop: t.pop,
            unitsetKey: t.units,
          });
        }
      });
    }
  }
  return products;
}

// ───────────── 3. Simulasi transaksi ─────────────

function unitOf(p, name) {
  return p.units.find((u) => u.name === name);
}

function randomSaleLine(p) {
  const us = p.units; // terurut dari terbesar
  let unit;
  if (us.length === 1) unit = us[0];
  else if (p.unitsetKey === 'paper') unit = rand() < 0.85 ? us[1] : us[0];
  else {
    const r = rand();
    unit = r < 0.62 ? us.at(-1) : r < 0.96 ? us.at(-2) : us[0];
  }
  const qty = unit.conversion === 1 ? randInt(1, 6) : unit === us[0] && us.length > 1 ? 1 : randInt(1, 2);
  return { p, unit, qty, baseQty: qty * unit.conversion };
}

async function main() {
  console.log('▶ Menghapus data lama...');
  await wipe();

  console.log('▶ Pengaturan, level mitra & pengguna...');
  await prisma.setting.createMany({
    data: [
      {
        key: 'store_profile',
        value: { ...SETTING_DEFAULTS.store_profile, address: 'Alamat toko (ubah di menu Pengaturan)' },
      },
      { key: 'print_pricing', value: SETTING_DEFAULTS.print_pricing },
      { key: 'b2b', value: SETTING_DEFAULTS.b2b },
    ],
  });
  const levels = {};
  for (const [name, discountPercent, description] of [
    ['Reguler', 0, 'Mitra baru'],
    ['Silver', 2, 'Belanja rutin ≥ Rp 5 jt/bulan'],
    ['Gold', 4, 'Belanja rutin ≥ Rp 15 jt/bulan'],
    ['Platinum', 6, 'Belanja rutin ≥ Rp 40 jt/bulan'],
  ]) {
    levels[name] = await prisma.partnerLevel.create({ data: { name, discountPercent, description } });
  }

  const passwordHash = await bcrypt.hash('password123', 10);
  const mkUser = (data) => prisma.user.create({ data: { passwordHash, ...data }, include: { partner: true } });
  const users = {
    owner: await mkUser({ name: 'Pemilik Talago Royal', email: 'owner@talago.test', phone: '081200000001', role: 'OWNER' }),
    admin: await mkUser({ name: 'Admin Gudang', email: 'admin@talago.test', phone: '081200000002', role: 'ADMIN' }),
    kasir: await mkUser({ name: 'Kasir Toko', email: 'kasir@talago.test', phone: '081200000003', role: 'ADMIN' }),
    mitra: await mkUser({
      name: 'Ratna Dewi (TU)',
      email: 'mitra@talago.test',
      phone: '081300000001',
      role: 'B2B',
      partner: {
        create: {
          institutionName: 'SMA Negeri 1 Contoh',
          institutionType: 'SEKOLAH',
          npwp: '00.000.000.0-000.000',
          address: 'Jl. Pendidikan No. 10, Kota Contoh',
          status: 'VERIFIED',
          levelId: levels.Gold.id,
          paymentTermDays: 30,
          creditLimit: 25_000_000,
          verifiedAt: daysAgoAt(60, 10),
        },
      },
    }),
    mitra2: await mkUser({
      name: 'Andi Pratama (Purchasing)',
      email: 'mitra2@talago.test',
      phone: '081300000002',
      role: 'B2B',
      partner: {
        create: {
          institutionName: 'PT Maju Bersama Sejahtera',
          institutionType: 'PERUSAHAAN',
          npwp: '01.234.567.8-901.000',
          address: 'Kawasan Niaga Blok B-7, Kota Contoh',
          status: 'VERIFIED',
          levelId: levels.Silver.id,
          paymentTermDays: 14,
          creditLimit: 0,
          verifiedAt: daysAgoAt(45, 10),
        },
      },
    }),
    mitra3: await mkUser({
      name: 'Sekretariat Dinas Pendidikan',
      email: 'mitra3@talago.test',
      phone: '081300000003',
      role: 'B2B',
      partner: {
        create: {
          institutionName: 'Dinas Pendidikan Kota Contoh',
          institutionType: 'INSTANSI',
          address: 'Jl. Balai Kota No. 2, Kota Contoh',
          status: 'PENDING',
        },
      },
    }),
    pelanggan: await mkUser({ name: 'Rina Mahasiswi', email: 'pelanggan@talago.test', phone: '085700000001', role: 'CUSTOMER' }),
    pelanggan2: await mkUser({ name: 'Budi Santoso', email: 'pelanggan2@talago.test', phone: '085700000002', role: 'CUSTOMER' }),
  };

  console.log('▶ Katalog produk multi-satuan...');
  const categoryIds = {};
  for (const cat of CATALOG) categoryIds[cat.category] = (await prisma.category.create({ data: { name: cat.category } })).id;
  const catalog = buildCatalog(categoryIds);
  await chunked(catalog, 500, (rows) =>
    prisma.product.createMany({
      data: rows.map(({ units, tiers, pop, unitsetKey, ...p }) => p),
    }),
  );
  const idBySku = new Map((await prisma.product.findMany({ select: { id: true, sku: true } })).map((p) => [p.sku, p.id]));
  for (const p of catalog) p.id = idBySku.get(p.sku);
  await chunked(catalog.flatMap((p) => p.units.map((u) => ({ ...u, productId: p.id }))), 1000, (rows) =>
    prisma.productUnit.createMany({ data: rows }),
  );
  await chunked(catalog.flatMap((p) => p.tiers.map((t) => ({ ...t, productId: p.id }))), 1000, (rows) =>
    prisma.priceTier.createMany({ data: rows }),
  );
  console.log(`  ${catalog.length} SKU dibuat`);
  const byName = new Map(catalog.map((p) => [p.name, p]));
  const P = (name) => {
    const p = byName.get(name);
    if (!p) throw new Error(`Produk seed tidak ditemukan: ${name}`);
    return p;
  };

  // ── Event penjualan kasir 30 hari ──
  console.log('▶ Simulasi transaksi 30 hari...');
  const sellable = catalog.filter((p) => p.pop > 0).map((p) => ({ p, w: p.pop ** 2 * (0.4 + rand()) }));
  const totalW = sellable.reduce((s, x) => s + x.w, 0);
  const pickProduct = () => {
    let r = rand() * totalW;
    for (const x of sellable) if ((r -= x.w) <= 0) return x.p;
    return sellable.at(-1).p;
  };

  const events = []; // { at, kind, ... }
  for (let d = 30; d >= 0; d--) {
    const count = d === 0 ? randInt(6, 10) : randInt(14, 28);
    for (let i = 0; i < count; i++) {
      const at = d === 0 ? minutesAgo(randInt(5, 360)) : daysAgoAt(d, randInt(8, 19), randInt(0, 59));
      const lines = [];
      const used = new Set();
      for (let k = randInt(1, 4); k > 0; k--) {
        const p = pickProduct();
        if (used.has(p.sku)) continue;
        used.add(p.sku);
        lines.push(randomSaleLine(p));
      }
      events.push({ at, kind: 'SALE', lines, cashier: rand() < 0.6 ? users.kasir : users.admin });
    }
  }

  // ── PO B2B ──
  const PO_DEFS = [
    {
      user: users.mitra, level: levels.Gold, term: 30, days: 38, status: 'COMPLETED', invoice: 'UNPAID',
      partnerRef: 'SPK/027/SMAN1/IX', note: 'Kebutuhan ATK semester ganjil',
      items: [['Pulpen Standard AE7 0.5 Hitam', 'Dus', 4], ['Kertas HVS A4 70gsm SiDU', 'Rim', 30], ['Map Plastik Kancing Bantex Folio Biru', 'Pak', 6], ['Spidol Whiteboard Snowman Hitam', 'Pak', 4]],
    },
    {
      user: users.mitra, level: levels.Gold, term: 30, days: 25, status: 'COMPLETED', invoice: 'PAID',
      partnerRef: 'SPK/031/SMAN1/X',
      items: [['Buku Tulis Sinar Dunia 38 Lembar', 'Dus', 2], ['Pensil Faber-Castell 1990 2B', 'Pak', 10], ['Penghapus Faber-Castell Kecil', 'Pak', 6], ['Isi Staples Max No. 10', 'Pak', 5]],
    },
    {
      user: users.mitra2, level: levels.Silver, term: 14, days: 12, status: 'APPROVED', invoice: 'PARTIAL',
      partnerRef: 'PR-MBS-1108',
      items: [['Kertas HVS F4 70gsm PaperOne', 'Dus', 3], ['Amplop Putih Paperline No. 90', 'Box', 5], ['Lakban Cokelat 2 inch Nachi', 'Slop', 4], ['Ordner Bantex Folio Biru', 'Pcs', 12]],
    },
    {
      user: users.mitra2, level: levels.Silver, term: 14, days: 20, status: 'REJECTED', reason: 'Barang yang diminta sedang tidak tersedia, silakan ajukan ulang minggu depan.',
      items: [['Toner HP 85A', 'Pcs', 10]],
    },
    {
      user: users.mitra, level: levels.Gold, term: 30, days: 3, status: 'READY', invoice: 'UNPAID',
      partnerRef: 'SPK/036/SMAN1/XI', note: 'Untuk ujian akhir semester',
      items: [['Kertas HVS A4 70gsm SiDU', 'Dus', 2], ['Pulpen Standard AE7 0.5 Biru', 'Dus', 2], ['Stopmap Kertas Diamond Merah', 'Pak', 4]],
    },
    {
      user: users.mitra, level: levels.Gold, term: 30, days: 0, status: 'SUBMITTED',
      partnerRef: 'SPK/040/SMAN1/XI', note: 'Mohon disiapkan sebelum hari Jumat',
      items: [['Pulpen Standard AE7 0.5 Hitam', 'Dus', 1], ['Buku Tulis Sinar Dunia 58 Lembar', 'Pak', 10], ['Spidol Whiteboard Snowman Biru', 'Pak', 2]],
    },
  ];
  const taxPercent = SETTING_DEFAULTS.b2b.taxPercent;
  for (const def of PO_DEFS) {
    const createdAt = def.days === 0 ? minutesAgo(50) : daysAgoAt(def.days, 9, randInt(0, 30));
    const lines = def.items.map(([name, unitName, qty]) => {
      const p = P(name);
      const unit = unitOf(p, unitName);
      if (!unit) throw new Error(`Satuan ${unitName} tidak ada untuk ${name}`);
      return { p, unit, qty, baseQty: qty * unit.conversion };
    });
    const totals = new Map();
    for (const l of lines) totals.set(l.p.sku, (totals.get(l.p.sku) ?? 0) + l.baseQty);
    for (const l of lines) {
      l.retailUnitPrice = l.p.units.at(-1).price;
      l.tierUnitPrice = resolveTierPrice(totals.get(l.p.sku), l.p.tiers, l.retailUnitPrice).unitPrice;
    }
    const priced = priceOrder(lines.map((l) => ({ baseQty: l.baseQty, unitPrice: l.tierUnitPrice })), {
      discountPercent: def.level.discountPercent,
      taxPercent,
    });
    const approvedAt = ['APPROVED', 'READY', 'COMPLETED'].includes(def.status)
      ? new Date(createdAt.getTime() + 4 * 3_600_000)
      : null;
    events.push({ at: createdAt, kind: 'PO', def, lines, priced, approvedAt });
  }

  // ── Stock opname 7 hari lalu (selisih kecil karena barang rusak/hilang) ──
  const opnameItems = ['Pulpen Gel Zebra Sarasa Hitam', 'Penghapus Joyko Kecil', 'Lem Kertas Stick UHU 8 gr', 'Correction Pen Kenko KE-108'].map(
    (n) => ({ p: P(n), diff: -randInt(1, 3) }),
  );
  events.push({ at: daysAgoAt(7, 17, 30), kind: 'OPNAME', lines: opnameItems });

  // ── Hitung kebutuhan stok agar saldo tidak pernah minus ──
  const out = new Map();
  const addOut = (sku, q) => out.set(sku, (out.get(sku) ?? 0) + q);
  for (const e of events) {
    if (e.kind === 'SALE') e.lines.forEach((l) => addOut(l.p.sku, l.baseQty));
    if (e.kind === 'PO' && e.approvedAt) e.lines.forEach((l) => addOut(l.p.sku, l.baseQty));
    if (e.kind === 'OPNAME') e.lines.forEach((l) => addOut(l.p.sku, -l.diff));
  }
  const pendingDemand = new Map();
  for (const e of events.filter((x) => x.kind === 'PO' && x.def.status === 'SUBMITTED')) {
    for (const l of e.lines) pendingDemand.set(l.p.sku, (pendingDemand.get(l.p.sku) ?? 0) + l.baseQty);
  }
  const protectedSkus = new Set([...pendingDemand.keys(), ...opnameItems.map((o) => o.p.sku)]);

  // Stok akhir: mayoritas aman, sebagian dibuat HABIS/KRITIS/WASPADA untuk demo Smart Restock Alert.
  const ranked = catalog.filter((p) => (out.get(p.sku) ?? 0) > 0 && !protectedSkus.has(p.sku)).sort((a, b) => out.get(b.sku) - out.get(a.sku));
  const habis = new Set([ranked[2], ranked[8], ranked[17], ranked[40]].filter(Boolean).map((p) => p.sku));
  const kritis = new Set([3, 5, 10, 13, 21, 26, 33, 55, 70].map((i) => ranked[i]).filter(Boolean).map((p) => p.sku));
  const waspada = new Set([6, 12, 19, 28].map((i) => ranked[i]).filter(Boolean).map((p) => p.sku));
  const pen = P('Pulpen Standard AE7 0.5 Hitam');
  for (const p of catalog) {
    const top = p.units[0].conversion;
    const sold = out.get(p.sku) ?? 0;
    let final;
    if (habis.has(p.sku)) final = 0;
    else if (kritis.has(p.sku)) final = randInt(Math.max(1, Math.floor(p.reorderPoint / 4)), p.reorderPoint);
    else if (waspada.has(p.sku)) {
      const daily = Math.max(1, Math.ceil(sold / 30));
      p.reorderPoint = daily;
      final = daily + daily * 3;
    } else final = p.reorderPoint + (top > 1 ? randInt(1, 6) * top : randInt(3, 12));
    if (p === pen) final = p.reorderPoint + 15; // aman, cukup untuk PO yang menunggu verifikasi
    final = Math.max(final, (pendingDemand.get(p.sku) ?? 0) + (pendingDemand.has(p.sku) ? p.reorderPoint + top : 0));
    p.finalStock = final;
    p.initialStock = sold + final;
  }

  // ───────────── 4. Tulis transaksi ─────────────
  console.log('▶ Menulis penerimaan barang, penjualan, PO & faktur...');
  const receiptAt = daysAgoAt(45, 8, 0);
  const receipt = await prisma.stockReceipt.create({
    data: {
      code: docCode('RCV', receiptAt),
      supplier: 'Saldo awal (migrasi dari pembukuan manual)',
      note: 'Stok awal sistem',
      userId: users.admin.id,
      createdAt: receiptAt,
    },
  });
  const receiptLines = catalog.filter((p) => p.initialStock > 0);
  await chunked(receiptLines, 1000, (rows) =>
    prisma.stockReceiptItem.createMany({
      data: rows.map((p) => ({
        receiptId: receipt.id,
        productId: p.id,
        unitName: p.baseUnit,
        unitQty: p.initialStock,
        baseQty: p.initialStock,
        unitCost: p.costPrice,
      })),
    }),
  );

  events.sort((a, b) => a.at - b.at);

  // Penjualan kasir
  const sales = events.filter((e) => e.kind === 'SALE' && e.lines.length);
  for (const e of sales) {
    e.code = docCode('POS', e.at, 'day');
    e.total = e.lines.reduce((s, l) => s + l.unit.price * l.qty, 0);
    const r = rand();
    e.method = r < 0.65 ? 'CASH' : r < 0.95 ? 'QRIS' : 'TRANSFER';
    e.paid = e.method === 'CASH' ? Math.ceil(e.total / 5000) * 5000 + (rand() < 0.3 ? 5000 : 0) : e.total;
  }
  await chunked(sales, 500, (rows) =>
    prisma.sale.createMany({
      data: rows.map((e) => ({
        code: e.code,
        cashierId: e.cashier.id,
        total: e.total,
        paymentMethod: e.method,
        paidAmount: e.paid,
        changeAmount: e.paid - e.total,
        createdAt: e.at,
      })),
    }),
  );
  const saleIds = new Map((await prisma.sale.findMany({ select: { id: true, code: true } })).map((s) => [s.code, s.id]));
  for (const e of sales) e.id = saleIds.get(e.code);
  await chunked(
    sales.flatMap((e) =>
      e.lines.map((l) => ({
        saleId: e.id,
        productId: l.p.id,
        unitName: l.unit.name,
        unitQty: l.qty,
        conversion: l.unit.conversion,
        baseQty: l.baseQty,
        unitPrice: l.unit.price,
        subtotal: l.unit.price * l.qty,
      })),
    ),
    1000,
    (rows) => prisma.saleItem.createMany({ data: rows }),
  );

  // PO + faktur
  for (const e of events.filter((x) => x.kind === 'PO')) {
    const { def, lines, priced, approvedAt } = e;
    const partner = def.user.partner;
    e.code = docCode('PO', e.at);
    const readyAt = ['READY', 'COMPLETED'].includes(def.status) ? new Date(approvedAt.getTime() + 20 * 3_600_000) : null;
    const po = await prisma.purchaseOrder.create({
      data: {
        poNumber: e.code,
        partnerId: partner.id,
        partnerRef: def.partnerRef ?? null,
        status: def.status,
        subtotal: priced.subtotal,
        levelName: def.level.name,
        levelDiscountPercent: def.level.discountPercent,
        discount: priced.discount,
        taxPercent,
        tax: priced.tax,
        total: priced.total,
        note: def.note ?? null,
        rejectionReason: def.reason ?? null,
        createdById: def.user.id,
        approvedById: approvedAt ? users.admin.id : null,
        approvedAt,
        readyAt,
        completedAt: def.status === 'COMPLETED' ? new Date(readyAt.getTime() + 24 * 3_600_000) : null,
        createdAt: e.at,
        items: {
          create: lines.map((l) => ({
            productId: l.p.id,
            sku: l.p.sku,
            productName: l.p.name,
            unitName: l.unit.name,
            unitQty: l.qty,
            conversion: l.unit.conversion,
            baseQty: l.baseQty,
            retailUnitPrice: l.retailUnitPrice,
            tierUnitPrice: l.tierUnitPrice,
            subtotal: l.tierUnitPrice * l.baseQty,
          })),
        },
      },
    });
    e.id = po.id;
    if (approvedAt && def.invoice) {
      const dueDate = new Date(approvedAt);
      dueDate.setDate(dueDate.getDate() + def.term);
      dueDate.setHours(23, 59, 59, 0);
      const paid = def.invoice === 'PAID' ? priced.total : def.invoice === 'PARTIAL' ? Math.round(priced.total / 2) : 0;
      const paidAt = new Date(approvedAt.getTime() + 8 * 86_400_000);
      await prisma.invoice.create({
        data: {
          invoiceNumber: docCode('INV', approvedAt),
          poId: po.id,
          partnerId: partner.id,
          issueDate: approvedAt,
          dueDate,
          subtotal: priced.subtotal,
          discount: priced.discount,
          tax: priced.tax,
          total: priced.total,
          amountPaid: paid,
          status: def.invoice,
          paidAt: def.invoice === 'PAID' ? paidAt : null,
          createdAt: approvedAt,
          payments: paid
            ? {
                create: {
                  amount: paid,
                  method: 'TRANSFER',
                  reference: `TRF-${randInt(100000, 999999)}`,
                  note: def.invoice === 'PARTIAL' ? 'Termin 1 (50%)' : 'Pelunasan',
                  paidAt,
                  recordedById: users.admin.id,
                },
              }
            : undefined,
        },
      });
    }
  }

  // Stock opname
  const opnameEvent = events.find((e) => e.kind === 'OPNAME');
  const opname = await prisma.stockOpname.create({
    data: {
      code: docCode('OPN', opnameEvent.at),
      note: 'Opname mingguan rak alat tulis',
      userId: users.admin.id,
      createdAt: opnameEvent.at,
    },
  });
  opnameEvent.id = opname.id;
  opnameEvent.code = opname.code;

  // ───────────── 5. Ledger mutasi stok kronologis ─────────────
  console.log('▶ Menyusun ledger mutasi stok...');
  const balance = new Map();
  const movements = [];
  for (const p of receiptLines) {
    balance.set(p.sku, p.initialStock);
    movements.push({
      productId: p.id, type: 'RECEIPT', qty: p.initialStock, balanceAfter: p.initialStock,
      unitName: p.baseUnit, unitQty: p.initialStock, refType: 'RECEIPT', refId: receipt.id, refCode: receipt.code,
      note: 'Saldo awal', userId: users.admin.id, createdAt: receiptAt,
    });
  }
  const move = (p, qty, data) => {
    const bal = (balance.get(p.sku) ?? 0) + qty;
    if (bal < 0) throw new Error(`Saldo minus untuk ${p.sku}`);
    balance.set(p.sku, bal);
    movements.push({ productId: p.id, qty, balanceAfter: bal, ...data });
  };
  const opnameRows = [];
  for (const e of events) {
    if (e.kind === 'SALE' && e.lines.length) {
      for (const l of e.lines) {
        move(l.p, -l.baseQty, {
          type: 'SALE', unitName: l.unit.name, unitQty: l.qty, refType: 'SALE', refId: e.id, refCode: e.code,
          userId: e.cashier.id, createdAt: e.at,
        });
      }
    } else if (e.kind === 'PO' && e.approvedAt) {
      for (const l of e.lines) {
        move(l.p, -l.baseQty, {
          type: 'B2B_ORDER', unitName: l.unit.name, unitQty: l.qty, refType: 'PO', refId: e.id, refCode: e.code,
          note: e.def.user.partner.institutionName, userId: users.admin.id, createdAt: e.approvedAt,
        });
      }
    } else if (e.kind === 'OPNAME') {
      for (const l of e.lines) {
        const systemQty = balance.get(l.p.sku);
        move(l.p, l.diff, {
          type: 'ADJUSTMENT', refType: 'OPNAME', refId: e.id, refCode: e.code,
          note: 'Stock opname: selisih fisik (barang rusak)', userId: users.admin.id, createdAt: e.at,
        });
        opnameRows.push({ opnameId: e.id, productId: l.p.id, systemQty, countedQty: systemQty + l.diff, difference: l.diff });
      }
    }
  }
  movements.sort((a, b) => a.createdAt - b.createdAt);
  await chunked(movements, 2000, (rows) => prisma.stockMovement.createMany({ data: rows }));
  await prisma.stockOpnameItem.createMany({ data: opnameRows });

  // Sinkronkan stok produk dengan saldo akhir ledger
  await chunked(catalog, 200, (rows) =>
    prisma.$transaction(
      rows.map((p) =>
        prisma.product.update({
          where: { id: p.id },
          data: { stock: balance.get(p.sku) ?? 0, reorderPoint: p.reorderPoint },
        }),
      ),
    ),
  );
  for (const p of catalog) {
    if ((balance.get(p.sku) ?? 0) !== p.finalStock) throw new Error(`Saldo akhir ${p.sku} tidak sesuai`);
  }

  // ───────────── 6. Cloud printing ─────────────
  console.log('▶ Riwayat & antrean cetak...');
  await generateSamples(SAMPLE_DIR);
  const pricing = SETTING_DEFAULTS.print_pricing;
  const customers = [users.pelanggan, users.pelanggan2, users.mitra];
  const files = [...SAMPLE_PDFS.map((s) => ({ ...s, mime: 'application/pdf', note: 'PDF' })), { ...SAMPLE_DOCX, title: 'Surat', mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', note: 'Metadata Word (perkiraan)' }];

  async function createPrintJob({ customer, file, cfg, status, createdAt, paidAt, startedAt, readyAt, completedAt, queueNumber, withFile }) {
    const q = quotePrint(cfg, file.pages, pricing);
    let storedName = `${crypto.randomUUID()}${path.extname(file.file)}`;
    if (withFile) await fs.copyFile(path.join(SAMPLE_DIR, file.file), path.join(PRINT_DIR, storedName));
    const code = docCode('PRN', createdAt, 'day');
    const paid = Boolean(paidAt);
    return prisma.printJob.create({
      data: {
        code, customerId: customer.id, originalName: file.file, storedName, mimeType: file.mime,
        fileSize: withFile ? (await fs.stat(path.join(PRINT_DIR, storedName))).size : 150_000,
        pageCount: file.pages, pageCountNote: file.note, pageRange: q.pageRange, pagesToPrint: q.pagesToPrint,
        colorMode: cfg.colorMode, paperSize: cfg.paperSize, orientation: cfg.orientation ?? 'PORTRAIT',
        duplex: cfg.duplex, copies: cfg.copies, binding: cfg.binding,
        pricePerPage: q.pricePerPage, printCost: q.printCost, bindingCost: q.bindingCost, totalPrice: q.total,
        status, queueNumber: queueNumber ?? null, queueDate: paid ? ymd(paidAt, '-') : null,
        pickupCode: paid ? String(randInt(0, 999999)).padStart(6, '0') : null,
        paidAt, startedAt, readyAt, completedAt, createdAt,
        fileDeletedAt: withFile ? null : completedAt ?? createdAt,
        handledById: startedAt ? users.kasir.id : null,
        payments: {
          create: {
            orderId: `${code}-1-SEED`, provider: 'MOCK', amount: q.total,
            status: paid ? 'PAID' : 'EXPIRED', paidAt,
            expiresAt: new Date(createdAt.getTime() + 15 * 60_000), createdAt,
          },
        },
      },
    });
  }
  const randomCfg = () => ({
    colorMode: rand() < 0.7 ? 'BW' : 'COLOR',
    paperSize: rand() < 0.8 ? 'A4' : 'F4',
    duplex: rand() < 0.4,
    copies: rand() < 0.75 ? 1 : randInt(2, 5),
    binding: rand() < 0.6 ? 'NONE' : rand() < 0.5 ? 'LAKBAN' : 'SPIRAL',
  });
  for (let d = 30; d >= 1; d--) {
    for (let i = randInt(2, 6); i > 0; i--) {
      const createdAt = daysAgoAt(d, randInt(8, 18), randInt(0, 59));
      const paidAt = new Date(createdAt.getTime() + 3 * 60_000);
      await createPrintJob({
        customer: pick(customers), file: pick(files), cfg: randomCfg(), status: 'COMPLETED', createdAt, paidAt,
        startedAt: new Date(paidAt.getTime() + 20 * 60_000), readyAt: new Date(paidAt.getTime() + 35 * 60_000),
        completedAt: new Date(paidAt.getTime() + 120 * 60_000), withFile: false,
      });
    }
  }
  await createPrintJob({
    customer: users.pelanggan, file: files[1], cfg: randomCfg(), status: 'EXPIRED', createdAt: daysAgoAt(1, 15), withFile: false,
  });
  // Antrean hari ini (berkas nyata tersedia untuk diunduh operator)
  const today = [
    { customer: users.pelanggan2, file: files[0], status: 'COMPLETED', paid: 150, done: 100, cfg: { colorMode: 'BW', paperSize: 'A4', duplex: false, copies: 3, binding: 'NONE' } },
    { customer: users.pelanggan, file: files[3], status: 'READY', paid: 90, done: 30, cfg: { colorMode: 'BW', paperSize: 'A4', duplex: true, copies: 1, binding: 'SPIRAL' } },
    { customer: users.mitra, file: files[1], status: 'PRINTING', paid: 45, cfg: { colorMode: 'COLOR', paperSize: 'A4', duplex: false, copies: 2, binding: 'LAKBAN' } },
    { customer: users.pelanggan2, file: files[2], status: 'QUEUED', paid: 20, cfg: { colorMode: 'BW', paperSize: 'F4', duplex: true, copies: 1, binding: 'LAKBAN', pageRange: '1-10' } },
    { customer: users.pelanggan, file: files[4], status: 'QUEUED', paid: 5, cfg: { colorMode: 'COLOR', paperSize: 'A4', duplex: false, copies: 1, binding: 'NONE' } },
  ];
  let queueNo = 0;
  for (const t of today) {
    const paidAt = minutesAgo(t.paid);
    await createPrintJob({
      customer: t.customer, file: t.file, cfg: t.cfg, status: t.status, createdAt: minutesAgo(t.paid + 4), paidAt,
      startedAt: ['PRINTING', 'READY', 'COMPLETED'].includes(t.status) ? minutesAgo(t.paid - 10) : null,
      readyAt: ['READY', 'COMPLETED'].includes(t.status) ? minutesAgo(t.done) : null,
      completedAt: t.status === 'COMPLETED' ? minutesAgo(t.done - 20) : null,
      queueNumber: ++queueNo, withFile: true,
    });
  }
  counters.set(`QUEUE-${ymd(NOW, '-')}`, queueNo);

  // ───────────── 7. Counter & notifikasi ─────────────
  await prisma.counter.createMany({ data: [...counters].map(([key, value]) => ({ key, value })) });

  const submitted = await prisma.purchaseOrder.findFirst({ where: { status: 'SUBMITTED' } });
  const overdueInv = await prisma.invoice.findFirst({ where: { status: 'UNPAID', dueDate: { lt: NOW } } });
  const readyPo = await prisma.purchaseOrder.findFirst({ where: { status: 'READY' } });
  const readyJob = await prisma.printJob.findFirst({ where: { status: 'READY' } });
  const staffNotes = [
    { type: 'B2B_ORDER', title: `PO baru ${submitted.poNumber}`, body: `SMA Negeri 1 Contoh mengajukan PO senilai Rp ${submitted.total.toLocaleString('id-ID')}.`, link: `/admin/b2b-orders?id=${submitted.id}` },
    { type: 'PARTNER', title: 'Pendaftaran mitra B2B baru', body: 'Dinas Pendidikan Kota Contoh menunggu verifikasi.', link: '/admin/partners' },
    ...catalog.filter((p) => habis.has(p.sku)).slice(0, 2).map((p) => ({ type: 'STOCK_ALERT', title: `Stok habis: ${p.name}`, body: `${p.sku} perlu segera dipesan ulang.`, link: '/admin/restock' })),
  ];
  for (const u of [users.owner, users.admin, users.kasir]) {
    await prisma.notification.createMany({ data: staffNotes.map((n) => ({ ...n, userId: u.id })) });
  }
  await prisma.notification.createMany({
    data: [
      { userId: users.mitra.id, type: 'B2B_ORDER', title: `Pesanan ${readyPo.poNumber} siap diambil`, body: 'Barang pesanan Anda sudah disiapkan dan dapat diambil di toko.', link: `/b2b/orders?id=${readyPo.id}` },
      { userId: users.mitra.id, type: 'INVOICE', title: `Faktur ${overdueInv.invoiceNumber} telah jatuh tempo`, body: `Sisa tagihan Rp ${(overdueInv.total - overdueInv.amountPaid).toLocaleString('id-ID')}.`, link: '/b2b/invoices' },
      { userId: users.pelanggan.id, type: 'PRINT', title: 'Dokumen siap diambil · C002', body: `Pesanan ${readyJob.code} sudah selesai dicetak. Tunjukkan kode ambil ${readyJob.pickupCode} ke kasir.`, link: `/print/jobs/${readyJob.id}` },
    ],
  });

  const stats = {
    sku: catalog.length,
    penjualan: sales.length,
    mutasi: movements.length,
    po: PO_DEFS.length,
    cetak: await prisma.printJob.count(),
    alertDemo: { habis: habis.size, kritis: kritis.size, waspada: waspada.size },
  };
  console.log('✔ Seed selesai:', stats);
  console.log('\nAkun demo (password: password123):');
  for (const [k, u] of Object.entries(users)) console.log(`  ${k.padEnd(11)} ${u.email.padEnd(24)} ${u.role}`);
}

main()
  .catch((err) => {
    console.error('✖ Seed gagal:', err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
