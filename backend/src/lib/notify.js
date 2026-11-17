import { prisma } from './prisma.js';
import { publish } from './events.js';

/** Simpan notifikasi in-app untuk satu pengguna dan dorong secara real-time. */
export async function notifyUser(userId, { type, title, body, link = null }) {
  try {
    const n = await prisma.notification.create({ data: { userId, type, title, body, link } });
    publish('notification', n, [`user:${userId}`]);
    return n;
  } catch (err) {
    console.error('[notify] gagal:', err.message);
    return null;
  }
}

/** Notifikasi untuk seluruh staf aktif (admin & owner). */
export async function notifyStaff({ type, title, body, link = null }) {
  try {
    const staff = await prisma.user.findMany({
      where: { role: { in: ['ADMIN', 'OWNER'] }, isActive: true },
      select: { id: true },
    });
    if (!staff.length) return;
    await prisma.notification.createMany({
      data: staff.map((s) => ({ userId: s.id, type, title, body, link })),
    });
    for (const s of staff) {
      publish('notification', { type, title, body, link, createdAt: new Date() }, [`user:${s.id}`]);
    }
  } catch (err) {
    console.error('[notify] staff gagal:', err.message);
  }
}

/** Jejak audit aksi penting (verifikasi mitra, approve PO, pembayaran, ubah harga, dll). */
export async function audit(userId, action, entity, entityId = null, detail = null) {
  try {
    await prisma.auditLog.create({ data: { userId, action, entity, entityId, detail } });
  } catch (err) {
    console.error('[audit] gagal:', err.message);
  }
}
