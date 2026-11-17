import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { PDFDocument } from 'pdf-lib';
import AdmZip from 'adm-zip';
import { badRequest } from '../../lib/errors.js';

const execFileAsync = promisify(execFile);

const MAGIC = {
  pdf: [0x25, 0x50, 0x44, 0x46], // %PDF
  zip: [0x50, 0x4b, 0x03, 0x04], // PK.. (docx)
  ole: [0xd0, 0xcf, 0x11, 0xe0], // OLE2 (doc)
};
const startsWith = (buf, sig) => sig.every((b, i) => buf[i] === b);

export const ALLOWED_EXT = ['.pdf', '.doc', '.docx'];

/** Validasi isi berkas berdasarkan "magic bytes", bukan hanya ekstensi. */
export function detectKind(buf, ext) {
  if (ext === '.pdf' && startsWith(buf, MAGIC.pdf)) return 'pdf';
  if (ext === '.docx' && startsWith(buf, MAGIC.zip)) {
    try {
      if (new AdmZip(buf).getEntry('word/document.xml')) return 'docx';
    } catch {
      /* zip rusak */
    }
  }
  if (ext === '.doc' && startsWith(buf, MAGIC.ole)) return 'doc';
  throw badRequest('Isi berkas tidak sesuai format .pdf / .doc / .docx atau berkas rusak');
}

export async function pdfPageCount(buf) {
  try {
    const doc = await PDFDocument.load(buf, { ignoreEncryption: true, updateMetadata: false });
    return doc.getPageCount();
  } catch {
    throw badRequest('PDF tidak dapat dibaca (rusak atau terproteksi)');
  }
}

/** Jumlah halaman dari metadata docProps/app.xml (diisi oleh MS Word saat menyimpan). */
function docxMetadataPages(buf) {
  const entry = new AdmZip(buf).getEntry('docProps/app.xml');
  if (!entry) return null;
  const m = /<Pages>(\d+)<\/Pages>/.exec(entry.getData().toString('utf8'));
  return m ? Number(m[1]) : null;
}

/**
 * Hitung halaman dokumen.
 * - PDF  : dibaca langsung (akurat).
 * - Word : jika SOFFICE_PATH diisi → dikonversi ke PDF dengan LibreOffice (akurat & tata letak
 *          terkunci sehingga hasil cetak = yang dihitung). Tanpa LibreOffice, .docx memakai
 *          metadata (perkiraan) dan .doc ditolak.
 * @returns {{kind:string, pageCount:number, method:string, pdfPath?:string}}
 */
export async function analyzeDocument(filePath, originalName, { sofficePath } = {}) {
  const ext = path.extname(originalName).toLowerCase();
  const buf = await fs.readFile(filePath);
  const kind = detectKind(buf, ext);

  if (kind === 'pdf') return { kind, pageCount: await pdfPageCount(buf), method: 'PDF' };

  if (sofficePath) {
    const outDir = path.dirname(filePath);
    try {
      await execFileAsync(sofficePath, ['--headless', '--convert-to', 'pdf', '--outdir', outDir, filePath], {
        timeout: 120_000,
      });
      const pdfPath = path.join(outDir, `${path.parse(filePath).name}.pdf`);
      const pageCount = await pdfPageCount(await fs.readFile(pdfPath));
      return { kind, pageCount, method: `Dikonversi dari ${ext} ke PDF`, pdfPath };
    } catch (err) {
      if (err.status) throw err;
      console.error('[pagecount] konversi LibreOffice gagal:', err.message);
    }
  }

  if (kind === 'docx') {
    const pages = docxMetadataPages(buf);
    if (pages) return { kind, pageCount: pages, method: 'Metadata Word (perkiraan)' };
  }
  throw badRequest(
    'Jumlah halaman dokumen Word ini tidak dapat dihitung otomatis. Simpan sebagai PDF lalu unggah ulang.',
  );
}
