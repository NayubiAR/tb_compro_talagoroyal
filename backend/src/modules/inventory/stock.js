import { conflict, notFound } from '../../lib/errors.js';
import { publish } from '../../lib/events.js';
import { notifyStaff } from '../../lib/notify.js';
import { formatQty } from './units.js';

export const stockStatusOf = (p) => (p.stock <= 0 ? 'OUT' : p.stock <= p.reorderPoint ? 'LOW' : 'OK');

/**
 * Ubah stok secara atomik dan catat ke ledger. WAJIB dipanggil di dalam prisma.$transaction.
 * qty bertanda dalam satuan terkecil (negatif = keluar).
 * Pengurangan memakai UPDATE bersyarat (WHERE stock >= qty) sehingga stok tidak pernah
 * minus walau ada dua kasir / PO yang memotong stok bersamaan.
 */
export async function changeStock(
  tx,
  { productId, qty, type, unitName = null, unitQty = null, refType = null, refId = null, refCode = null, note = null, userId = null },
) {
  if (!Number.isInteger(qty) || qty === 0) throw new Error('qty harus bilangan bulat bukan nol');
  if (qty < 0) {
    const res = await tx.product.updateMany({
      where: { id: productId, stock: { gte: -qty } },
      data: { stock: { increment: qty } },
    });
    if (res.count === 0) {
      const p = await tx.product.findUnique({ where: { id: productId }, include: { units: true } });
      if (!p) throw notFound('Produk tidak ditemukan');
      throw conflict(`Stok ${p.name} tidak mencukupi (tersedia ${formatQty(p.stock, p.units)})`, {
        productId,
        available: p.stock,
        requested: -qty,
      });
    }
  } else {
    await tx.product.update({ where: { id: productId }, data: { stock: { increment: qty } } });
  }
  const product = await tx.product.findUnique({ where: { id: productId }, include: { units: true } });
  await tx.stockMovement.create({
    data: { productId, type, qty, balanceAfter: product.stock, unitName, unitQty, refType, refId, refCode, note, userId },
  });
  return { product, previousStock: product.stock - qty };
}

/**
 * Dipanggil SETELAH transaksi commit: siarkan perubahan stok ke dashboard staf dan
 * kirim Smart Restock Alert hanya ketika stok BARU melewati batas minimum
 * (bukan setiap transaksi, supaya tidak spam).
 */
export function announceStockChanges(changes) {
  const byId = new Map();
  for (const c of changes) {
    const prev = byId.get(c.product.id);
    byId.set(c.product.id, { product: c.product, previousStock: prev ? prev.previousStock : c.previousStock });
  }
  for (const { product: p, previousStock } of byId.values()) {
    const status = stockStatusOf(p);
    const payload = {
      productId: p.id,
      sku: p.sku,
      name: p.name,
      stock: p.stock,
      stockDisplay: formatQty(p.stock, p.units),
      reorderDisplay: formatQty(p.reorderPoint, p.units),
      status,
    };
    publish('stock.changed', payload, ['staff']);
    const crossedMin = previousStock > p.reorderPoint && p.stock <= p.reorderPoint;
    const becameEmpty = previousStock > 0 && p.stock <= 0;
    if (crossedMin || becameEmpty) {
      publish('stock.alert', payload, ['staff']);
      notifyStaff({
        type: 'STOCK_ALERT',
        title: status === 'OUT' ? `Stok habis: ${p.name}` : `Stok menipis: ${p.name}`,
        body: `${p.sku} tersisa ${payload.stockDisplay} (batas minimum ${payload.reorderDisplay}).`,
        link: '/admin/restock',
      });
    }
  }
}
