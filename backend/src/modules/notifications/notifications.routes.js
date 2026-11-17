import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { authenticate } from '../../middleware/auth.js';
import { parse, parseId, z } from '../../lib/validate.js';

const router = Router();
router.use(authenticate);

router.get('/', async (req, res) => {
  const q = parse(
    z.object({
      unread: z.enum(['true', 'false']).optional(),
      limit: z.coerce.number().int().min(1).max(100).default(30),
    }),
    req.query,
  );
  const where = { userId: req.user.id, ...(q.unread === 'true' && { readAt: null }) };
  const [rows, unreadCount] = await Promise.all([
    prisma.notification.findMany({ where, orderBy: { id: 'desc' }, take: q.limit }),
    prisma.notification.count({ where: { userId: req.user.id, readAt: null } }),
  ]);
  res.json({ data: rows, meta: { unreadCount } });
});

router.post('/read-all', async (req, res) => {
  const r = await prisma.notification.updateMany({
    where: { userId: req.user.id, readAt: null },
    data: { readAt: new Date() },
  });
  res.json({ data: { updated: r.count } });
});

router.post('/:id/read', async (req, res) => {
  await prisma.notification.updateMany({
    where: { id: parseId(req.params.id), userId: req.user.id, readAt: null },
    data: { readAt: new Date() },
  });
  res.json({ data: { ok: true } });
});

export default router;
