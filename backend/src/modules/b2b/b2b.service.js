import { prisma } from '../../lib/prisma.js';
import { badRequest, conflict, notFound } from '../../lib/errors.js';
import { nextCode } from '../../lib/sequence.js';
import { addDays, daysBetween } from '../../lib/dates.js';
import { getSetting } from '../../lib/settings.js';
import { publish } from '../../lib/events.js';
import { notifyStaff, notifyUser, audit } from '../../lib/notify.js';
import { rupiah, longDate } from '../../lib/format.js';
import { renderOrderPdf } from '../../lib/pdf.js';
import { findUnit, toBase, sortUnits, baseUnitOf, formatQty } from '../inventory/units.js';
import { changeStock, announceStockChanges } from '../inventory/stock.js';
import { resolveTierPrice, priceOrder } from './pricing.js';

export const ACTIVE_INVOICE = ['UNPAID', 'PARTIAL'];
const HEAVY_TX = { timeout: 30_000, maxWait: 10_000 };

export const orderInclude = {
  partner: { include: { user: { select: { id: true, name: true, email: true, phone: true } } } },
  items: { orderBy: { id: 'asc' } },
  invoice: { include: { payments: { orderBy: { paidAt: 'asc' } } } },
};

// ───────────── Serializer ─────────────

export function invoiceDisplayStatus(inv, now = new Date()) {
  if (inv.status === 'PAID' || inv.status === 'VOID') return inv.status;
  return new Date(inv.dueDate) < now ? 'OVERDUE' : inv.status;
}

export function invoiceDto(inv) {
  const now = new Date();
  const displayStatus = invoiceDisplayStatus(inv, now);
  return {
    id: inv.id,
    invoiceNumber: inv.invoiceNumber,
    poId: inv.poId,
    poNumber: inv.po?.poNumber,
    partner: inv.partner ? { id: inv.partner.id, institutionName: inv.partner.institutionName } : undefined,
    issueDate: inv.issueDate,
    dueDate: inv.dueDate,
    subtotal: inv.subtotal,
    discount: inv.discount,
    tax: inv.tax,
    total: inv.total,
    amountPaid: inv.amountPaid,
    remaining: inv.total - inv.amountPaid,
    status: inv.status,
    displayStatus,
    daysOverdue: displayStatus === 'OVERDUE' ? Math.max(1, daysBetween(inv.dueDate, now)) : 0,
    daysUntilDue: ACTIVE_INVOICE.includes(inv.status) ? daysBetween(now, inv.dueDate) : null,
    paidAt: inv.paidAt,
    payments: inv.payments?.map((p) => ({
      id: p.id,
      amount: p.amount,
      method: p.method,
      reference: p.reference,
      note: p.note,
      paidAt: p.paidAt,
    })),
  };
}

export function orderDto(o) {
  return {
    id: o.id,
    poNumber: o.poNumber,
    partnerRef: o.partnerRef,
    status: o.status,
    subtotal: o.subtotal,
    levelName: o.levelName,
    levelDiscountPercent: o.levelDiscountPercent,
    discount: o.discount,
    taxPercent: o.taxPercent,
    tax: o.tax,
    total: o.total,
    note: o.note,
    rejectionReason: o.rejectionReason,
    createdAt: o.createdAt,
    approvedAt: o.approvedAt,
    readyAt: o.readyAt,
    completedAt: o.completedAt,
    cancelledAt: o.cancelledAt,
    partner: o.partner
      ? {
          id: o.partner.id,
          institutionName: o.partner.institutionName,
          institutionType: o.partner.institutionType,
          address: o.partner.address,
          npwp: o.partner.npwp,
          pic: o.partner.user?.name,
          email: o.partner.user?.email,
          phone: o.partner.user?.phone,
        }
      : undefined,
    itemCount: o.items?.length ?? o._count?.items ?? 0,
    items: o.items?.map((i) => ({
      id: i.id,
      productId: i.productId,
      sku: i.sku,
      productName: i.productName,
      unitName: i.unitName,
      unitQty: i.unitQty,
      conversion: i.conversion,
      baseQty: i.baseQty,
      retailUnitPrice: i.retailUnitPrice,
      tierUnitPrice: i.tierUnitPrice,
      unitPrice: i.tierUnitPrice * i.conversion,
      subtotal: i.subtotal,
      savings: Math.max(0, (i.retailUnitPrice - i.tierUnitPrice) * i.baseQty),
    })),
    invoice: o.invoice ? invoiceDto(o.invoice) : null,
  };
}

