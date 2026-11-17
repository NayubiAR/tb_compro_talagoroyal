import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';
import { prisma } from '../lib/prisma.js';
import { forbidden, unauthorized } from '../lib/errors.js';

export const STAFF = ['ADMIN', 'OWNER'];

export function signToken(user) {
  return jwt.sign({ sub: String(user.id), role: user.role }, env.jwtSecret, {
    expiresIn: env.jwtExpiresIn,
  });
}

export function verifyToken(token) {
  const payload = jwt.verify(token, env.jwtSecret);
  if (payload.typ === 'dl') throw new Error('Token unduhan tidak bisa dipakai sebagai sesi');
  return payload;
}

/**
 * Token unduhan berumur pendek (2 menit) yang terikat ke satu path.
 * Dipakai untuk membuka PDF faktur / berkas cetak lewat tautan biasa di browser
 * (tautan tidak bisa membawa header Authorization).
 */
export function signDownloadToken(userId, path) {
  return jwt.sign({ sub: String(userId), typ: 'dl', path }, env.jwtSecret, { expiresIn: '2m' });
}

async function loadUser(id) {
  const user = await prisma.user.findUnique({
    where: { id },
    include: { partner: { include: { level: true } } },
  });
  if (!user || !user.isActive) throw unauthorized('Akun tidak aktif atau tidak ditemukan');
  return user;
}

export async function authenticate(req, _res, next) {
  const header = req.headers.authorization || '';
  let payload;
  if (header.startsWith('Bearer ')) {
    try {
      payload = verifyToken(header.slice(7));
    } catch {
      throw unauthorized('Sesi berakhir, silakan login ulang');
    }
  } else if (req.method === 'GET' && typeof req.query?.dl === 'string') {
    try {
      payload = jwt.verify(req.query.dl, env.jwtSecret);
    } catch {
      throw unauthorized('Tautan unduhan sudah kedaluwarsa, silakan ulangi');
    }
    const path = req.originalUrl.split('?')[0];
    if (payload.typ !== 'dl' || payload.path !== path) throw unauthorized('Tautan unduhan tidak valid');
  } else {
    throw unauthorized();
  }
  req.user = await loadUser(Number(payload.sub));
  next();
}

export const authorize =
  (...roles) =>
  (req, _res, next) => {
    if (!req.user || !roles.includes(req.user.role)) throw forbidden();
    next();
  };

/** Mitra B2B (status apa pun) — untuk melihat riwayat pesanan & faktur. */
export function requirePartner(req, _res, next) {
  if (req.user?.role !== 'B2B' || !req.user.partner) throw forbidden('Fitur ini khusus mitra B2B');
  req.partner = req.user.partner;
  next();
}

/** Mitra B2B terverifikasi — syarat akses katalog harga khusus & membuat PO. */
export function requireVerifiedPartner(req, res, next) {
  requirePartner(req, res, () => {});
  const { status } = req.partner;
  if (status !== 'VERIFIED') {
    throw forbidden(
      status === 'PENDING'
        ? 'Akun mitra Anda masih menunggu verifikasi oleh toko'
        : 'Akun mitra Anda tidak aktif. Hubungi Talago Royal.',
    );
  }
  next();
}

export function publicUser(u) {
  const p = u.partner;
  return {
    id: u.id,
    name: u.name,
    email: u.email,
    phone: u.phone,
    role: u.role,
    isActive: u.isActive,
    createdAt: u.createdAt,
    partner: p
      ? {
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
          rejectionReason: p.rejectionReason,
          verifiedAt: p.verifiedAt,
        }
      : null,
  };
}
