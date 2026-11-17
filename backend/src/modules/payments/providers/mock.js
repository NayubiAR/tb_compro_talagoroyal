/**
 * Provider simulasi untuk development, demo, dan UAT tanpa akun payment gateway.
 * QR yang dihasilkan hanya teks contoh; pembayaran diselesaikan lewat tombol
 * "Simulasikan Pembayaran" (POST /api/payments/mock/:orderId/pay) yang melewati
 * jalur pemrosesan yang SAMA dengan webhook Midtrans.
 */
export function createMockProvider() {
  return {
    name: 'MOCK',
    async createQris({ orderId, amount }) {
      return {
        qrString: `00020101021226590013ID.TALAGO.MOCK0118${orderId}5204581253033605404${amount}5802ID5912TALAGO ROYAL6304MOCK`,
        qrUrl: null,
        raw: { simulated: true },
      };
    },
    async fetchStatus() {
      return null;
    },
    async expire() {},
    verifyNotification() {
      return true;
    },
  };
}
