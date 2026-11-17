// Smoke test end-to-end terhadap server yang sedang berjalan (data hasil `npm run db:seed`).
// Jalankan: npm run dev (terminal 1) lalu npm run smoke (terminal 2).
// Menguji alur lintas modul via HTTP + WebSocket sungguhan, termasuk Redis Pub/Sub.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { io } from 'socket.io-client';

const BASE = process.env.SMOKE_BASE_URL || `http://localhost:${process.env.PORT || 4000}`;
const SAMPLES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'samples');
let passed = 0;

async function api(method, url, { token, body, form, raw } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${BASE}${url}`, { method, headers, body: form ?? (body ? JSON.stringify(body) : undefined) });
  if (raw) return res;
  const json = await res.json().catch(() => ({}));
  return { ...json, status: res.status };
}
async function step(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ✔ ${name}`);
  } catch (err) {
    console.error(`  ✖ ${name}\n    ${err.message}`);
    process.exitCode = 1;
    throw err;
  }
}
const login = async (email) => (await api('POST', '/api/auth/login', { body: { email, password: 'password123' } })).data.token;
function waitFor(socket, event, predicate = () => true, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`Timeout menunggu event ${event}`)), timeout);
    const handler = (payload) => {
      if (!predicate(payload)) return;
      clearTimeout(t);
      socket.off(event, handler);
      resolve(payload);
    };
    socket.on(event, handler);
  });
}
function connect(token) {
  return new Promise((resolve, reject) => {
    const s = io(BASE, { auth: token ? { token } : {}, transports: ['websocket'] });
    s.on('connect', () => resolve(s));
    s.on('connect_error', reject);
  });
}

console.log(`Smoke test → ${BASE}`);
const T = {};
const sockets = [];

