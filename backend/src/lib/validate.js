import { z } from 'zod';
import { badRequest } from './errors.js';

z.config(z.locales.id());

/** Validasi data dengan skema Zod; lempar 400 berisi daftar field yang salah. */
export function parse(schema, data) {
  const result = schema.safeParse(data ?? {});
  if (!result.success) {
    throw badRequest(
      'Data yang dikirim tidak valid',
      result.error.issues.map((i) => ({ field: i.path.join('.'), message: i.message })),
    );
  }
  return result.data;
}

export const idParam = z.coerce.number().int().positive();
export const parseId = (value) => parse(idParam, value);

export const pageSchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

export const paginate = ({ page, limit }) => ({ skip: (page - 1) * limit, take: limit });

export const pageMeta = (total, { page, limit }) => ({
  page,
  limit,
  total,
  totalPages: Math.max(1, Math.ceil(total / limit)),
});

/** Query tanggal opsional (YYYY-MM-DD) → Date lokal pukul 00:00. */
export const dateQuery = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Format tanggal YYYY-MM-DD')
  .transform((s) => {
    const [y, m, d] = s.split('-').map(Number);
    return new Date(y, m - 1, d);
  });

/** Field teks opsional: string kosong dianggap null. */
export const optionalText = (max) =>
  z
    .string()
    .trim()
    .max(max)
    .nullish()
    .transform((v) => (v ? v : null));

export { z };
