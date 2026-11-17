import crypto from 'node:crypto';
import { AppError } from '../../../lib/errors.js';

/** Signature notifikasi Midtrans: SHA512(order_id + status_code + gross_amount + ServerKey). */
export function midtransSignature(orderId, statusCode, grossAmount, serverKey) {
  return crypto.createHash('sha512').update(`${orderId}${statusCode}${grossAmount}${serverKey}`).digest('hex');
}

export function mapMidtransStatus(transactionStatus) {
  switch (transactionStatus) {
    case 'settlement':
    case 'capture':
      return 'PAID';
    case 'expire':
      return 'EXPIRED';
    case 'cancel':
    case 'deny':
    case 'failure':
      return 'FAILED';
    default:
      return 'PENDING';
  }
}

export function createMidtransProvider({ serverKey, isProduction }) {
  const baseUrl = isProduction ? 'https://api.midtrans.com' : 'https://api.sandbox.midtrans.com';
  const headers = {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    Authorization: `Basic ${Buffer.from(`${serverKey}:`).toString('base64')}`,
  };

  async function call(method, urlPath, body) {
    const res = await fetch(`${baseUrl}${urlPath}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(15_000),
    });
    return res.json();
  }

  return {
    name: 'MIDTRANS',

    /** Core API charge QRIS → mengembalikan qr_string (dirender jadi QR) & URL gambar QR. */
    async createQris({ orderId, amount, expiryMinutes, customer, itemName }) {
      const data = await call('POST', '/v2/charge', {
        payment_type: 'qris',
        transaction_details: { order_id: orderId, gross_amount: amount },
        item_details: [{ id: 'PRINT', price: amount, quantity: 1, name: itemName.slice(0, 50) }],
        customer_details: { first_name: customer.name, email: customer.email, phone: customer.phone ?? undefined },
        qris: { acquirer: 'gopay' },
        custom_expiry: { expiry_duration: expiryMinutes, unit: 'minute' },
      });
      if (!['200', '201'].includes(String(data.status_code))) {
        throw new AppError(502, `Gagal membuat QRIS: ${data.status_message ?? 'gateway error'}`);
      }
      const qrAction = data.actions?.find((a) => a.name === 'generate-qr-code');
      return { qrString: data.qr_string ?? null, qrUrl: qrAction?.url ?? null, raw: data };
    },

    /** Cek status langsung ke gateway (cadangan bila webhook tidak sampai, mis. saat development). */
    async fetchStatus(orderId) {
      const data = await call('GET', `/v2/${encodeURIComponent(orderId)}/status`);
      if (String(data.status_code) === '404') return null;
      return { status: mapMidtransStatus(data.transaction_status), raw: data };
    },

    async expire(orderId) {
      try {
        await call('POST', `/v2/${encodeURIComponent(orderId)}/expire`);
      } catch (err) {
        console.warn('[midtrans] expire gagal:', err.message);
      }
    },

    verifyNotification(n) {
      if (typeof n?.signature_key !== 'string') return false;
      const expected = midtransSignature(n.order_id, n.status_code, n.gross_amount, serverKey);
      const a = Buffer.from(expected);
      const b = Buffer.from(n.signature_key);
      return a.length === b.length && crypto.timingSafeEqual(a, b);
    },
  };
}
