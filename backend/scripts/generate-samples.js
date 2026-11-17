// Membuat berkas sampel uji Cloud Printing (PDF & DOCX dengan jumlah halaman berbeda).
// Jalankan: npm run samples   → hasil di backend/samples/
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import AdmZip from 'adm-zip';

export const SAMPLE_PDFS = [
  { file: 'contoh-1-halaman.pdf', pages: 1, title: 'Surat Keterangan' },
  { file: 'contoh-5-halaman.pdf', pages: 5, title: 'Proposal Kegiatan' },
  { file: 'makalah-12-halaman.pdf', pages: 12, title: 'Makalah Kelompok' },
  { file: 'laporan-30-halaman.pdf', pages: 30, title: 'Laporan Praktikum' },
];
export const SAMPLE_DOCX = { file: 'surat-undangan-3-halaman.docx', pages: 3 };

async function makePdf({ pages, title }) {
  const doc = await PDFDocument.create();
  doc.setTitle(title);
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  for (let i = 1; i <= pages; i++) {
    const page = doc.addPage([595.28, 841.89]); // A4
    page.drawText(title, { x: 60, y: 770, size: 22, font: bold, color: rgb(0.12, 0.16, 0.35) });
    page.drawText(`Berkas uji Cloud Printing Talago Royal — halaman ${i} dari ${pages}`, {
      x: 60,
      y: 740,
      size: 11,
      font,
    });
    for (let line = 0; line < 30; line++) {
      page.drawText('Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.', {
        x: 60,
        y: 700 - line * 20,
        size: 10,
        font,
        color: rgb(0.3, 0.3, 0.3),
      });
    }
    page.drawText(String(i), { x: 290, y: 40, size: 10, font });
  }
  return Buffer.from(await doc.save());
}

function makeDocx(pages) {
  const xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const para = (text) => `<w:p><w:r><w:t xml:space="preserve">${text}</w:t></w:r></w:p>`;
  const pageBreak = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';
  const body = Array.from({ length: pages }, (_, i) =>
    [para(`Surat Undangan — Halaman ${i + 1}`), para('Dengan hormat, kami mengundang Bapak/Ibu untuk hadir.')]
      .join('')
      .concat(i < pages - 1 ? pageBreak : ''),
  ).join('');
  const zip = new AdmZip();
  zip.addFile(
    '[Content_Types].xml',
    Buffer.from(
      `${xmlHead}<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
        '</Types>',
    ),
  );
  zip.addFile(
    '_rels/.rels',
    Buffer.from(
      `${xmlHead}<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
        '</Relationships>',
    ),
  );
  zip.addFile('word/document.xml', Buffer.from(`${xmlHead}<w:document xmlns:w="${W}"><w:body>${body}</w:body></w:document>`));
  zip.addFile(
    'docProps/app.xml',
    Buffer.from(
      `${xmlHead}<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">` +
        `<Application>Talago Royal Sample</Application><Pages>${pages}</Pages></Properties>`,
    ),
  );
  return zip.toBuffer();
}

export async function generateSamples(dir) {
  await fs.mkdir(dir, { recursive: true });
  for (const s of SAMPLE_PDFS) await fs.writeFile(path.join(dir, s.file), await makePdf(s));
  await fs.writeFile(path.join(dir, SAMPLE_DOCX.file), makeDocx(SAMPLE_DOCX.pages));
  return dir;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'samples');
  await generateSamples(dir);
  console.log(`Sampel dibuat di ${dir}`);
}
