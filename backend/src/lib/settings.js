import { prisma } from './prisma.js';

export const SETTING_DEFAULTS = {
  store_profile: {
    name: 'Talago Royal',
    tagline: 'Toko Alat Tulis Kantor & Jasa Cetak',
    address: 'Jl. Contoh No. 1, Kota',
    phone: '0812-0000-0000',
    email: 'info@talagoroyal.test',
    npwp: '',
    openingHours: 'Senin–Sabtu 08.00–20.00',
    bankAccounts: [{ bank: 'BRI', number: '0000-01-000000-50-0', holder: 'Talago Royal' }],
  },
  print_pricing: {
    pricePerPage: {
      A4: { BW: 500, COLOR: 1500 },
      F4: { BW: 600, COLOR: 1750 },
      A3: { BW: 1500, COLOR: 4000 },
    },
    binding: { NONE: 0, LAKBAN: 3000, SPIRAL: 8000 },
  },
  b2b: {
    taxPercent: 11,
    invoiceNotes: 'Pembayaran melalui transfer bank. Cantumkan nomor faktur pada berita transfer.',
  },
};

export const SETTING_KEYS = Object.keys(SETTING_DEFAULTS);

export async function getSetting(key) {
  const row = await prisma.setting.findUnique({ where: { key } });
  const defaults = structuredClone(SETTING_DEFAULTS[key]);
  return row ? { ...defaults, ...row.value } : defaults;
}

export async function getAllSettings() {
  const entries = await Promise.all(SETTING_KEYS.map(async (k) => [k, await getSetting(k)]));
  return Object.fromEntries(entries);
}

export async function setSetting(key, value) {
  await prisma.setting.upsert({ where: { key }, create: { key, value }, update: { value } });
  return getSetting(key);
}
