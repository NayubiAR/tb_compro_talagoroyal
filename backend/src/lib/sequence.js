import { ymd } from './dates.js';

/**
 * Nomor urut atomik per kunci (mis. "PO-2611"). UPDATE value = value + 1 mengunci baris
 * sampai transaksi selesai sehingga dua request bersamaan tidak mendapat nomor sama.
 */
export async function nextSequence(tx, key) {
  for (let attempt = 0; ; attempt++) {
    try {
      const row = await tx.counter.upsert({
        where: { key },
        create: { key, value: 1 },
        update: { value: { increment: 1 } },
      });
      return row.value;
    } catch (err) {
      // Dua request membuat kunci baru bersamaan → salah satu kena unique violation, ulangi.
      if (err?.code !== 'P2002' || attempt >= 2) throw err;
    }
  }
}

/** Kode dokumen, mis. PO-2611-0001 (bulanan) atau POS-261118-0001 (harian). */
export async function nextCode(tx, prefix, { period = 'month', pad = 4 } = {}) {
  const stamp = period === 'day' ? ymd().slice(2) : ymd().slice(2, 6);
  const seq = await nextSequence(tx, `${prefix}-${stamp}`);
  return `${prefix}-${stamp}-${String(seq).padStart(pad, '0')}`;
}
