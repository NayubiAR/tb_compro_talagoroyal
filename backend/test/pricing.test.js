import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveTierPrice, priceOrder, normalizeTiers } from '../src/modules/b2b/pricing.js';
import { countRangePages, quotePrint } from '../src/modules/printing/pricing.js';
import { midtransSignature, mapMidtransStatus } from '../src/modules/payments/providers/midtrans.js';

const TIERS = [
  { minQty: 1, unitPrice: 2300 },
  { minQty: 60, unitPrice: 2100 },
  { minQty: 600, unitPrice: 1950 },
];

test('tier price dipilih dari kuantitas total', () => {
  assert.equal(resolveTierPrice(10, TIERS, 2500).unitPrice, 2300);
  assert.equal(resolveTierPrice(60, TIERS, 2500).unitPrice, 2100);
  assert.equal(resolveTierPrice(1000, TIERS, 2500).unitPrice, 1950);
});

test('tier memberi info kuantitas tambahan untuk tier berikutnya', () => {
  const r = resolveTierPrice(45, TIERS, 2500);
  assert.deepEqual(r.nextTier, { minQty: 60, unitPrice: 2100, needed: 15 });
  assert.equal(resolveTierPrice(700, TIERS, 2500).nextTier, null);
});

test('tanpa tier memakai harga eceran', () => {
  assert.equal(resolveTierPrice(5, [], 2500).unitPrice, 2500);
  assert.equal(resolveTierPrice(5, [{ minQty: 12, unitPrice: 2000 }], 2500).unitPrice, 2500);
});

test('normalizeTiers menolak harga yang naik untuk kuantitas lebih besar', () => {
  assert.throws(
    () => normalizeTiers([
      { minQty: 1, unitPrice: 2000 },
      { minQty: 10, unitPrice: 2200 },
    ]),
    /semakin murah/,
  );
});

test('priceOrder: subtotal → diskon level → PPN', () => {
  const r = priceOrder(
    [
      { baseQty: 120, unitPrice: 2100 },
      { baseQty: 10, unitPrice: 5000 },
    ],
    { discountPercent: 4, taxPercent: 11 },
  );
  assert.equal(r.subtotal, 302000);
  assert.equal(r.discount, 12080);
  assert.equal(r.tax, Math.round((302000 - 12080) * 0.11));
  assert.equal(r.total, 302000 - 12080 + r.tax);
});

test('rentang halaman cetak', () => {
  assert.deepEqual(countRangePages('', 10), { pages: 10, normalized: null });
  assert.deepEqual(countRangePages('1-3, 5, 8-10', 10), { pages: 7, normalized: '1-3,5,8-10' });
  assert.deepEqual(countRangePages('2-4,3-5', 10), { pages: 4, normalized: '2-5' });
  assert.throws(() => countRangePages('5-2', 10), /di luar/);
  assert.throws(() => countRangePages('1-20', 10), /di luar/);
  assert.throws(() => countRangePages('a-b', 10), /tidak valid/);
});

test('kalkulasi biaya cetak', () => {
  const pricing = {
    pricePerPage: { A4: { BW: 500, COLOR: 1500 } },
    binding: { NONE: 0, LAKBAN: 3000, SPIRAL: 8000 },
  };
  const q = quotePrint(
    { paperSize: 'A4', colorMode: 'COLOR', binding: 'SPIRAL', copies: 2, duplex: true, pageRange: '1-9' },
    20,
    pricing,
  );
  assert.equal(q.pagesToPrint, 9);
  assert.equal(q.printCost, 9 * 2 * 1500);
  assert.equal(q.bindingCost, 16000);
  assert.equal(q.sheets, 10);
  assert.equal(q.total, 27000 + 16000);
  assert.throws(
    () => quotePrint({ paperSize: 'A3', colorMode: 'BW', binding: 'NONE', copies: 1, duplex: false }, 1, pricing),
    /tidak tersedia/,
  );
});

test('signature & status Midtrans', () => {
  const sig = midtransSignature('PRN-1', '200', '15000.00', 'SB-Mid-server-xxx');
  assert.equal(sig.length, 128);
  assert.equal(mapMidtransStatus('settlement'), 'PAID');
  assert.equal(mapMidtransStatus('pending'), 'PENDING');
  assert.equal(mapMidtransStatus('expire'), 'EXPIRED');
  assert.equal(mapMidtransStatus('deny'), 'FAILED');
});