// ───────────── Quote (kalkulasi harga tiering) ─────────────

/**
 * Hitung harga PO tanpa menyimpan. Dipakai Quick PO (preview langsung) dan saat submit.
 * items: [{ productId? , sku?, unitName?, qty }]
 */
export async function quoteOrder(partner, items) {
  const ids = items.filter((i) => i.productId).map((i) => i.productId);
  const skus = items.filter((i) => !i.productId && i.sku).map((i) => i.sku.toUpperCase());
  const products = await prisma.product.findMany({
    where: { OR: [{ id: { in: ids } }, { sku: { in: skus } }] },
    include: { units: true, priceTiers: true },
  });
  const byId = new Map(products.map((p) => [p.id, p]));
  const bySku = new Map(products.map((p) => [p.sku.toUpperCase(), p]));

  const resolved = items.map((input, index) => {
    const product = input.productId ? byId.get(input.productId) : bySku.get(input.sku?.toUpperCase());
    if (!product || !product.isActive) {
      return { index, input, errors: [input.sku ? `SKU "${input.sku}" tidak ditemukan` : 'Produk tidak ditemukan'] };
    }
    const unit = findUnit(product.units, input.unitName);
    if (!unit) {
      const options = sortUnits(product.units).map((u) => u.name).join(', ');
      return { index, input, product, errors: [`Satuan "${input.unitName}" tidak tersedia (pilihan: ${options})`] };
    }
    return { index, input, product, unit, baseQty: toBase(input.qty, unit), errors: [] };
  });

  // Tier ditentukan dari total kuantitas per produk dalam satu PO.
  const totalByProduct = new Map();
  for (const r of resolved) {
    if (!r.errors.length) totalByProduct.set(r.product.id, (totalByProduct.get(r.product.id) ?? 0) + r.baseQty);
  }

  const lines = resolved.map((r) => {
    const unitsOf = (p) => sortUnits(p.units).map((u) => ({ name: u.name, conversion: u.conversion }));
    if (r.errors.length) {
      return {
        index: r.index,
        productId: r.product?.id ?? null,
        sku: r.product?.sku ?? r.input.sku ?? null,
        productName: r.product?.name ?? null,
        unitName: r.input.unitName ?? null,
        unitQty: r.input.qty,
        units: r.product ? unitsOf(r.product) : [],
        subtotal: 0,
        errors: r.errors,
        warnings: [],
      };
    }
    const p = r.product;
    const totalQty = totalByProduct.get(p.id);
    const retailUnitPrice = baseUnitOf(p.units)?.price ?? 0;
    const { unitPrice, tier, nextTier } = resolveTierPrice(totalQty, p.priceTiers, retailUnitPrice);
    const warnings = totalQty > p.stock ? [`Stok tersedia hanya ${formatQty(p.stock, p.units)}`] : [];
    return {
      index: r.index,
      productId: p.id,
      sku: p.sku,
      productName: p.name,
      unitName: r.unit.name,
      unitQty: r.input.qty,
      conversion: r.unit.conversion,
      baseQty: r.baseQty,
      units: unitsOf(p),
      retailUnitPrice,
      tierUnitPrice: unitPrice,
      tierMinQty: tier?.minQty ?? null,
      unitPrice: unitPrice * r.unit.conversion,
      subtotal: unitPrice * r.baseQty,
      savings: Math.max(0, (retailUnitPrice - unitPrice) * r.baseQty),
      nextTier: nextTier
        ? { ...nextTier, neededDisplay: formatQty(nextTier.needed, p.units), baseUnit: p.baseUnit }
        : null,
      stock: p.stock,
      stockDisplay: formatQty(p.stock, p.units),
      errors: [],
      warnings,
    };
  });

  const valid = lines.filter((l) => !l.errors.length);
  const { taxPercent } = await getSetting('b2b');
  const discountPercent = partner.level?.discountPercent ?? 0;
  const totals = priceOrder(
    valid.map((l) => ({ baseQty: l.baseQty, unitPrice: l.tierUnitPrice })),
    { discountPercent, taxPercent },
  );
  return {
    lines,
    summary: {
      itemCount: valid.length,
      subtotal: totals.subtotal,
      levelName: partner.level?.name ?? null,
      discountPercent,
      discount: totals.discount,
      taxPercent,
      tax: totals.tax,
      total: totals.total,
      savings: valid.reduce((s, l) => s + l.savings, 0) + totals.discount,
      hasErrors: lines.some((l) => l.errors.length > 0),
      hasStockIssues: lines.some((l) => l.warnings.length > 0),
    },
  };
}

