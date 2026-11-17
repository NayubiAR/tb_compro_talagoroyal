import { Router } from 'express';
import path from 'node:path';
import crypto from 'node:crypto';
import multer from 'multer';
import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, parseId, pageSchema, paginate, pageMeta, optionalText, dateQuery, z } from '../../lib/validate.js';
import { badRequest, notFound, forbidden, conflict } from '../../lib/errors.js';
import { getSetting } from '../../lib/settings.js';
import { addDays } from '../../lib/dates.js';
import { ALLOWED_EXT } from './pagecount.js';
import { PAPER_SIZES, COLOR_MODES, BINDINGS, ORIENTATIONS } from './pricing.js';
import {
  printDir,
  printJobDto,
  createDraft,
  getOwnJob,
  quoteJob,
  checkout,
  checkPayment,
  cancelJob,
  staffQueue,
  updateQueueStatus,
  findByPickupCode,
  publicQueue,
  ACTIVE_QUEUE,
} from './printing.service.js';

const router = Router();

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, printDir()),
    filename: (_req, file, cb) => cb(null, `${crypto.randomUUID()}${path.extname(file.originalname).toLowerCase()}`),
  }),
  limits: { fileSize: env.maxUploadMb * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (!ALLOWED_EXT.includes(ext)) return cb(badRequest('Format berkas harus .pdf, .doc, atau .docx'));
    cb(null, true);
  },
});

const configSchema = z.object({
  colorMode: z.enum(COLOR_MODES).default('BW'),
  paperSize: z.enum(PAPER_SIZES).default('A4'),
  orientation: z.enum(ORIENTATIONS).default('PORTRAIT'),
  duplex: z.boolean().default(false),
  copies: z.number().int().min(1).max(100).default(1),
  binding: z.enum(BINDINGS).default('NONE'),
  pageRange: optionalText(120),
  notes: optionalText(500),
});

const customerOnly = [authenticate, authorize('CUSTOMER', 'B2B')];
const staffOnly = [authenticate, authorize(...STAFF)];

// ───────────── Publik & umum ─────────────

router.get('/queue/public', async (_req, res) => {
  res.json({ data: await publicQueue() });
});

router.get('/pricing', authenticate, async (_req, res) => {
  res.json({
    data: {
      ...(await getSetting('print_pricing')),
      maxUploadMb: env.maxUploadMb,
      allowedExtensions: ALLOWED_EXT,
      paymentExpiryMinutes: env.payment.expiryMinutes,
    },
  });
});

// ───────────── Pelanggan ─────────────

router.post('/jobs', ...customerOnly, upload.single('file'), async (req, res) => {
  if (!req.file) throw badRequest('Berkas wajib diunggah (field "file")');
  const job = await createDraft(req.user, req.file);
  res.status(201).json({ data: printJobDto(job) });
});

router.get('/jobs', ...customerOnly, async (req, res) => {
  const q = parse(pageSchema.extend({ scope: z.enum(['active', 'history', 'all']).default('all') }), req.query);
  const where = { customerId: req.user.id, status: { not: 'DRAFT' } };
  if (q.scope === 'active') where.status = { in: ['AWAITING_PAYMENT', ...ACTIVE_QUEUE] };
  if (q.scope === 'history') where.status = { in: ['COMPLETED', 'CANCELLED', 'EXPIRED'] };
  const [total, rows] = await Promise.all([
    prisma.printJob.count({ where }),
    prisma.printJob.findMany({
      where,
      orderBy: { id: 'desc' },
      include: { payments: { orderBy: { id: 'desc' }, take: 1 } },
      ...paginate(q),
    }),
  ]);
  res.json({ data: rows.map((j) => printJobDto(j)), meta: pageMeta(total, q) });
});

router.get('/jobs/:id', ...customerOnly, async (req, res) => {
  res.json({ data: printJobDto(await getOwnJob(req.user, parseId(req.params.id))) });
});

