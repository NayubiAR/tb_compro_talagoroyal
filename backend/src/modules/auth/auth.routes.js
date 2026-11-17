import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { rateLimit } from 'express-rate-limit';
import { prisma } from '../../lib/prisma.js';
import { parse, optionalText, z } from '../../lib/validate.js';
import { badRequest, conflict, unauthorized } from '../../lib/errors.js';
import { notifyStaff, audit } from '../../lib/notify.js';
import { authenticate, authorize, signToken, signDownloadToken, publicUser } from '../../middleware/auth.js';

const router = Router();

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 20,
  skipSuccessfulRequests: true, // hanya percobaan gagal yang dihitung (anti brute-force)
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: { message: 'Terlalu banyak percobaan login. Coba lagi 15 menit lagi.' } },
});

const email = z.string().trim().toLowerCase().pipe(z.email('Format email tidak valid').max(160));
const password = z.string().min(8, 'Password minimal 8 karakter').max(72);
const phone = z.string().trim().regex(/^[0-9+\-\s]{8,20}$/, 'Nomor HP tidak valid');

const registerSchema = z.object({
  name: z.string().trim().min(2).max(120),
  email,
  phone: phone.optional(),
  password,
});

const institutionSchema = z.object({
  institutionName: z.string().trim().min(3).max(160),
  institutionType: z.enum(['SEKOLAH', 'KANTOR', 'INSTANSI', 'PERUSAHAAN', 'LAINNYA']),
  npwp: optionalText(30),
  address: z.string().trim().min(5).max(255),
});

const userInclude = { partner: { include: { level: true } } };

async function ensureEmailFree(addr) {
  if (await prisma.user.findUnique({ where: { email: addr } })) throw conflict('Email sudah terdaftar');
}

router.post('/register', async (req, res) => {
  const body = parse(registerSchema, req.body);
  await ensureEmailFree(body.email);
  const user = await prisma.user.create({
    data: {
      name: body.name,
      email: body.email,
      phone: body.phone ?? null,
      role: 'CUSTOMER',
      passwordHash: await bcrypt.hash(body.password, 10),
    },
    include: userInclude,
  });
  res.status(201).json({ data: { token: signToken(user), user: publicUser(user) } });
});

/** Pendaftaran mitra institusi → status PENDING sampai diverifikasi staf toko. */
router.post('/register-partner', async (req, res) => {
  const body = parse(registerSchema.extend({ phone, ...institutionSchema.shape }), req.body);
  await ensureEmailFree(body.email);
  const user = await prisma.user.create({
    data: {
      name: body.name,
      email: body.email,
      phone: body.phone,
      role: 'B2B',
      passwordHash: await bcrypt.hash(body.password, 10),
      partner: {
        create: {
          institutionName: body.institutionName,
          institutionType: body.institutionType,
          npwp: body.npwp,
          address: body.address,
        },
      },
    },
    include: userInclude,
  });
  notifyStaff({
    type: 'PARTNER',
    title: 'Pendaftaran mitra B2B baru',
    body: `${body.institutionName} menunggu verifikasi.`,
    link: '/admin/partners',
  });
  res.status(201).json({ data: { token: signToken(user), user: publicUser(user) } });
});

router.post('/login', loginLimiter, async (req, res) => {
  const body = parse(z.object({ email, password: z.string().min(1) }), req.body);
  const user = await prisma.user.findUnique({ where: { email: body.email }, include: userInclude });
  const ok = user && (await bcrypt.compare(body.password, user.passwordHash));
  if (!ok) throw unauthorized('Email atau password salah');
  if (!user.isActive) throw unauthorized('Akun Anda dinonaktifkan. Hubungi Talago Royal.');
  await prisma.user.update({ where: { id: user.id }, data: { lastLoginAt: new Date() } });
  res.json({ data: { token: signToken(user), user: publicUser(user) } });
});

router.get('/me', authenticate, (req, res) => {
  res.json({ data: publicUser(req.user) });
});

router.patch('/me', authenticate, async (req, res) => {
  const body = parse(z.object({ name: z.string().trim().min(2).max(120), phone: phone.nullish() }), req.body);
  const user = await prisma.user.update({
    where: { id: req.user.id },
    data: { name: body.name, phone: body.phone ?? null },
    include: userInclude,
  });
  res.json({ data: publicUser(user) });
});

router.post('/change-password', authenticate, async (req, res) => {
  const body = parse(z.object({ currentPassword: z.string().min(1), newPassword: password }), req.body);
  if (!(await bcrypt.compare(body.currentPassword, req.user.passwordHash))) {
    throw badRequest('Password saat ini salah');
  }
  await prisma.user.update({
    where: { id: req.user.id },
    data: { passwordHash: await bcrypt.hash(body.newPassword, 10) },
  });
  audit(req.user.id, 'PASSWORD_CHANGE', 'user', req.user.id);
  res.json({ data: { ok: true } });
});

/** Mitra memperbarui data institusi; jika sebelumnya ditolak, diajukan ulang untuk verifikasi. */
router.put('/partner', authenticate, authorize('B2B'), async (req, res) => {
  const body = parse(institutionSchema, req.body);
  const partner = req.user.partner;
  const resubmit = partner.status === 'REJECTED';
  await prisma.partner.update({
    where: { id: partner.id },
    data: { ...body, ...(resubmit && { status: 'PENDING', rejectionReason: null }) },
  });
  if (resubmit) {
    notifyStaff({
      type: 'PARTNER',
      title: 'Pengajuan ulang mitra B2B',
      body: `${body.institutionName} mengajukan verifikasi ulang.`,
      link: '/admin/partners',
    });
  }
  const user = await prisma.user.findUnique({ where: { id: req.user.id }, include: userInclude });
  res.json({ data: publicUser(user) });
});

/** Token unduhan sekali pakai (2 menit) untuk membuka PDF/berkas di tab browser baru. */
router.post('/download-token', authenticate, (req, res) => {
  const { path } = parse(
    z.object({ path: z.string().regex(/^\/api\/[A-Za-z0-9/_-]+$/, 'Path tidak valid') }),
    req.body,
  );
  const token = signDownloadToken(req.user.id, path);
  res.json({ data: { token, url: `${path}?dl=${token}` } });
});

export default router;