try {
  await step('health & login semua peran', async () => {
    const h = await api('GET', '/api/health');
    assert.equal(h.status, 200);
    for (const k of ['owner', 'admin', 'mitra', 'mitra2', 'mitra3', 'pelanggan']) T[k] = await login(`${k}@talago.test`);
    const bad = await api('POST', '/api/auth/login', { body: { email: 'owner@talago.test', password: 'salah' } });
    assert.equal(bad.status, 401);
  });

  await step('RBAC: pelanggan ditolak di inventaris, mitra pending ditolak di katalog', async () => {
    assert.equal((await api('GET', '/api/inventory/products', { token: T.pelanggan })).status, 403);
    const pending = await api('GET', '/api/b2b/catalog', { token: T.mitra3 });
    assert.equal(pending.status, 403);
    assert.match(pending.error.message, /menunggu verifikasi/);
    assert.equal((await api('GET', '/api/users', { token: T.admin })).status, 403);
  });

  const staffSocket = await connect(T.admin);
  sockets.push(staffSocket);

  let product;
  await step('inventaris: validasi hierarki satuan & buat produk 1 Dus = 5 Pak = 60 Pcs', async () => {
    const cats = await api('GET', '/api/inventory/categories', { token: T.admin });
    const base = {
      sku: `TEST-${Date.now()}`,
      name: 'Pulpen Uji Smoke Test',
      categoryId: cats.data[0].id,
      costPrice: 1800,
      reorderPoint: 60,
      leadTimeDays: 3,
      priceTiers: [{ minQty: 1, unitPrice: 2300 }, { minQty: 60, unitPrice: 2100 }],
    };
    const bad = await api('POST', '/api/inventory/products', {
      token: T.admin,
      body: { ...base, units: [{ name: 'Dus', conversion: 50, price: 1 }, { name: 'Pak', conversion: 12, price: 1 }, { name: 'Pcs', conversion: 1, price: 1 }] },
    });
    assert.equal(bad.status, 400);
    const res = await api('POST', '/api/inventory/products', {
      token: T.admin,
      body: { ...base, units: [{ name: 'Pcs', conversion: 1, price: 2500 }, { name: 'Pak', conversion: 12, price: 27000 }, { name: 'Dus', conversion: 60, price: 130000 }] },
    });
    assert.equal(res.status, 201, JSON.stringify(res.error));
    product = res.data;
    assert.equal(product.hierarchy, '1 Dus = 5 Pak = 60 Pcs');
    assert.equal(product.stockStatus, 'OUT');
  });

  await step('penerimaan barang 2 Dus + 3 Pak → stok 156 Pcs (2 Dus 3 Pak) & broadcast stock.changed', async () => {
    const evt = waitFor(staffSocket, 'stock.changed', (p) => p.productId === product.id);
    const res = await api('POST', '/api/inventory/receipts', {
      token: T.admin,
      body: { supplier: 'PT Uji', items: [{ productId: product.id, unitName: 'Dus', qty: 2, unitCost: 108000 }, { productId: product.id, unitName: 'Pak', qty: 3 }] },
    });
    assert.equal(res.status, 201, JSON.stringify(res.error));
    const payload = await evt;
    const detail = await api('GET', `/api/inventory/products/${product.id}`, { token: T.admin });
    assert.equal(detail.data.stock, 156);
    assert.equal(detail.data.stockDisplay, '2 Dus 3 Pak');
    assert.equal(detail.data.costPrice, 1800);
    assert.ok(payload.stockDisplay);
  });

  await step('kasir: jual 1 Dus + 45 Pcs, oversell ditolak, alert stok terkirim real-time', async () => {
    const alert = waitFor(staffSocket, 'stock.alert', (p) => p.productId === product.id);
    const sale = await api('POST', '/api/sales', {
      token: T.admin,
      body: { paymentMethod: 'CASH', paidAmount: 250000, items: [{ productId: product.id, unitName: 'Dus', qty: 1 }, { productId: product.id, unitName: 'Pcs', qty: 45 }] },
    });
    assert.equal(sale.status, 201, JSON.stringify(sale.error));
    assert.equal(sale.data.total, 130000 + 45 * 2500);
    assert.equal(sale.data.changeAmount, 250000 - sale.data.total);
    await alert; // stok 156 → 51 (≤ reorder point 60)
    const over = await api('POST', '/api/sales', {
      token: T.admin,
      body: { paymentMethod: 'QRIS', items: [{ productId: product.id, unitName: 'Dus', qty: 1 }] },
    });
    assert.equal(over.status, 409);
    assert.match(over.error.message, /tidak mencukupi/);
  });

  await step('stock opname: hitung fisik 4 Pak 2 Pcs → penyesuaian -1 Pcs', async () => {
    const res = await api('POST', '/api/inventory/opnames', {
      token: T.admin,
      body: { note: 'Smoke', items: [{ productId: product.id, counts: [{ unitName: 'Pak', qty: 4 }, { unitName: 'Pcs', qty: 2 }] }] },
    });
    assert.equal(res.status, 201, JSON.stringify(res.error));
    assert.equal(res.data.items[0].systemQty, 51);
    assert.equal(res.data.items[0].difference, -1);
    const mv = await api('GET', `/api/inventory/movements?productId=${product.id}`, { token: T.admin });
    assert.deepEqual(mv.data.map((m) => m.type), ['ADJUSTMENT', 'SALE', 'SALE', 'RECEIPT', 'RECEIPT']);
  });

  await step('smart restock alert & ringkasan gudang', async () => {
    const r = await api('GET', '/api/inventory/restock-alerts', { token: T.admin });
    assert.ok(r.counts.HABIS >= 1 && r.counts.KRITIS >= 1, JSON.stringify(r.counts));
    const mine = r.data.find((a) => a.productId === product.id);
    assert.equal(mine.level, 'KRITIS');
    assert.ok(mine.suggestedOrderQty % 60 === 0, 'saran pesan dibulatkan per Dus');
    const s = await api('GET', '/api/inventory/summary', { token: T.admin });
    assert.ok(s.data.totalSku > 1000 && s.data.stockValue > 0);
    const search = await api('GET', '/api/inventory/products?q=hvs%20a4&limit=5', { token: T.admin });
    assert.ok(search.data.every((p) => /HVS/i.test(p.name) && /A4/.test(p.name)));
  });

  const partnerSocket = await connect(T.mitra);
  sockets.push(partnerSocket);
  let order;
  await step('B2B: katalog tertutup + harga tiering + quote Quick PO (SKU tidak dikenal terdeteksi)', async () => {
    const cat = await api('GET', '/api/b2b/catalog?q=pulpen%20standard&limit=3', { token: T.mitra });
    assert.equal(cat.status, 200);
    assert.equal(cat.meta.levelName, 'Gold');
    assert.ok(cat.data[0].priceTiers.length >= 2);
    const q = await api('POST', '/api/b2b/quote', {
      token: T.mitra,
      body: { items: [{ sku: 'ATL-0001', unitName: 'Pak', qty: 3 }, { sku: 'ATL-0001', unitName: 'Pcs', qty: 30 }, { sku: 'TIDAK-ADA', qty: 1 }] },
    });
    assert.equal(q.data.summary.hasErrors, true);
    const [a, b] = q.data.lines;
    assert.equal(a.tierUnitPrice, b.tierUnitPrice, 'tier dihitung dari total qty produk (36+30=66 pcs)');
    assert.equal(a.tierMinQty, 60);
    assert.equal(q.data.summary.discountPercent, 4);
  });

  await step('B2B: submit PO → staf approve → stok terpotong & faktur terbit (notifikasi real-time)', async () => {
    const created = await api('POST', '/api/b2b/orders', {
      token: T.mitra,
      body: { partnerRef: 'SMOKE-1', items: [{ sku: 'ATL-0001', unitName: 'Dus', qty: 1 }, { sku: 'BKU-0002', unitName: 'Pak', qty: 2 }] },
    });
    assert.equal(created.status, 201, JSON.stringify(created.error));
    order = created.data;
    assert.equal(order.status, 'SUBMITTED');
    const before = await api('GET', `/api/inventory/products?q=ATL-0001`, { token: T.admin });
    const notif = waitFor(partnerSocket, 'notification', (n) => n.title.includes(order.poNumber));
    const approved = await api('POST', `/api/admin/b2b/orders/${order.id}/approve`, { token: T.admin });
    assert.equal(approved.status, 200, JSON.stringify(approved.error));
    assert.equal(approved.data.status, 'APPROVED');
    assert.ok(approved.data.invoice.invoiceNumber.startsWith('INV-'));
    await notif;
    const after = await api('GET', `/api/inventory/products?q=ATL-0001`, { token: T.admin });
    assert.equal(before.data[0].stock - after.data[0].stock, 60);
    const again = await api('POST', `/api/admin/b2b/orders/${order.id}/approve`, { token: T.admin });
    assert.equal(again.status, 409);
    const cancel = await api('POST', `/api/b2b/orders/${order.id}/cancel`, { token: T.mitra, body: {} });
    assert.equal(cancel.status, 409);
    order = approved.data;
  });

  await step('faktur: pembayaran sebagian → PARTIAL, PDF via token unduhan', async () => {
    const pay = await api('POST', `/api/admin/b2b/invoices/${order.invoice.id}/payments`, {
      token: T.admin,
      body: { amount: 10000, method: 'TRANSFER', reference: 'TRF-SMOKE' },
    });
    assert.equal(pay.status, 201, JSON.stringify(pay.error));
    assert.equal(pay.data.status, 'PARTIAL');
    const over = await api('POST', `/api/admin/b2b/invoices/${order.invoice.id}/payments`, {
      token: T.admin,
      body: { amount: order.total, method: 'CASH' },
    });
    assert.equal(over.status, 400);
    const pdfPath = `/api/b2b/invoices/${order.invoice.id}/pdf`;
    const dl = await api('POST', '/api/auth/download-token', { token: T.mitra, body: { path: pdfPath } });
    const res = await api('GET', dl.data.url, { raw: true });
    assert.equal(res.headers.get('content-type'), 'application/pdf');
    assert.equal(Buffer.from(await res.arrayBuffer()).subarray(0, 4).toString(), '%PDF');
    const misuse = await api('GET', `/api/b2b/orders/${order.id}/pdf?dl=${dl.data.token}`, { raw: true });
    assert.equal(misuse.status, 401, 'token unduhan terikat ke satu path');
    const other = await api('GET', `/api/b2b/invoices/${order.invoice.id}`, { token: T.mitra2 });
    assert.equal(other.status, 404, 'mitra lain tidak bisa melihat faktur');
  });

  await step('piutang & mitra: aging report, verifikasi mitra pending', async () => {
    const r = await api('GET', '/api/admin/b2b/receivables', { token: T.owner });
    assert.ok(r.data.overdue > 0 && r.data.outstanding > r.data.overdue);
    const partners = await api('GET', '/api/partners?status=PENDING', { token: T.admin });
    const pending = partners.data[0];
    const levels = await api('GET', '/api/partners/levels', { token: T.admin });
    const v = await api('POST', `/api/partners/${pending.id}/verify`, {
      token: T.admin,
      body: { levelId: levels.data[0].id, paymentTermDays: 30, creditLimit: 1000 },
    });
    assert.equal(v.data.status, 'VERIFIED');
    assert.equal((await api('GET', '/api/b2b/catalog', { token: T.mitra3 })).status, 200);
    const limited = await api('POST', '/api/b2b/orders', {
      token: T.mitra3,
      body: { items: [{ sku: 'BKU-0002', unitName: 'Pak', qty: 1 }] },
    });
    assert.equal(limited.status, 409);
    assert.match(limited.error.message, /batas kredit/);
  });

  const customerSocket = await connect(T.pelanggan);
  const publicSocket = await connect(null);
  sockets.push(customerSocket, publicSocket);
  let job;
  await step('cloud printing: unggah PDF 12 halaman, validasi magic bytes, hitung DOCX', async () => {
    const pdf = await fs.readFile(path.join(SAMPLES, 'makalah-12-halaman.pdf'));
    const form = new FormData();
    form.append('file', new Blob([pdf], { type: 'application/pdf' }), 'makalah-12-halaman.pdf');
    const res = await api('POST', '/api/print/jobs', { token: T.pelanggan, form });
    assert.equal(res.status, 201, JSON.stringify(res.error));
    job = res.data;
    assert.equal(job.pageCount, 12);
    const fake = new FormData();
    fake.append('file', new Blob(['bukan pdf'], { type: 'application/pdf' }), 'palsu.pdf');
    assert.equal((await api('POST', '/api/print/jobs', { token: T.pelanggan, form: fake })).status, 400);
    const exe = new FormData();
    exe.append('file', new Blob(['MZ'], { type: 'application/octet-stream' }), 'virus.exe');
    assert.equal((await api('POST', '/api/print/jobs', { token: T.pelanggan, form: exe })).status, 400);
    const docx = new FormData();
    docx.append('file', new Blob([await fs.readFile(path.join(SAMPLES, 'surat-undangan-3-halaman.docx'))]), 'surat undangan.docx');
    const d = await api('POST', '/api/print/jobs', { token: T.pelanggan, form: docx });
    assert.equal(d.data.pageCount, 3);
    await api('POST', `/api/print/jobs/${d.data.id}/cancel`, { token: T.pelanggan });
  });

  await step('cloud printing: kalkulasi biaya, checkout QRIS, belum masuk antrean sebelum lunas', async () => {
    const cfg = { colorMode: 'COLOR', paperSize: 'A4', duplex: true, copies: 2, binding: 'SPIRAL', pageRange: '1-5,8' };
    const q = await api('POST', `/api/print/jobs/${job.id}/quote`, { token: T.pelanggan, body: cfg });
    assert.equal(q.data.pagesToPrint, 6);
    assert.equal(q.data.total, 6 * 2 * 1500 + 2 * 8000);
    const co = await api('POST', `/api/print/jobs/${job.id}/checkout`, { token: T.pelanggan, body: cfg });
    assert.equal(co.status, 200, JSON.stringify(co.error));
    job = co.data;
    assert.equal(job.status, 'AWAITING_PAYMENT');
    assert.ok(job.payment.qrString);
    const queue = await api('GET', '/api/print/queue', { token: T.admin });
    assert.ok(![...queue.data.waiting].some((j) => j.id === job.id), 'aturan bisnis: belum lunas = tidak masuk antrean');
    const twice = await api('POST', `/api/print/jobs/${job.id}/checkout`, { token: T.pelanggan, body: cfg });
    assert.equal(twice.status, 409);
  });

  await step('pembayaran QRIS (simulasi) → antrean real-time via Redis Pub/Sub ke pelanggan, kasir & monitor', async () => {
    const toCustomer = waitFor(customerSocket, 'print.job.updated', (p) => p.id === job.id && p.status === 'QUEUED');
    const toStaff = waitFor(staffSocket, 'print.job.updated', (p) => p.id === job.id && p.status === 'QUEUED');
    const toPublic = waitFor(publicSocket, 'print.queue.updated', (p) => p.id === job.id);
    const paid = await api('POST', `/api/payments/mock/${job.payment.orderId}/pay`, { token: T.pelanggan });
    assert.equal(paid.status, 200, JSON.stringify(paid.error));
    const evt = await toCustomer;
    await Promise.all([toStaff, toPublic]);
    assert.match(evt.queueLabel, /^C\d{3}$/);
    job = paid.data;
    assert.equal(job.status, 'QUEUED');
    assert.match(job.pickupCode, /^\d{6}$/);
    const dup = await api('POST', `/api/payments/mock/${job.payment.orderId}/pay`, { token: T.pelanggan });
    assert.equal(dup.status, 409, 'notifikasi ganda tidak memproses ulang');
    const pub = await api('GET', '/api/print/queue/public');
    assert.ok(pub.data.waiting.includes(job.queueLabel));
  });

  await step('kasir: proses antrean Menunggu → Dicetak → Siap Diambil → Selesai (verifikasi kode ambil)', async () => {
    const queue = await api('GET', '/api/print/queue', { token: T.admin });
    const staffView = queue.data.waiting.find((j) => j.id === job.id);
    assert.equal(staffView.pickupCode, undefined, 'staf tidak melihat kode ambil');
    assert.equal((await api('PATCH', `/api/print/queue/${job.id}`, { token: T.admin, body: { status: 'READY' } })).status, 409);
    assert.equal((await api('PATCH', `/api/print/queue/${job.id}`, { token: T.admin, body: { status: 'PRINTING' } })).status, 200);
    const ready = waitFor(customerSocket, 'notification', (n) => n.title.includes('siap diambil'));
    assert.equal((await api('PATCH', `/api/print/queue/${job.id}`, { token: T.admin, body: { status: 'READY' } })).status, 200);
    await ready;
    const found = await api('GET', `/api/print/queue/pickup/${job.pickupCode}`, { token: T.admin });
    assert.ok(found.data.some((j) => j.id === job.id));
    const wrong = await api('PATCH', `/api/print/queue/${job.id}`, { token: T.admin, body: { status: 'COMPLETED', pickupCode: '000000' === job.pickupCode ? '111111' : '000000' } });
    assert.equal(wrong.status, 400);
    const done = await api('PATCH', `/api/print/queue/${job.id}`, { token: T.admin, body: { status: 'COMPLETED', pickupCode: job.pickupCode } });
    assert.equal(done.data.status, 'COMPLETED');
    const dl = await api('POST', '/api/auth/download-token', { token: T.admin, body: { path: `/api/print/jobs/${job.id}/file` } });
    const file = await api('GET', dl.data.url, { raw: true });
    assert.equal(file.status, 200);
  });

  await step('laporan: dashboard, penjualan & inventaris', async () => {
    const d = await api('GET', '/api/reports/dashboard', { token: T.owner });
    assert.equal(d.data.revenueTrend.length, 14);
    assert.ok(d.data.today.total > 0);
    const s = await api('GET', '/api/reports/sales', { token: T.owner });
    assert.ok(s.data.topProducts.length > 0 && s.data.totals.b2b > 0 && s.data.totals.print > 0);
    const i = await api('GET', '/api/reports/inventory', { token: T.owner });
    assert.ok(i.data.byCategory.length === 10 && i.data.deadStock.count > 0);
  });

  await step('pengaturan & notifikasi', async () => {
    const pricing = await api('GET', '/api/settings', { token: T.admin });
    assert.ok(pricing.data.print_pricing.pricePerPage.A4.BW > 0);
    assert.equal((await api('PUT', '/api/settings/b2b', { token: T.admin, body: { taxPercent: 11 } })).status, 403);
    const n = await api('GET', '/api/notifications', { token: T.pelanggan });
    assert.ok(n.meta.unreadCount > 0);
    await api('POST', '/api/notifications/read-all', { token: T.pelanggan });
    assert.equal((await api('GET', '/api/notifications', { token: T.pelanggan })).meta.unreadCount, 0);
  });

  console.log(`\n✔ ${passed} skenario lulus`);
} catch {
  console.error(`\n✖ Berhenti setelah ${passed} skenario lulus`);
} finally {
  sockets.forEach((s) => s.close());
}
