const idr = new Intl.NumberFormat('id-ID');
const dateFmt = new Intl.DateTimeFormat('id-ID', { day: '2-digit', month: 'long', year: 'numeric' });

export const rupiah = (n) => `Rp ${idr.format(Math.round(n ?? 0))}`;
export const number = (n) => idr.format(n ?? 0);
export const longDate = (d) => (d ? dateFmt.format(new Date(d)) : '-');
