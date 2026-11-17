import { EventEmitter } from 'node:events';
import { Redis } from 'ioredis';
import { env } from '../config/env.js';

/**
 * Event bus real-time.
 * - Mode Redis: setiap event di-PUBLISH ke channel Redis; setiap instance server SUBSCRIBE
 *   lalu meneruskannya ke klien Socket.IO. Antrean real-time tetap sinkron walau backend
 *   dijalankan lebih dari satu instance (horizontal scaling).
 * - Mode memori (REDIS_URL kosong / Redis mati): EventEmitter lokal (cukup untuk 1 instance).
 *
 * Catatan desain: Pub/Sub hanya membawa NOTIFIKASI perubahan (fire-and-forget).
 * Status antrean yang sebenarnya tetap disimpan di database, jadi pesan yang terlewat
 * tidak membuat data hilang — klien cukup memuat ulang daftar dari API.
 */
const CHANNEL = 'talago:events';
const local = new EventEmitter();
local.setMaxListeners(50);

let pub = null;
let sub = null;
let mode = 'memory';

export async function initEventBus() {
  if (!env.redisUrl) {
    console.warn('[events] REDIS_URL kosong → memakai event bus in-memory');
    return mode;
  }
  try {
    const opts = { lazyConnect: true, maxRetriesPerRequest: 2, connectTimeout: 3000 };
    pub = new Redis(env.redisUrl, opts);
    sub = new Redis(env.redisUrl, opts);
    pub.on('error', (e) => console.error('[events] redis pub error:', e.message));
    sub.on('error', (e) => console.error('[events] redis sub error:', e.message));
    await Promise.all([pub.connect(), sub.connect()]);
    await sub.subscribe(CHANNEL);
    sub.on('message', (_channel, message) => {
      try {
        local.emit('event', JSON.parse(message));
      } catch (e) {
        console.error('[events] pesan tidak valid:', e.message);
      }
    });
    mode = 'redis';
    console.log(`[events] Redis Pub/Sub aktif (channel "${CHANNEL}")`);
  } catch (err) {
    console.warn(`[events] Redis tidak tersedia (${err.message}) → fallback in-memory`);
    pub?.disconnect();
    sub?.disconnect();
    pub = sub = null;
  }
  return mode;
}

export const eventBusMode = () => mode;

/**
 * Kirim event ke room Socket.IO.
 * rooms: 'staff' | 'public' | `user:<id>`
 */
export function publish(event, payload, rooms) {
  const message = { event, payload, rooms, at: new Date().toISOString() };
  if (pub && pub.status === 'ready') {
    pub.publish(CHANNEL, JSON.stringify(message)).catch((e) => {
      console.error('[events] publish gagal, kirim lokal:', e.message);
      local.emit('event', message);
    });
  } else {
    local.emit('event', message);
  }
}

/** Kunci terdistribusi sederhana (Redis SET NX PX). Tanpa Redis selalu berhasil (1 instance). */
export async function acquireLock(key, ttlMs) {
  if (!pub || pub.status !== 'ready') return true;
  try {
    return (await pub.set(`talago:${key}`, process.pid.toString(), 'PX', ttlMs, 'NX')) === 'OK';
  } catch {
    return true;
  }
}

export function onEvent(handler) {
  local.on('event', handler);
}

export async function closeEventBus() {
  await Promise.allSettled([pub?.quit(), sub?.quit()]);
}
