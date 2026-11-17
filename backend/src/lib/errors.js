export class AppError extends Error {
  constructor(status, message, details) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.details = details;
  }
}

export const badRequest = (message, details) => new AppError(400, message, details);
export const unauthorized = (message = 'Silakan login terlebih dahulu') => new AppError(401, message);
export const forbidden = (message = 'Anda tidak memiliki akses ke fitur ini') => new AppError(403, message);
export const notFound = (message = 'Data tidak ditemukan') => new AppError(404, message);
export const conflict = (message, details) => new AppError(409, message, details);
