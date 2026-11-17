const pad = (n, len = 2) => String(n).padStart(len, '0');

/** Tanggal lokal sebagai YYYYMMDD (atau dengan pemisah). */
export function ymd(date = new Date(), sep = '') {
  return [date.getFullYear(), pad(date.getMonth() + 1), pad(date.getDate())].join(sep);
}

export function startOfDay(date = new Date()) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  return d;
}

export function addDays(date, days) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d;
}

/** Selisih hari kalender (b - a). */
export function daysBetween(a, b) {
  return Math.round((startOfDay(b) - startOfDay(a)) / 86_400_000);
}