// ───────────── Piutang ─────────────

export async function partnerOutstanding(partnerId) {
  const agg = await prisma.invoice.aggregate({
    where: { partnerId, status: { in: ACTIVE_INVOICE } },
    _sum: { total: true, amountPaid: true },
  });
  return (agg._sum.total ?? 0) - (agg._sum.amountPaid ?? 0);
}

export async function receivablesSummary(partnerId) {
  const invoices = await prisma.invoice.findMany({
    where: { status: { in: ACTIVE_INVOICE }, ...(partnerId && { partnerId }) },
    include: { partner: { select: { id: true, institutionName: true } } },
  });
  const now = new Date();
  const aging = { current: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90plus: 0 };
  const perPartner = new Map();
  let outstanding = 0;
  let overdue = 0;
  for (const inv of invoices) {
    const remaining = inv.total - inv.amountPaid;
    outstanding += remaining;
    const late = new Date(inv.dueDate) < now ? Math.max(1, daysBetween(inv.dueDate, now)) : 0;
    if (late > 0) overdue += remaining;
    const bucket = late === 0 ? 'current' : late <= 30 ? 'd1_30' : late <= 60 ? 'd31_60' : late <= 90 ? 'd61_90' : 'd90plus';
    aging[bucket] += remaining;
    const row = perPartner.get(inv.partnerId) ?? {
      partnerId: inv.partnerId,
      institutionName: inv.partner.institutionName,
      outstanding: 0,
      overdue: 0,
      invoiceCount: 0,
      oldestDueDate: inv.dueDate,
    };
    row.outstanding += remaining;
    row.overdue += late > 0 ? remaining : 0;
    row.invoiceCount++;
    if (inv.dueDate < row.oldestDueDate) row.oldestDueDate = inv.dueDate;
    perPartner.set(inv.partnerId, row);
  }
  return {
    outstanding,
    overdue,
    invoiceCount: invoices.length,
    aging,
    partners: [...perPartner.values()].sort((a, b) => b.overdue - a.overdue || b.outstanding - a.outstanding),
  };
}

// ───────────── Siklus hidup PO ─────────────

async function loadOrder(id) {
  const order = await prisma.purchaseOrder.findUnique({ where: { id }, include: orderInclude });
  if (!order) throw notFound('PO tidak ditemukan');
  return order;
}

export async function getOrderForPartner(id, partnerId) {
  const order = await loadOrder(id);
  if (order.partnerId !== partnerId) throw notFound('PO tidak ditemukan');
  return order;
}

export { loadOrder };

function broadcastOrder(order) {
  publish('order.updated', { id: order.id, poNumber: order.poNumber, status: order.status }, [
    'staff',
    `user:${order.partner.userId}`,
  ]);
}

