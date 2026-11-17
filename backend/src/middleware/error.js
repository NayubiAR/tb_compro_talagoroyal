import multer from 'multer';
import { AppError } from '../lib/errors.js';
import { env } from '../config/env.js';

export function notFoundHandler(req, res) {
  res.status(404).json({ error: { message: `Endpoint ${req.method} ${req.path} tidak ditemukan` } });
}

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, req, res, _next) {
  if (err instanceof AppError) {
    return res.status(err.status).json({ error: { message: err.message, details: err.details } });
  }
  if (err instanceof multer.MulterError) {
    const message =
      err.code === 'LIMIT_FILE_SIZE'
        ? `Ukuran berkas maksimal ${env.maxUploadMb} MB`
        : `Unggahan gagal: ${err.message}`;
    return res.status(400).json({ error: { message } });
  }
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({ error: { message: 'Format JSON tidak valid' } });
  }
  if (err?.code === 'P2002') {
    const target = [].concat(err.meta?.target ?? []).join(', ');
    return res.status(409).json({ error: { message: `Data sudah ada (duplikat${target ? `: ${target}` : ''})` } });
  }
  if (err?.code === 'P2025') {
    return res.status(404).json({ error: { message: 'Data tidak ditemukan' } });
  }
  console.error(`[error] ${req.method} ${req.originalUrl}`, err);
  res.status(500).json({ error: { message: 'Terjadi kesalahan pada server' } });
}
