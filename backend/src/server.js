import './config/timezone.js';
import http from 'node:http';
import fs from 'node:fs/promises';
import { env } from './config/env.js';
import { prisma } from './lib/prisma.js';
import { initEventBus, closeEventBus } from './lib/events.js';
import { initSocket } from './lib/socket.js';
import { createApp } from './app.js';
import { startScheduler } from './jobs/scheduler.js';
import { printDir } from './modules/printing/printing.service.js';

await fs.mkdir(printDir(), { recursive: true });
await prisma.$connect();
const realtimeMode = await initEventBus();

const server = http.createServer(createApp());
const io = initSocket(server);
const stopScheduler = startScheduler();

server.listen(env.port, () => {
  console.log(`[server] Talago Royal API berjalan di http://localhost:${env.port} (${env.nodeEnv})`);
  console.log(`[server] realtime=${realtimeMode} payment=${env.payment.provider} upload=${env.uploadDir}`);
});

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[server] ${signal} diterima, menutup koneksi...`);
  stopScheduler();
  io.close();
  server.close();
  await Promise.allSettled([closeEventBus(), prisma.$disconnect()]);
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
