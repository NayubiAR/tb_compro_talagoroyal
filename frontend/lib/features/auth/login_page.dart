import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/common.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String _storeName = 'Talago Royal';

  static const _demo = [
    ('Pemilik', 'owner@talago.test'),
    ('Admin/Kasir', 'admin@talago.test'),
    ('Mitra B2B', 'mitra@talago.test'),
    ('Pelanggan', 'pelanggan@talago.test'),
  ];

  @override
  void initState() {
    super.initState();
    context.api.get('/api/settings/store').then((res) {
      if (mounted) setState(() => _storeName = res['data']['name'] ?? _storeName);
    }).catchError((_) {});
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    await guard(context, () => context.auth.login(_email.text.trim(), _password.text));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final form = _buildForm(context);
    return Scaffold(
      body: wide
          ? Row(children: [
              Expanded(child: _BrandPanel(storeName: _storeName)),
              Expanded(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: form))),
            ])
          : Center(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: form)),
    );
  }

  Widget _buildForm(BuildContext context) {
    final expired = context.auth.sessionExpired;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Masuk', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Masuk ke $_storeName untuk melanjutkan.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (expired) ...[
              const SizedBox(height: 16),
              Card(
                color: toneColor(context, Tone.warning).withValues(alpha: 0.12),
                child: const Padding(padding: EdgeInsets.all(12), child: Text('Sesi Anda berakhir. Silakan masuk kembali.')),
              ),
            ],
            const SizedBox(height: 24),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
              validator: (v) => (v ?? '').contains('@') ? null : 'Masukkan email yang valid',
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v ?? '').isEmpty ? 'Password wajib diisi' : null,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Masuk'),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: () => context.go('/register'), child: const Text('Belum punya akun? Daftar sekarang')),
            const Divider(height: 32),
            OutlinedButton.icon(
              onPressed: () => context.go('/antrean'),
              icon: const Icon(Icons.tv),
              label: const Text('Lihat layar antrean cetak'),
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Akun demo (UAT)', style: TextStyle(fontSize: 14)),
              subtitle: const Text('Password semua akun: password123', style: TextStyle(fontSize: 12)),
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (label, email) in _demo)
                    ActionChip(
                      label: Text(label),
                      onPressed: () {
                        _email.text = email;
                        _password.text = 'password123';
                      },
                    ),
                ]),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.storeName});
  final String storeName;

  @override
  Widget build(BuildContext context) {
    const features = [
      (Icons.inventory_2_outlined, 'Inventaris Cerdas', 'Konversi Dus → Pak → Pcs otomatis & Smart Restock Alert'),
      (Icons.business_center_outlined, 'Portal B2B', 'Harga bertingkat, Quick PO massal & faktur PDF otomatis'),
      (Icons.print_outlined, 'Cloud Printing', 'Unggah dari rumah, bayar QRIS, pantau antrean real-time'),
    ];
    return Container(
      color: Brand.navy,
      padding: const EdgeInsets.all(48),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: Brand.gold, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.edit_note, color: Brand.navy, size: 34),
        ),
        const SizedBox(height: 24),
        Text(storeName, style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('Sistem Informasi Terintegrasi Toko ATK', style: TextStyle(color: Color(0xFFD7DBEA), fontSize: 16)),
        const SizedBox(height: 40),
        for (final (icon, title, desc) in features)
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: Brand.gold),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(desc, style: const TextStyle(color: Color(0xFFC2C8DD))),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}
