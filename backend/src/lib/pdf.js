import PDFDocument from 'pdfkit';
import { rupiah, number, longDate } from './format.js';

const COLORS = { primary: '#1F2A5A', accent: '#C9A227', muted: '#6B7280', line: '#D1D5DB' };

/**
 * Render dokumen Purchase Order atau Faktur (invoice) ke stream (mis. response Express).
 * @param {import('node:stream').Writable} out
 * @param {{kind:'PO'|'INVOICE', order:any, invoice?:any, store:any, b2b:any}} data
 */
export function renderOrderPdf(out, { kind, order, invoice, store, b2b }) {
  const doc = new PDFDocument({ size: 'A4', margin: 40, info: { Title: `${kind} ${order.poNumber}` } });
  doc.pipe(out);

  const left = 40;
  const right = doc.page.width - 40;
  const width = right - left;

  // ── Kop toko ──
  doc.fillColor(COLORS.primary).font('Helvetica-Bold').fontSize(18).text(store.name, left, 40);
  doc.font('Helvetica').fontSize(9).fillColor(COLORS.muted);
  doc.text(store.tagline ?? '');
  doc.text(store.address ?? '');
  doc.text(`Telp: ${store.phone ?? '-'}  ·  Email: ${store.email ?? '-'}`);
  if (store.npwp) doc.text(`NPWP: ${store.npwp}`);

  const title = kind === 'INVOICE' ? 'FAKTUR' : 'PURCHASE ORDER';
  doc.fillColor(COLORS.primary).font('Helvetica-Bold').fontSize(16).text(title, left, 40, { width, align: 'right' });
  doc.font('Helvetica').fontSize(9).fillColor('#111827');
  const meta =
    kind === 'INVOICE'
      ? [
          ['No. Faktur', invoice.invoiceNumber],
          ['Tanggal', longDate(invoice.issueDate)],
          ['Jatuh Tempo', longDate(invoice.dueDate)],
          ['No. PO', order.poNumber],
        ]
      : [
          ['No. PO', order.poNumber],
          ['Tanggal', longDate(order.createdAt)],
          ['Status', order.status],
        ];
  if (order.partnerRef) meta.push(['Ref. Instansi', order.partnerRef]);
  let y = 62;
  for (const [k, v] of meta) {
    doc.text(`${k}: ${v}`, left, y, { width, align: 'right' });
    y += 12;
  }

  y = Math.max(doc.y, 120) + 10;
  doc.moveTo(left, y).lineTo(right, y).strokeColor(COLORS.accent).lineWidth(2).stroke();
  y += 12;

  // ── Pihak mitra ──
  const partner = order.partner;
  doc.fillColor(COLORS.muted).fontSize(8).text(kind === 'INVOICE' ? 'DITAGIHKAN KEPADA' : 'PEMESAN', left, y);
  doc.fillColor('#111827').font('Helvetica-Bold').fontSize(11).text(partner.institutionName, left, y + 11);
  doc.font('Helvetica').fontSize(9);
  doc.text(partner.address ?? '', { width: width / 2 });
  if (partner.npwp) doc.text(`NPWP: ${partner.npwp}`);
  const u = partner.user;
  if (u) doc.text(`PIC: ${u.name}${u.phone ? ` · ${u.phone}` : ''} · ${u.email}`);
  y = doc.y + 14;

  // ── Tabel item ──
  const cols = [
    { key: 'no', label: 'No', w: 24, align: 'center' },
    { key: 'sku', label: 'Kode', w: 70 },
    { key: 'name', label: 'Nama Barang', w: 175 },
    { key: 'qty', label: 'Qty', w: 70, align: 'right' },
    { key: 'price', label: 'Harga Satuan', w: 88, align: 'right' },
    { key: 'subtotal', label: 'Subtotal', w: width - 24 - 70 - 175 - 70 - 88, align: 'right' },
  ];
  const drawHeader = () => {
    doc.rect(left, y, width, 18).fill(COLORS.primary);
    let x = left;
    doc.fillColor('#FFFFFF').font('Helvetica-Bold').fontSize(8.5);
    for (const c of cols) {
      doc.text(c.label, x + 4, y + 5, { width: c.w - 8, align: c.align ?? 'left' });
      x += c.w;
    }
    y += 18;
    doc.font('Helvetica').fillColor('#111827');
  };
  drawHeader();

  order.items.forEach((item, idx) => {
    const row = {
      no: String(idx + 1),
      sku: item.sku,
      name: item.productName,
      qty: `${number(item.unitQty)} ${item.unitName}`,
      price: rupiah(item.tierUnitPrice * item.conversion),
      subtotal: rupiah(item.subtotal),
    };
    const h = Math.max(16, doc.heightOfString(row.name, { width: cols[2].w - 8 }) + 6);
    if (y + h > doc.page.height - 170) {
      doc.addPage();
      y = 40;
      drawHeader();
    }
    if (idx % 2 === 1) doc.rect(left, y, width, h).fill('#F3F4F6').fillColor('#111827');
    let x = left;
    doc.fontSize(8.5);
    for (const c of cols) {
      doc.text(row[c.key], x + 4, y + 4, { width: c.w - 8, align: c.align ?? 'left' });
      x += c.w;
    }
    y += h;
  });
  doc.moveTo(left, y).lineTo(right, y).strokeColor(COLORS.line).lineWidth(1).stroke();
  y += 8;

  // ── Total ──
  const totals = [['Subtotal', rupiah(order.subtotal)]];
  if (order.discount > 0) {
    totals.push([`Diskon level ${order.levelName ?? ''} (${order.levelDiscountPercent}%)`, `- ${rupiah(order.discount)}`]);
  }
  if (order.tax > 0) totals.push([`PPN (${order.taxPercent}%)`, rupiah(order.tax)]);
  totals.push(['TOTAL', rupiah(order.total)]);
  if (kind === 'INVOICE') {
    totals.push(['Sudah dibayar', rupiah(invoice.amountPaid)]);
    totals.push(['Sisa tagihan', rupiah(invoice.total - invoice.amountPaid)]);
  }
  for (const [label, value] of totals) {
    const bold = label === 'TOTAL' || label === 'Sisa tagihan';
    doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(bold ? 10 : 9);
    doc.text(label, right - 260, y, { width: 150, align: 'right' });
    doc.text(value, right - 105, y, { width: 105, align: 'right' });
    y += bold ? 15 : 13;
  }

  // ── Stempel status faktur ──
  if (kind === 'INVOICE') {
    const overdue = invoice.status !== 'PAID' && invoice.status !== 'VOID' && new Date(invoice.dueDate) < new Date();
    const stamp =
      invoice.status === 'PAID'
        ? ['LUNAS', '#15803D']
        : invoice.status === 'VOID'
          ? ['DIBATALKAN', '#6B7280']
          : overdue
            ? ['JATUH TEMPO', '#B91C1C']
            : ['BELUM LUNAS', '#B45309'];
    doc.save();
    doc.rotate(-12, { origin: [left + 90, y - 30] });
    doc.roundedRect(left + 10, y - 50, 170, 36, 6).lineWidth(2.5).strokeColor(stamp[1]).stroke();
    doc.fillColor(stamp[1]).font('Helvetica-Bold').fontSize(18).text(stamp[0], left + 10, y - 41, { width: 170, align: 'center' });
    doc.restore();
  }

  // ── Catatan & pembayaran ──
  y += 12;
  doc.fillColor('#111827').font('Helvetica-Bold').fontSize(9);
  if (order.note) {
    doc.text('Catatan pemesan:', left, y);
    doc.font('Helvetica').text(order.note, { width });
    y = doc.y + 8;
  }
  if (kind === 'INVOICE') {
    doc.font('Helvetica-Bold').text('Informasi pembayaran:', left, y);
    doc.font('Helvetica');
    for (const b of store.bankAccounts ?? []) doc.text(`${b.bank} ${b.number} a.n. ${b.holder}`);
    if (b2b?.invoiceNotes) doc.text(b2b.invoiceNotes, { width });
  }

  doc.page.margins.bottom = 0; // footer di bawah margin tanpa memicu halaman baru
  doc
    .fontSize(7.5)
    .fillColor(COLORS.muted)
    .text(
      `Dokumen ini dibuat otomatis oleh Sistem Informasi Talago Royal pada ${new Date().toLocaleString('id-ID')}.`,
      left,
      doc.page.height - 50,
      { width, align: 'center' },
    );

  doc.end();
}
