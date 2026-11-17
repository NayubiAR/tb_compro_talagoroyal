// Manajemen akun staf (khusus Pemilik Toko).
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { prisma } from '../../lib/prisma.js';
import { authenticate, authorize, publicUser } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, z } from '../../lib/validate.js';
import { badRequest, conflict, notFound } from '../../lib/errors.js';
import { audit } from '../../lib/notify.js';

const router = Router();
router.use(authenticate, authorize('OWNER'));

const include = { partner: { include: { level: true } } };

router.get('/', async (req, res) => {
  const q = parse(
    pageSchema.extend({
      role: z.enum(['OWNER', 'ADMIN', 'B2B', 'CUSTOMER']).optional(),
      q: z.string().trim().optional(),
    }),
    req.query,
  );
  const where = {};
  if (q.role) where.role = q.role;
  if (q.q) where.OR = [{ name: { contains: q.q } }, { email: { contains: q.q } }];
  const [total, rows] = await Promise.all([
    prisma.user.count({ where }),
    prisma.user.findMany({ where, include, orderBy: { id: 'desc' }, ...paginate(q) }),
  ]);
  res.json({
    data: rows.map((u) => ({ ...publicUser(u), lastLoginAt: u.lastLoginAt })),
    meta: pageMeta(total, q),
  });
});

router.post('/', async (req, res) => {
  const body = parse(
    z.object({
      name: z.string().trim().min(2).max(120),
      email: z.string().trim().toLowerCase().pipe(z.email().max(160)),
      phone: z.string().trim().max(30).nullish(),
      password: z.string().min(8).max(72),
      role: z.enum(['ADMIN', 'OWNER']),
    }),
    req.body,
  );
  if (await prisma.user.findUnique({ where: { email: body.email } })) throw conflict('Email sudah terdaftar');
  const user = await prisma.user.create({
    data: {
      name: body.name,
      email: body.email,
      phone: body.phone ?? null,
      role: body.role,
      passwordHash: await bcrypt.hash(body.password, 10),
    },
    include,
  });
  audit(req.user.id, 'USER_CREATE', 'user', user.id, { role: user.role });
  res.status(201).json({ data: publicUser(user) });
});

router.patch('/:id', async (req, res) => {
  const id = parseId(req.params.id);
  const body = parse(
    z.object({
      name: z.string().trim().min(2).max(120).optional(),
      phone: z.string().trim().max(30).nullish(),
      role: z.enum(['ADMIN', 'OWNER']).optional(),
      isActive: z.boolean().optional(),
    }),
    req.body,
  );
  const target = await prisma.user.findUnique({ where: { id } });
  if (!target) throw notFound('Pengguna tidak ditemukan');
  if (id === req.user.id && (body.isActive === false || (body.role && body.role !== 'OWNER'))) {
    throw badRequest('Anda tidak dapat menonaktifkan atau menurunkan peran akun sendiri');
  }
  if (body.role && !['ADMIN', 'OWNER'].includes(target.role)) {
    throw badRequest('Peran hanya bisa diubah untuk akun staf');
  }
  const user = await prisma.user.update({
    where: { id },
    data: {
      ...(body.name && { name: body.name }),
      ...(body.phone !== undefined && { phone: body.phone }),
      ...(body.role && { role: body.role }),
      ...(body.isActive !== undefined && { isActive: body.isActive }),
    },
    include,
  });
  audit(req.user.id, 'USER_UPDATE', 'user', id, body);
  res.json({ data: publicUser(user) });
});

router.post('/:id/reset-password', async (req, res) => {
  const id = parseId(req.params.id);
  const { password } = parse(z.object({ password: z.string().min(8).max(72) }), req.body);
  await prisma.user.update({ where: { id }, data: { passwordHash: await bcrypt.hash(password, 10) } });
  audit(req.user.id, 'USER_RESET_PASSWORD', 'user', id);
  res.json({ data: { ok: true } });
});

export default router;