export async function createOrder(user, partner, { items, note, partnerRef }) {
  const quote = await quoteOrder(partner, items);
  if (quote.summary.hasErrors) {
    throw badRequest(
      'Masih ada baris pesanan yang tidak valid',
      quote.lines.filter((l) => l.errors.length).map((l) => ({ field: `items.${l.index}`, message: l.errors.join('; ') })),
    );
  }
  if (quote.summary.hasStockIssues) {
    throw conflict(
      'Sebagian barang melebihi stok yang tersedia',
      quote.lines
        .filter((l) => l.warnings.length)
        .map((l) => ({ field: `items.${l.index}`, message: `${l.productName}: ${l.warnings.join('; ')}` })),
    );
  }

  if (partner.creditLimit > 0) {
    const [outstanding, pending] = await Promise.all([
      partnerOutstanding(partner.id),
      prisma.purchaseOrder.aggregate({ where: { partnerId: partner.id, status: 'SUBMITTED' }, _sum: { total: true } }),
    ]);
    const used = outstanding + (pending._sum.total ?? 0);
    if (used + quote.summary.total > partner.creditLimit) {
      throw conflict(
        `Pesanan melebihi batas kredit. Limit ${rupiah(partner.creditLimit)}, terpakai ${rupiah(used)}, sisa ${rupiah(Math.max(0, partner.creditLimit - used))}.`,
      );
    }
  }

  const s = quote.summary;
  const created = await prisma.$transaction(async (tx) => {
    const poNumber = await nextCode(tx, 'PO');
    return tx.purchaseOrder.create({
      data: {
        poNumber,
        partnerId: partner.id,
        partnerRef,
        note,
        subtotal: s.subtotal,
        levelName: s.levelName,
        levelDiscountPercent: s.discountPercent,
        discount: s.discount,
        taxPercent: s.taxPercent,
        tax: s.tax,
        total: s.total,
        createdById: user.id,
        items: {
          create: quote.lines.map((l) => ({
            productId: l.productId,
            sku: l.sku,
            productName: l.productName,
            unitName: l.unitName,
            unitQty: l.unitQty,
            conversion: l.conversion,
            baseQty: l.baseQty,
            retailUnitPrice: l.retailUnitPrice,
            tierUnitPrice: l.tierUnitPrice,
            subtotal: l.subtotal,
          })),
        },
      },
    });
  });
  const order = await loadOrder(created.id);
  broadcastOrder(order);
  notifyStaff({
    type: 'B2B_ORDER',
    title: `PO baru ${order.poNumber}`,
    body: `${partner.institutionName} mengajukan ${order.items.length} item senilai ${rupiah(order.total)}.`,
    link: `/admin/b2b-orders?id=${order.id}`,
  });
  audit(user.id, 'PO_SUBMIT', 'purchase_order', order.id, { poNumber: order.poNumber, total: order.total });
  return order;
}

export async function approveOrder(staff, id) {
  const { changes, invoiceNumber, dueDate } = await prisma.$transaction(async (tx) => {
    const upd = await tx.purchaseOrder.updateMany({
      where: { id, status: 'SUBMITTED' },
      data: { status: 'APPROVED', approvedAt: new Date(), approvedById: staff.id },
    });
    if (!upd.count) {
      const existing = await tx.purchaseOrder.findUnique({ where: { id } });
      if (!existing) throw notFound('PO tidak ditemukan');
      throw conflict(`PO berstatus ${existing.status}, tidak dapat diverifikasi`);
    }
    const order = await tx.purchaseOrder.findUnique({ where: { id }, include: { items: true, partner: true } });
    const changes = [];
    for (const item of order.items) {
      changes.push(
        await changeStock(tx, {
          productId: item.productId,
          qty: -item.baseQty,
          type: 'B2B_ORDER',
          unitName: item.unitName,
          unitQty: item.unitQty,
          refType: 'PO',
          refId: order.id,
          refCode: order.poNumber,
          note: order.partner.institutionName,
          userId: staff.id,
        }),
      );
    }
    const invoiceNumber = await nextCode(tx, 'INV');
    const issueDate = new Date();
    const dueDate = addDays(issueDate, order.partner.paymentTermDays);
    dueDate.setHours(23, 59, 59, 0);
    await tx.invoice.create({
      data: {
        invoiceNumber,
        poId: order.id,
        partnerId: order.partnerId,
        issueDate,
        dueDate,
        subtotal: order.subtotal,
        discount: order.discount,
        tax: order.tax,
        total: order.total,
      },
    });
    return { changes, invoiceNumber, dueDate };
  }, HEAVY_TX);

  announceStockChanges(changes);
  const order = await loadOrder(id);
  broadcastOrder(order);
  notifyUser(order.partner.userId, {
    type: 'B2B_ORDER',
    title: `PO ${order.poNumber} disetujui`,
    body: `Faktur ${invoiceNumber} telah terbit dengan jatuh tempo ${longDate(dueDate)}.`,
    link: `/b2b/orders?id=${order.id}`,
  });
  audit(staff.id, 'PO_APPROVE', 'purchase_order', id, { invoiceNumber });
  return order;
}

