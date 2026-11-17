import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/labels.dart';
import '../../widgets/common.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _form = GlobalKey<FormState>();
  bool _partner = false;
  bool _busy = false;
  final _c = {
    for (final k in ['name', 'email', 'phone', 'password', 'institutionName', 'npwp', 'address']) k: TextEditingController(),
  };
  String _type = 'SEKOLAH';

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final body = {
      'name': _c['name']!.text.trim(),
      'email': _c['email']!.text.trim(),
      if (_c['phone']!.text.trim().isNotEmpty) 'phone': _c['phone']!.text.trim(),
      'password': _c['password']!.text,
      if (_partner) ...{
        'institutionName': _c['institutionName']!.text.trim(),
        'institutionType': _type,
        'npwp': _c['npwp']!.text.trim(),
        'address': _c['address']!.text.trim(),
      },
    };
    await guard(context, () => context.auth.register(body, partner: _partner));
    if (mounted) setState(() => _busy = false);
  }

  String? _required(String? v, [int min = 2]) => (v ?? '').trim().length < min ? 'Minimal $min karakter' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _form,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Buat Akun', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, icon: Icon(Icons.person_outline), label: Text('Pelanggan Umum')),
                        ButtonSegment(value: true, icon: Icon(Icons.apartment), label: Text('Mitra Institusi')),
                      ],
                      selected: {_partner},
                      onSelectionChanged: (s) => setState(() => _partner = s.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _partner
                          ? 'Untuk sekolah, kantor & instansi. Setelah diverifikasi toko, Anda mendapat akses katalog harga grosir, Quick PO, dan faktur otomatis.'
                          : 'Untuk layanan cetak dokumen dari rumah dengan pembayaran QRIS.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    if (_partner) ...[
                      TextFormField(
                        controller: _c['institutionName'],
                        decoration: const InputDecoration(labelText: 'Nama institusi', prefixIcon: Icon(Icons.apartment)),
                        validator: (v) => _required(v, 3),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _type,
                        decoration: const InputDecoration(labelText: 'Jenis institusi'),
                        items: [
                          for (final e in institutionTypeLabel.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onChanged: (v) => setState(() => _type = v!),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _c['address'],
                        decoration: const InputDecoration(labelText: 'Alamat institusi'),
                        maxLines: 2,
                        validator: (v) => _required(v, 5),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(controller: _c['npwp'], decoration: const InputDecoration(labelText: 'NPWP (opsional)')),
                      const Divider(height: 32),
                    ],
                    TextFormField(
                      controller: _c['name'],
                      decoration: InputDecoration(labelText: _partner ? 'Nama penanggung jawab (PIC)' : 'Nama lengkap', prefixIcon: const Icon(Icons.badge_outlined)),
                      validator: _required,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _c['email'],
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                      validator: (v) => (v ?? '').contains('@') ? null : 'Email tidak valid',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _c['phone'],
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(labelText: _partner ? 'No. HP / WhatsApp' : 'No. HP (opsional)', prefixIcon: const Icon(Icons.phone_outlined)),
                      validator: (v) => _partner && (v ?? '').trim().length < 8 ? 'Nomor HP wajib untuk mitra' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _c['password'],
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password', helperText: 'Minimal 8 karakter', prefixIcon: Icon(Icons.lock_outline)),
                      validator: (v) => (v ?? '').length < 8 ? 'Minimal 8 karakter' : null,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(_partner ? 'Daftar sebagai Mitra' : 'Daftar'),
                    ),
                    TextButton(onPressed: () => context.go('/login'), child: const Text('Sudah punya akun? Masuk')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
