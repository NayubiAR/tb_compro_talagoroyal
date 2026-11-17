// Verifikasi & pengelolaan mitra B2B oleh staf toko.
import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, z } from '../../lib/validate.js';
import { conflict, notFound } from '../../lib/errors.js';
import { notifyUser, audit } from '../../lib/notify.js';
import { ACTIVE_INVOICE, orderDto } from '../b2b/b2b.service.js';

const router = Router();
router.use(authenticate, authorize(...STAFF));

// ───────────── Level mitra (Reguler/Silver/Gold/…) ─────────────

const levelSchema = z.object({
  name: z.string().trim().min(2).max(40),
  discountPercent: z.number().min(0).max(50),
  description: z.string().trim().max(255).nullish(),
});

router.get('/levels', async (_req, res) => {
  const levels = await prisma.partnerLevel.findMany({
    orderBy: { discountPercent: 'asc' },
    include: { _count: { select: { partners: true } } },
  });
  res.json({ data: levels.map((l) => ({ ...l, partnerCount: l._count.partners, _count: undefined })) });
});

router.post('/levels', authorize('OWNER'), async (req, res) => {
  const body = parse(levelSchema, req.body);
  const level = await prisma.partnerLevel.create({ data: body });
  audit(req.user.id, 'LEVEL_CREATE', 'partner_level', level.id, body);
  res.status(201).json({ data: level });
});

router.patch('/levels/:id', authorize('OWNER'), async (req, res) => {
  const id = parseId(req.params.id);
  const body = parse(levelSchema.partial(), req.body);
  const level = await prisma.partnerLevel.update({ where: { id }, data: body });
  audit(req.user.id, 'LEVEL_UPDATE', 'partner_level', id, body);
  res.json({ data: level });
});

// ───────────── Mitra ─────────────

async function outstandingByPartner(ids) {
  if (!ids.length) return new Map();
  const rows = await prisma.invoice.groupBy({
    by: ['partnerId'],
    where: { partnerId: { in: ids }, status: { in: ACTIVE_INVOICE } },
    _sum: { total: true, amountPaid: true },
  });
  return new Map(rows.map((r) => [r.partnerId, (r._sum.total ?? 0) - (r._sum.amountPaid ?? 0)]));
}

function partnerDto(p, outstanding = 0) {
  return {
    id: p.id,
    institutionName: p.institutionName,
    institutionType: p.institutionType,
    npwp: p.npwp,
    address: p.address,
    status: p.status,
    levelId: p.levelId,
    level: p.level?.name ?? null,
    discountPercent: p.level?.discountPercent ?? 0,
    paymentTermDays: p.paymentTermDays,
    creditLimit: p.creditLimit,
    outstanding,
    verifiedAt: p.verifiedAt,
    rejectionReason: p.rejectionReason,
    createdAt: p.createdAt,
    user: p.user
      ? { id: p.user.id, name: p.user.name, email: p.user.email, phone: p.user.phone, isActive: p.user.isActive }
      : undefined,
  };
}

const include = { user: true, level: true };

router.get('/', async (req, res) => {
  const q = parse(
    pageSchema.extend({
      status: z.enum(['PENDING', 'VERIFIED', 'REJECTED', 'SUSPENDED']).optional(),
      q: z.string().trim().optional(),
    }),
    req.query,
  );
  const where = {};
  if (q.status) where.status = q.status;
  if (q.q) {
    where.OR = [
      { institutionName: { contains: q.q } },
      { user: { name: { contains: q.q } } },
      { user: { email: { contains: q.q } } },
    ];
  }
  const [total, rows, counts] = await Promise.all([
    prisma.partner.count({ where }),
    prisma.partner.findMany({ where, include, orderBy: [{ status: 'asc' }, { id: 'desc' }], ...paginate(q) }),
    prisma.partner.groupBy({ by: ['status'], _count: { _all: true } }),
  ]);
  const outstanding = await outstandingByPartner(rows.map((r) => r.id));
  res.json({
    data: rows.map((p) => partnerDto(p, outstanding.get(p.id) ?? 0)),
    meta: { ...pageMeta(total, q), counts: Object.fromEntries(counts.map((c) => [c.status, c._count._all])) },
  });
});