async function transition(id, from, to, data = {}) {
  const upd = await prisma.purchaseOrder.updateMany({ where: { id, status: { in: from } }, data: { status: to, ...data } });
  if (!upd.count) {
    const existing = await prisma.purchaseOrder.findUnique({ where: { id } });
    if (!existing) throw notFound('PO tidak ditemukan');
    throw conflict(`PO berstatus ${existing.status}, aksi tidak dapat dilakukan`);
  }
  const order = await loadOrder(id);
  broadcastOrder(order);
  return order;
}

export async function rejectOrder(staff, id, reason) {
  const order = await transition(id, ['SUBMITTED'], 'REJECTED', { rejectionReason: reason });
  notifyUser(order.partner.userId, {
    type: 'B2B_ORDER',
    title: `PO ${order.poNumber} ditolak`,
    body: `Alasan: ${reason}`,
    link: `/b2b/orders?id=${order.id}`,
  });
  audit(staff.id, 'PO_REJECT', 'purchase_order', id, { reason });
  return order;
}

export async function markReady(staff, id) {
  const order = await transition(id, ['APPROVED'], 'READY', { readyAt: new Date() });
  notifyUser(order.partner.userId, {
    type: 'B2B_ORDER',
    title: `Pesanan ${order.poNumber} siap diambil`,
    body: 'Barang pesanan Anda sudah disiapkan dan dapat diambil di toko.',
    link: `/b2b/orders?id=${order.id}`,
  });
  audit(staff.id, 'PO_READY', 'purchase_order', id);
  return order;
}

export async function markCompleted(staff, id) {
  const order = await transition(id, ['READY'], 'COMPLETED', { completedAt: new Date() });
  audit(staff.id, 'PO_COMPLETE', 'purchase_order', id);
  return order;
}

/** Batalkan PO. Mitra hanya bisa saat SUBMITTED; staf juga saat APPROVED/READY (stok dikembalikan, faktur VOID). */
export async function cancelOrder(actor, id, reason, { byPartner }) {
  const order = await loadOrder(id);
  if (byPartner && order.partnerId !== actor.partner?.id) throw notFound('PO tidak ditemukan');
  const allowed = byPartner ? ['SUBMITTED'] : ['SUBMITTED', 'APPROVED', 'READY'];
  if (!allowed.includes(order.status)) {
    throw conflict(
      byPartner
        ? 'PO yang sudah diverifikasi tidak dapat dibatalkan dari portal. Hubungi toko.'
        : `PO berstatus ${order.status} tidak dapat dibatalkan`,
    );
  }
  if (order.invoice && order.invoice.amountPaid > 0) {
    throw conflict('Faktur PO ini sudah menerima pembayaran sehingga tidak dapat dibatalkan otomatis');
  }
  const restock = ['APPROVED', 'READY'].includes(order.status);
  const changes = await prisma.$transaction(async (tx) => {
    const upd = await tx.purchaseOrder.updateMany({
      where: { id, status: order.status },
      data: { status: 'CANCELLED', cancelledAt: new Date(), rejectionReason: reason ?? null },
    });
    if (!upd.count) throw conflict('Status PO berubah, muat ulang halaman');
    const changes = [];
    if (restock) {
      for (const item of order.items) {
        changes.push(
          await changeStock(tx, {
            productId: item.productId,
            qty: item.baseQty,
            type: 'RETURN',
            unitName: item.unitName,
            unitQty: item.unitQty,
            refType: 'PO',
            refId: order.id,
            refCode: order.poNumber,
            note: 'Pembatalan PO',
            userId: actor.id,
          }),
        );
      }
      if (order.invoice) await tx.invoice.update({ where: { id: order.invoice.id }, data: { status: 'VOID' } });
    }
    return changes;
  }, HEAVY_TX);
  if (changes.length) announceStockChanges(changes);
  const updated = await loadOrder(id);
  broadcastOrder(updated);
  if (byPartner) {
    notifyStaff({ type: 'B2B_ORDER', title: `PO ${order.poNumber} dibatalkan mitra`, body: order.partner.institutionName });
  } else {
    notifyUser(order.partner.userId, {
      type: 'B2B_ORDER',
      title: `PO ${order.poNumber} dibatalkan`,
      body: reason ? `Alasan: ${reason}` : 'PO dibatalkan oleh toko.',
      link: `/b2b/orders?id=${order.id}`,
    });
  }
  audit(actor.id, 'PO_CANCEL', 'purchase_order', id, { reason, byPartner });
  return updated;
}