router.post('/jobs/:id/quote', ...customerOnly, async (req, res) => {
  const cfg = parse(configSchema, req.body);
  const job = await getOwnJob(req.user, parseId(req.params.id));
  res.json({ data: await quoteJob(job, cfg) });
});

router.post('/jobs/:id/checkout', ...customerOnly, async (req, res) => {
  const cfg = parse(configSchema, req.body);
  const job = await checkout(req.user, parseId(req.params.id), cfg);
  res.json({ data: printJobDto(job) });
});

router.post('/jobs/:id/check-payment', ...customerOnly, async (req, res) => {
  res.json({ data: printJobDto(await checkPayment(req.user, parseId(req.params.id))) });
});

router.post('/jobs/:id/cancel', ...customerOnly, async (req, res) => {
  res.json({ data: printJobDto(await cancelJob(req.user, parseId(req.params.id))) });
});

/** Unduh berkas: pemilik pesanan atau staf (mendukung token unduhan ?dl=). */
router.get('/jobs/:id/file', authenticate, async (req, res) => {
  const job = await prisma.printJob.findUnique({ where: { id: parseId(req.params.id) } });
  if (!job) throw notFound('Pesanan cetak tidak ditemukan');
  if (job.customerId !== req.user.id && !STAFF.includes(req.user.role)) throw forbidden();
  if (job.fileDeletedAt) throw conflict('Berkas sudah dihapus sesuai kebijakan retensi');
  const ext = job.mimeType === 'application/pdf' ? '.pdf' : path.extname(job.originalName);
  const downloadName = `${job.code}_${path.parse(job.originalName).name}${ext}`;
  res.download(path.join(printDir(), job.storedName), downloadName);
});

// ───────────── Staf / kasir ─────────────

router.get('/queue', ...staffOnly, async (_req, res) => {
  res.json({ data: await staffQueue() });
});

router.patch('/queue/:id', ...staffOnly, async (req, res) => {
  const body = parse(
    z.object({
      status: z.enum(['QUEUED', 'PRINTING', 'READY', 'COMPLETED']),
      pickupCode: z.string().trim().regex(/^\d{6}$/, 'Kode ambil 6 digit').optional(),
    }),
    req.body,
  );
  const job = await updateQueueStatus(req.user, parseId(req.params.id), body);
  res.json({ data: printJobDto(job, { forStaff: true }) });
});

router.get('/queue/pickup/:code', ...staffOnly, async (req, res) => {
  const code = parse(z.string().regex(/^\d{6}$/, 'Kode ambil 6 digit'), req.params.code);
  res.json({ data: await findByPickupCode(code) });
});

router.get('/admin/jobs', ...staffOnly, async (req, res) => {
  const q = parse(
    pageSchema.extend({
      status: z
        .enum(['AWAITING_PAYMENT', 'QUEUED', 'PRINTING', 'READY', 'COMPLETED', 'CANCELLED', 'EXPIRED'])
        .optional(),
      q: z.string().trim().optional(),
      from: dateQuery.optional(),
      to: dateQuery.optional(),
    }),
    req.query,
  );
  const where = { status: q.status ?? { not: 'DRAFT' } };
  if (q.from || q.to) where.createdAt = { ...(q.from && { gte: q.from }), ...(q.to && { lt: addDays(q.to, 1) }) };
  if (q.q) {
    where.OR = [
      { code: { contains: q.q } },
      { originalName: { contains: q.q } },
      { customer: { name: { contains: q.q } } },
    ];
  }
  const [total, rows] = await Promise.all([
    prisma.printJob.count({ where }),
    prisma.printJob.findMany({
      where,
      orderBy: { id: 'desc' },
      include: {
        customer: { select: { id: true, name: true, phone: true, email: true } },
        payments: { orderBy: { id: 'desc' }, take: 1 },
      },
      ...paginate(q),
    }),
  ]);
  res.json({ data: rows.map((j) => printJobDto(j, { forStaff: true })), meta: pageMeta(total, q) });
});

export default router;
