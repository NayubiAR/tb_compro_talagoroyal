import { Server } from 'socket.io';
import { env } from '../config/env.js';
import { onEvent } from './events.js';
import { verifyToken, STAFF } from '../middleware/auth.js';

/**
 * Gateway WebSocket (Socket.IO). Browser (Flutter Web) tidak bisa terhubung langsung ke Redis,
 * jadi server meneruskan event dari Redis Pub/Sub ke room berikut:
 *   - public         : layar monitor antrean di toko (tanpa login)
 *   - staff          : admin/owner (antrean kasir, alert stok, pesanan B2B baru)
 *   - user:<id>      : status pesanan cetak & notifikasi milik pengguna tsb.
 */
export function initSocket(httpServer) {
  const io = new Server(httpServer, {
    cors: { origin: env.corsOrigins.includes('*') ? true : env.corsOrigins },
  });

  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token) {
      socket.data.user = null;
      return next();
    }
    try {
      const payload = verifyToken(token);
      socket.data.user = { id: Number(payload.sub), role: payload.role };
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    socket.join('public');
    const user = socket.data.user;
    if (user) {
      socket.join(`user:${user.id}`);
      if (STAFF.includes(user.role)) socket.join('staff');
    }
  });

  onEvent(({ event, payload, rooms }) => {
    for (const room of rooms ?? []) io.to(room).emit(event, payload);
  });

  return io;
}
