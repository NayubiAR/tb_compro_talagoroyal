import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/labels.dart';
import '../../state/auth_state.dart';
import '../../widgets/common.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final auth = context.read<AuthState>();
  late final name = TextEditingController(text: auth.user?['name']);
  late final phone = TextEditingController(text: auth.user?['phone'] ?? '');
  final current = TextEditingController();
  final next = TextEditingController();

  Future<void> _saveProfile() async {
    final res = await guard(
      context,
      () => context.api.patch('/api/auth/me', {'name': name.text.trim(), 'phone': phone.text.trim().isEmpty ? null : phone.text.trim()}),
      success: 'Profil diperbarui',
    );
    if (res != null) auth.updateUser(res['data'] as Json);
  }

  Future<void> _changePassword() async {
    if (next.text.length < 8) {
      showSnack(context, 'Password baru minimal 8 karakter', error: true);
      return;
    }
    final res = await guard(
      context,
      () => context.api.post('/api/auth/change-password', {'currentPassword': current.text, 'newPassword': next.text}),
      success: 'Password berhasil diganti',
    );
    if (res != null) {
      current.clear();
      next.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().user ?? {};
    final partner = user['partner'] as Json?;
    return PageBody(maxWidth: 720, children: [
      PageHeader(title: 'Profil & Keamanan', subtitle: '${user['email']} · ${roleLabel[user['role']]}'),
      SectionCard(
        title: 'Data diri',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama')),
          const SizedBox(height: 12),
          TextField(controller: phone, decoration: const InputDecoration(labelText: 'No. HP')),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _saveProfile, child: const Text('Simpan'))),
        ]),
      ),
      if (partner != null) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Institusi',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InfoRow('Nama', partner['institutionName'] ?? '-'),
            InfoRow('Jenis', institutionTypeLabel[partner['institutionType']] ?? '-'),
            InfoRow('Alamat', partner['address'] ?? '-'),
            InfoRow('NPWP', partner['npwp'] ?? '-'),
            InfoRow('Status', statusOf(partnerStatus, partner['status']).label),
            InfoRow('Level', partner['level'] == null ? '-' : '${partner['level']} (${partner['discountPercent']}%)'),
            InfoRow('Termin', '${partner['paymentTermDays']} hari'),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      SectionCard(
        title: 'Ganti password',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Password saat ini')),
          const SizedBox(height: 12),
          TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'Password baru (min. 8 karakter)')),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _changePassword, child: const Text('Ganti password'))),
        ]),
      ),
    ]);
  }
}
