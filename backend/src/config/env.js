import path from 'node:path';

function num(name, fallback) {
  const raw = process.env[name];
  const value = raw === undefined || raw === '' ? fallback : Number(raw);
  if (Number.isNaN(value)) throw new Error(`Env ${name} harus berupa angka`);
  return value;
}

const nodeEnv = process.env.NODE_ENV || 'development';
const jwtSecret = process.env.JWT_SECRET;
if (!jwtSecret) throw new Error('JWT_SECRET wajib diisi (lihat .env.example)');
if (nodeEnv === 'production' && jwtSecret.length < 32) {
  throw new Error('JWT_SECRET minimal 32 karakter untuk production');
}

const port = num('PORT', 4000);
const provider = (process.env.PAYMENT_PROVIDER || 'mock').toLowerCase();
if (!['mock', 'midtrans'].includes(provider)) throw new Error('PAYMENT_PROVIDER harus mock atau midtrans');
if (provider === 'midtrans' && !process.env.MIDTRANS_SERVER_KEY) {
  throw new Error('MIDTRANS_SERVER_KEY wajib diisi jika PAYMENT_PROVIDER=midtrans');
}
if (nodeEnv === 'production' && provider === 'mock') {
  console.warn('[env] PERINGATAN: PAYMENT_PROVIDER=mock di production — pembayaran bisa disimulasikan!');
}

export const env = Object.freeze({
  nodeEnv,
  isProd: nodeEnv === 'production',
  port,
  jwtSecret,
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || '8h',
  corsOrigins: (process.env.CORS_ORIGINS || '*').split(',').map((s) => s.trim()).filter(Boolean),
  publicBaseUrl: process.env.PUBLIC_BASE_URL || `http://localhost:${port}`,
  redisUrl: process.env.REDIS_URL || '',
  uploadDir: path.resolve(process.env.UPLOAD_DIR || 'uploads'),
  maxUploadMb: num('MAX_UPLOAD_MB', 25),
  fileRetentionDays: num('FILE_RETENTION_DAYS', 7),
  sofficePath: process.env.SOFFICE_PATH || '',
  webDir: process.env.WEB_DIR || '',
  payment: Object.freeze({
    provider,
    expiryMinutes: num('PAYMENT_EXPIRY_MINUTES', 15),
    midtransServerKey: process.env.MIDTRANS_SERVER_KEY || '',
    midtransIsProduction: process.env.MIDTRANS_IS_PRODUCTION === 'true',
  }),
});
