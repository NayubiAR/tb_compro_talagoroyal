import { prisma } from '../lib/prisma.js';
import { acquireLock } from '../lib/events.js';
import { notifyUser } from '../lib/notify.js';
import { rupiah, longDate } from '../lib/format.js';
import { addDays } from '../lib/dates.js';
import { expireStalePayments, cleanupPrintFiles } from '../modules/printing/printing.service.js';

/**
 * Pengingat faktur: sekali saat H-3 jatuh tempo, lalu setiap 7 hari selama masih menunggak.
 */
async function sendInvoiceReminders() {
  const now = new Date();
  const candidates = await prisma.invoice.findMany({
    where: { status: { in: ['UNPAID', 'PARTIAL'] }, dueDate: { lte: addDays(now, 3) } },
    include: { partner: true },
    take: 500,
  });
  let sent = 0;
  for (const inv of candidates) {
    const overdue = inv.dueDate < now;
    const last = inv.lastReminderAt;
    const due = overdue
      ? !last || last < inv.dueDate || last < addDays(now, -7)
      : !last;
    if (!due) continue;
    await notifyUser(inv.partner.userId, {
      type: 'INVOICE',
      title: overdue ? `Faktur ${inv.invoiceNumber} telah jatuh tempo` : `Faktur ${inv.invoiceNumber} segera jatuh tempo`,
      body: `Sisa tagihan ${rupiah(inv.total - inv.amountPaid)}, jatuh tempo ${longDate(inv.dueDate)}.`,
      link: '/b2b/invoices',
    });
    await prisma.invoice.update({ where: { id: inv.id }, data: { lastReminderAt: now } });
    sent++;
  }
  return sent;
}

const TASKS = [
  { name: 'expire-payments', everyMs: 60_000, run: expireStalePayments },
  { name: 'cleanup-print-files', everyMs: 60 * 60_000, run: cleanupPrintFiles },
  { name: 'invoice-reminders', everyMs: 60 * 60_000, run: sendInvoiceReminders },
];

/**
 * Penjadwal sederhana berbasis setInterval. Saat backend dijalankan >1 instance,
 * kunci Redis (SET NX) memastikan tiap tugas hanya dieksekusi oleh satu instance.
 */
export function startScheduler() {
  const timers = [];
  for (const task of TASKS) {
    const exec = async () => {
      if (!(await acquireLock(`lock:${task.name}`, task.everyMs - 1000))) return;
      try {
        const n = await task.run();
        if (n) console.log(`[scheduler] ${task.name}: ${n} item diproses`);
      } catch (err) {
        console.error(`[scheduler] ${task.name} gagal:`, err.message);
      }
    };
    timers.push(setTimeout(exec, 5_000).unref());
    timers.push(setInterval(exec, task.everyMs).unref());
  }
  return () => timers.forEach((t) => clearInterval(t));
}
