import { env } from '../../../config/env.js';
import { createMidtransProvider } from './midtrans.js';
import { createMockProvider } from './mock.js';

/** Abstraksi payment gateway: ganti Midtrans ↔ Xendit cukup dengan menambah provider baru. */
export const paymentProvider =
  env.payment.provider === 'midtrans'
    ? createMidtransProvider({
        serverKey: env.payment.midtransServerKey,
        isProduction: env.payment.midtransIsProduction,
      })
    : createMockProvider();
