import express from 'express';
import fs from 'node:fs';
import path from 'node:path';
import cors from 'cors';
import helmet from 'helmet';
import { env } from './config/env.js';
import { prisma } from './lib/prisma.js';
import { eventBusMode } from './lib/events.js';
import { errorHandler, notFoundHandler } from './middleware/error.js';
import authRoutes from './modules/auth/auth.routes.js';
import userRoutes from './modules/users/users.routes.js';
import partnerRoutes from './modules/partners/partners.routes.js';
import inventoryRoutes from './modules/inventory/inventory.routes.js';
import salesRoutes from './modules/sales/sales.routes.js';
import b2bRoutes from './modules/b2b/b2b.routes.js';
import b2bAdminRoutes from './modules/b2b/b2b.admin.routes.js';
import printingRoutes from './modules/printing/printing.routes.js';
import paymentRoutes from './modules/payments/payments.routes.js';
import reportRoutes from './modules/reports/reports.routes.js';
import settingRoutes from './modules/settings/settings.routes.js';
import notificationRoutes from './modules/notifications/notifications.routes.js';

export function createApp() {
  const app = express();
  app.set('trust proxy', 1);
  app.disable('x-powered-by');
  app.use(
    helmet({
      contentSecurityPolicy: false, // Flutter Web memakai skrip/wasm sendiri; API hanya JSON
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    }),
  );
  app.use(cors({ origin: env.corsOrigins.includes('*') ? true : env.corsOrigins }));
  app.use(express.json({ limit: '1mb' }));

  app.get('/api/health', async (_req, res) => {
    let db = true;
    try {
      await prisma.$queryRaw`SELECT 1`;
    } catch {
      db = false;
    }
    res.status(db ? 200 : 503).json({
      status: db ? 'ok' : 'degraded',
      database: db,
      realtime: eventBusMode(),
      payment: env.payment.provider,
      time: new Date(),
    });
  });

  app.use('/api/auth', authRoutes);
  app.use('/api/users', userRoutes);
  app.use('/api/partners', partnerRoutes);
  app.use('/api/inventory', inventoryRoutes);
  app.use('/api/sales', salesRoutes);
  app.use('/api/b2b', b2bRoutes);
  app.use('/api/admin/b2b', b2bAdminRoutes);
  app.use('/api/print', printingRoutes);
  app.use('/api/payments', paymentRoutes);
  app.use('/api/reports', reportRoutes);
  app.use('/api/settings', settingRoutes);
  app.use('/api/notifications', notificationRoutes);
  app.use('/api', notFoundHandler);

  // Opsional: sajikan hasil `flutter build web` dari server yang sama (1 domain, tanpa CORS).
  if (env.webDir && fs.existsSync(path.join(env.webDir, 'index.html'))) {
    const webDir = path.resolve(env.webDir);
    app.use(express.static(webDir, { index: false, maxAge: '1h' }));
    app.use((req, res, next) => {
      if (req.method !== 'GET' || req.path.startsWith('/socket.io')) return next();
      res.sendFile(path.join(webDir, 'index.html'));
    });
  }

  app.use(errorHandler);
  return app;
}