// ───────────── Pembayaran faktur ─────────────

export async function recordInvoicePayment(staff, invoiceId, body) {
  const inv = await prisma.$transaction(async (tx) => {
    const inv = await tx.invoice.findUnique({ where: { id: invoiceId } });
    if (!inv) throw notFound('Faktur tidak ditemukan');
    if (inv.status === 'VOID') throw conflict('Faktur sudah dibatalkan');
    if (inv.status === 'PAID') throw conflict('Faktur sudah lunas');
    const remaining = inv.total - inv.amountPaid;
    if (body.amount > remaining) throw badRequest(`Nominal melebihi sisa tagihan (${rupiah(remaining)})`);
    const paidAt = body.paidAt ?? new Date();
    await tx.invoicePayment.create({
      data: {
        invoiceId,
        amount: body.amount,
        method: body.method,
        reference: body.reference,
        note: body.note,
        paidAt,
        recordedById: staff.id,
      },
    });
    const amountPaid = inv.amountPaid + body.amount;
    const status = amountPaid >= inv.total ? 'PAID' : 'PARTIAL';
    // Optimistic lock: gagal jika ada pembayaran lain tercatat bersamaan.
    const upd = await tx.invoice.updateMany({
      where: { id: invoiceId, amountPaid: inv.amountPaid },
      data: { amountPaid, status, paidAt: status === 'PAID' ? paidAt : null },
    });
    if (!upd.count) throw conflict('Faktur sedang diperbarui pengguna lain, coba lagi');
    return tx.invoice.findUnique({
      where: { id: invoiceId },
      include: { po: true, partner: true, payments: { orderBy: { paidAt: 'asc' } } },
    });
  });
  notifyUser(inv.partner.userId, {
    type: 'INVOICE',
    title: inv.status === 'PAID' ? `Faktur ${inv.invoiceNumber} lunas` : `Pembayaran faktur ${inv.invoiceNumber} diterima`,
    body: `Pembayaran ${rupiah(body.amount)} telah dicatat. Sisa tagihan ${rupiah(inv.total - inv.amountPaid)}.`,
    link: '/b2b/invoices',
  });
  publish('invoice.updated', { id: inv.id, status: inv.status }, ['staff', `user:${inv.partner.userId}`]);
  audit(staff.id, 'INVOICE_PAYMENT', 'invoice', invoiceId, { amount: body.amount, method: body.method });
  return inv;
}

// ───────────── PDF ─────────────

export async function sendOrderPdf(res, order, kind) {
  if (kind === 'INVOICE' && !order.invoice) throw notFound('Faktur belum terbit untuk PO ini');
  const [store, b2b] = await Promise.all([getSetting('store_profile'), getSetting('b2b')]);
  const filename = kind === 'INVOICE' ? order.invoice.invoiceNumber : order.poNumber;
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `inline; filename="${filename}.pdf"`);
  renderOrderPdf(res, { kind, order, invoice: order.invoice, store, b2b });
}
