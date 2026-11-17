import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeUnits,
  breakdown,
  formatQty,
  describeHierarchy,
  findUnit,
  toBase,
  sumCounts,
} from '../src/modules/inventory/units.js';

const PEN = [
  { name: 'Pcs', conversion: 1, price: 2500 },
  { name: 'Dus', conversion: 60, price: 132000 },
  { name: 'Pak', conversion: 12, price: 27000 },
];

test('normalizeUnits mengurutkan dari satuan terbesar', () => {
  const units = normalizeUnits(PEN);
  assert.deepEqual(
    units.map((u) => u.name),
    ['Dus', 'Pak', 'Pcs'],
  );
});

test('contoh proposal: 1 Dus = 5 Pak = 60 Pcs', () => {
  assert.equal(describeHierarchy(normalizeUnits(PEN)), '1 Dus = 5 Pak = 60 Pcs');
});

test('normalizeUnits menolak hierarki yang tidak bertingkat', () => {
  assert.throws(
    () => normalizeUnits([
      { name: 'Dus', conversion: 50, price: 0 },
      { name: 'Pak', conversion: 12, price: 0 },
      { name: 'Pcs', conversion: 1, price: 0 },
    ]),
    /tidak habis dibagi/,
  );
});

test('normalizeUnits mewajibkan satuan terkecil & menolak duplikat', () => {
  assert.throws(() => normalizeUnits([{ name: 'Dus', conversion: 12, price: 0 }]), /konversi 1/);
  assert.throws(
    () => normalizeUnits([
      { name: 'pcs', conversion: 1, price: 0 },
      { name: 'PCS', conversion: 10, price: 0 },
    ]),
    /duplikat/,
  );
  assert.throws(() => normalizeUnits([{ name: 'Pcs', conversion: 1.5, price: 0 }]), /bilangan bulat/);
});

test('breakdown memecah stok satuan terkecil ke satuan bertingkat', () => {
  assert.deepEqual(breakdown(137, PEN), [
    { unit: 'Dus', qty: 2 },
    { unit: 'Pak', qty: 1 },
    { unit: 'Pcs', qty: 5 },
  ]);
  assert.equal(formatQty(137, PEN), '2 Dus 1 Pak 5 Pcs');
  assert.equal(formatQty(60, PEN), '1 Dus');
  assert.equal(formatQty(0, PEN), '0 Pcs');
  assert.equal(formatQty(-14, PEN), '-1 Pak 2 Pcs');
});

test('konversi satuan ke satuan terkecil', () => {
  assert.equal(toBase(3, findUnit(PEN, 'dus')), 180);
  assert.equal(findUnit(PEN, undefined).name, 'Pcs');
  assert.equal(findUnit(PEN, 'Rim'), undefined);
});

test('sumCounts menjumlahkan hitungan campuran (stock opname)', () => {
  const total = sumCounts(
    [
      { unitName: 'Dus', qty: 2 },
      { unitName: 'Pak', qty: 3 },
      { unitName: 'Pcs', qty: 4 },
    ],
    PEN,
  );
  assert.equal(total, 2 * 60 + 3 * 12 + 4);
  assert.throws(() => sumCounts([{ unitName: 'Rim', qty: 1 }], PEN), /tidak dikenal/);
});
