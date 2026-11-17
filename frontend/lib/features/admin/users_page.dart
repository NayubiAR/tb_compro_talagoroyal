import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/labels.dart';
import '../../widgets/common.dart';

/// Manajemen akun (khusus Pemilik Toko): buat akun staf, ubah peran, nonaktifkan, reset password.
class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> with LoaderMixin {
  List rows = [];
  Json? meta;
  String? role;
  String q = '';
  int page = 1;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> load() async {
    final res = await context.api.get('/api/users', query: {'role': role, 'q': q, 'page': page});
    rows = res['data'] as List;
    meta = res['meta'] as Json;
  }

  Future<void> _create() async {
    final ctrl = {for (final k in ['name', 'email', 'phone', 'password']) k: TextEditingController()};
    var newRole = 'ADMIN';
    final body = await showDialog<Json>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Tambah akun staf'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: ctrl['name'], decoration: const InputDecoration(labelText: 'Nama')),
              const SizedBox(height: 12),
              TextField(controller: ctrl['email'], decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(controller: ctrl['phone'], decoration: const InputDecoration(labelText: 'No. HP')),
              const SizedBox(height: 12),
              TextField(controller: ctrl['password'], obscureText: true, decoration: const InputDecoration(labelText: 'Password awal (min. 8)')),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'ADMIN', label: Text('Staf Toko')),
                  ButtonSegment(value: 'OWNER', label: Text('Pemilik')),
                ],
                selected: {newRole},
                onSelectionChanged: (s) => setLocal(() => newRole = s.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                for (final e in ctrl.entries) e.key: e.value.text.trim(),
                'role': newRole,
              }),
              child: const Text('Buat akun'),
            ),
          ],
        ),
      ),
    );
    if (body == null || !mounted) return;
    final res = await guard(context, () => context.api.post('/api/users', body), success: 'Akun dibuat');
    if (res != null) reload(silent: true);
  }

  Future<void> _patch(Json u, Json body, String success) async {
    final res = await guard(context, () => context.api.patch('/api/users/${u['id']}', body), success: success);
    if (res != null) reload(silent: true);
  }

  Future<void> _resetPassword(Json u) async {
    final pw = await promptText(context, title: 'Reset password ${u['name']}', label: 'Password baru (min. 8)', minLength: 8, confirmLabel: 'Reset');
    if (pw == null || !mounted) return;
    await guard(context, () => context.api.post('/api/users/${u['id']}/reset-password', {'password': pw}), success: 'Password direset');
  }

  @override
  Widget build(BuildContext context) {
    final me = context.auth.user?['id'];
    return loadedBody(() => PageBody(children: [
          PageHeader(
            title: 'Pengguna',
            subtitle: 'Peran menentukan hak akses (RBAC): Pemilik, Staf Toko, Mitra B2B, Pelanggan.',
            actions: [FilledButton.icon(onPressed: _create, icon: const Icon(Icons.person_add_alt), label: const Text('Tambah staf'))],
          ),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ChoiceChip(label: const Text('Semua'), selected: role == null, onSelected: (_) => _filter(null)),
            for (final e in roleLabel.entries) ChoiceChip(label: Text(e.value), selected: role == e.key, onSelected: (_) => _filter(e.key)),
            SearchBox(hint: 'Nama / email', onChanged: (v) {
              q = v;
              page = 1;
              reload();
            }),
          ]),
          const SizedBox(height: 12),
          Card(
            child: ScrollTable(
              minWidth: 900,
              columns: const [
                DataColumn(label: Text('Nama')),
                DataColumn(label: Text('Peran')),
                DataColumn(label: Text('Login terakhir')),
                DataColumn(label: Text('Aktif')),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (final u in rows)
                  DataRow(cells: [
                    DataCell(Text('${u['name']}\n${u['email']}${u['partner'] != null ? ' · ${u['partner']['institutionName']}' : ''}', style: const TextStyle(fontSize: 13))),
                    DataCell(Text(roleLabel[u['role']] ?? u['role'])),
                    DataCell(Text(fmtDateTime(u['lastLoginAt']))),
                    DataCell(Switch(
                      value: u['isActive'] == true,
                      onChanged: u['id'] == me ? null : (v) => _patch(u, {'isActive': v}, v ? 'Akun diaktifkan' : 'Akun dinonaktifkan'),
                    )),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      if ((u['role'] == 'ADMIN' || u['role'] == 'OWNER') && u['id'] != me)
                        TextButton(
                          onPressed: () => _patch(u, {'role': u['role'] == 'ADMIN' ? 'OWNER' : 'ADMIN'}, 'Peran diubah'),
                          child: Text(u['role'] == 'ADMIN' ? 'Jadikan Pemilik' : 'Jadikan Staf'),
                        ),
                      TextButton(onPressed: () => _resetPassword(u), child: const Text('Reset password')),
                    ])),
                  ]),
              ],
            ),
          ),
          Paginator(meta: meta, onPage: (p) {
            page = p;
            reload();
          }),
        ]));
  }

  void _filter(String? r) {
    role = r;
    page = 1;
    reload();
  }
}