router.get('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const partner = await prisma.partner.findUnique({ where: { id }, include });
  if (!partner) throw notFound('Mitra tidak ditemukan');
  const [outstanding, recentOrders, totals] = await Promise.all([
    outstandingByPartner([id]),
    prisma.purchaseOrder.findMany({
      where: { partnerId: id },
      orderBy: { id: 'desc' },
      take: 10,
      include: { invoice: true, _count: { select: { items: true } } },
    }),
    prisma.purchaseOrder.aggregate({
      where: { partnerId: id, status: { in: ['APPROVED', 'READY', 'COMPLETED'] } },
      _sum: { total: true },
      _count: { _all: true },
    }),
  ]);
  res.json({
    data: {
      ...partnerDto(partner, outstanding.get(id) ?? 0),
      lifetimeValue: totals._sum.total ?? 0,
      orderCount: totals._count._all,
      recentOrders: recentOrders.map(orderDto),
    },
  });
});

const termsSchema = z.object({
  levelId: z.number().int().positive().nullish(),
  paymentTermDays: z.number().int().min(0).max(180),
  creditLimit: z.number().int().min(0),
});

router.post('/:id/verify', async (req, res) => {
  const id = parseId(req.params.id);
  const body = parse(termsSchema, req.body);
  const partner = await prisma.partner.findUnique({ where: { id } });
  if (!partner) throw notFound('Mitra tidak ditemukan');
  if (partner.status === 'VERIFIED') throw conflict('Mitra sudah terverifikasi');
  const updated = await prisma.partner.update({
    where: { id },
    data: { ...body, status: 'VERIFIED', verifiedAt: new Date(), rejectionReason: null },
    include,
  });
  notifyUser(updated.userId, {
    type: 'PARTNER',
    title: 'Akun mitra B2B terverifikasi',
    body: `Selamat! ${updated.institutionName} kini dapat mengakses katalog harga khusus${updated.level ? ` level ${updated.level.name}` : ''}.`,
    link: '/b2b',
  });
  audit(req.user.id, 'PARTNER_VERIFY', 'partner', id, body);
  res.json({ data: partnerDto(updated) });
});

router.post('/:id/reject', async (req, res) => {
  const id = parseId(req.params.id);
  const { reason } = parse(z.object({ reason: z.string().trim().min(3).max(255) }), req.body);
  const updated = await prisma.partner.update({
    where: { id },
    data: { status: 'REJECTED', rejectionReason: reason },
    include,
  });
  notifyUser(updated.userId, {
    type: 'PARTNER',
    title: 'Pengajuan mitra B2B ditolak',
    body: `Alasan: ${reason}. Anda dapat memperbaiki data institusi lalu mengajukan ulang.`,
    link: '/b2b',
  });
  audit(req.user.id, 'PARTNER_REJECT', 'partner', id, { reason });
  res.json({ data: partnerDto(updated) });
});

router.patch('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const body = parse(termsSchema.partial().extend({ status: z.enum(['VERIFIED', 'SUSPENDED']).optional() }), req.body);
  const updated = await prisma.partner.update({ where: { id }, data: body, include });
  if (body.status === 'SUSPENDED') {
    notifyUser(updated.userId, {
      type: 'PARTNER',
      title: 'Akun mitra ditangguhkan',
      body: 'Akses pemesanan B2B Anda sementara ditangguhkan. Hubungi Talago Royal untuk informasi.',
    });
  }
  audit(req.user.id, 'PARTNER_UPDATE', 'partner', id, body);
  const outstanding = await outstandingByPartner([id]);
  res.json({ data: partnerDto(updated, outstanding.get(id) ?? 0) });
});

export default router;
