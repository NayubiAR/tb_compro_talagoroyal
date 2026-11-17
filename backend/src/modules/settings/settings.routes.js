import { Router } from 'express';
import { authenticate, authorize, STAFF } from '../../middleware/auth.js';
import { parse, z } from '../../lib/validate.js';
import { notFound } from '../../lib/errors.js';
import { getSetting, getAllSettings, setSetting, SETTING_KEYS } from '../../lib/settings.js';
import { audit } from '../../lib/notify.js';

const router = Router();

const pagePrice = z.object({ BW: z.number().int().min(1), COLOR: z.number().int().min(1) });
const SCHEMAS = {
  store_profile: z.object({
    name: z.string().trim().min(2).max(80),
    tagline: z.string().trim().max(120).default(''),
    address: z.string().trim().max(255).default(''),
    phone: z.string().trim().max(40).default(''),
    email: z.string().trim().max(120).default(''),
    npwp: z.string().trim().max(30).default(''),
    openingHours: z.string().trim().max(120).default(''),
    bankAccounts: z
      .array(
        z.object({
          bank: z.string().trim().min(2).max(40),
          number: z.string().trim().min(3).max(40),
          holder: z.string().trim().min(2).max(80),
        }),
      )
      .max(5)
      .default([]),
  }),
  print_pricing: z.object({
    pricePerPage: z.object({ A4: pagePrice, F4: pagePrice, A3: pagePrice }),
    binding: z.object({ LAKBAN: z.number().int().min(0), SPIRAL: z.number().int().min(0) }).transform((b) => ({ NONE: 0, ...b })),
  }),
  b2b: z.object({
    taxPercent: z.number().min(0).max(100),
    invoiceNotes: z.string().trim().max(500).default(''),
  }),
};

/** Profil toko — publik (dipakai halaman login & kop dokumen). */
router.get('/store', async (_req, res) => {
  res.json({ data: await getSetting('store_profile') });
});

router.get('/', authenticate, authorize(...STAFF), async (_req, res) => {
  res.json({ data: await getAllSettings() });
});

router.put('/:key', authenticate, authorize('OWNER'), async (req, res) => {
  const { key } = req.params;
  if (!SETTING_KEYS.includes(key)) throw notFound('Pengaturan tidak dikenal');
  const value = parse(SCHEMAS[key], req.body);
  const saved = await setSetting(key, value);
  audit(req.user.id, 'SETTING_UPDATE', 'setting', null, { key, value });
  res.json({ data: saved });
});

export default router;
