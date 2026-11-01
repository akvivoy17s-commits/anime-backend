import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../services/api_client.dart';
import '../ui/manage_ui.dart';
import '../ui/media.dart';
import '../ui/neo.dart';
import '../ui/refresh.dart';

const Color _kOnline = Color(0xFF34D399);
const int _kMinLimit = 1;
const int _kMaxLimit = 10000;
const int _kPageSize = 50;

/// Admin-only: login limit, download permission and the registered-users list.
/// All data comes from the backend (/admin/*), which checks the admin role itself.
class ControlsPage extends StatelessWidget {
  const ControlsPage({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AdminService.notifier,
        builder: (context, isAdmin, _) {
          if (!isAdmin) {
            return const NeoScaffold(
              overline: 'Access // Restricted',
              title: 'Controls',
              body: EmptyState(
                icon: Icons.lock_outline_rounded,
                text: 'Admin access only',
                sub: 'Sign in with the admin account to open Controls.',
              ),
            );
          }
          return const _ControlsBody();
        },
      );
}

class _ControlsBody extends StatefulWidget {
  const _ControlsBody();

  @override
  State<_ControlsBody> createState() => _ControlsBodyState();
}

class _ControlsBodyState extends State<_ControlsBody> {
  // settings
  bool _settingsLoading = true;
  String? _settingsError;
  int _limit = 0;
  int _activeUsers = 0;
  bool _allowDownloads = true;
  final Set<String> _dlBusy = {}; // uids whose download permission is being saved
  final Set<String> _delBusy = {}; // uids being deleted
  bool _savingLimit = false;
  bool _savingToggle = false;
  final TextEditingController _limitCtrl = TextEditingController();

  // users
  final List<Map<String, dynamic>> _users = [];
  bool _usersLoading = true;
  bool _moreLoading = false;
  String? _usersError;
  String? _nextToken;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _loadSettings();
    _loadUsers(reset: true);
  }

  @override
  void dispose() {
    _limitCtrl.dispose();
    _search.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------ settings
  void _applySettings(Map<String, dynamic> r, {bool resetField = true}) {
    final l = r['maxConcurrentUsers'];
    final a = r['activeUsers'];
    final d = r['allowDownloads'];
    if (l is num) _limit = l.toInt();
    if (a is num) _activeUsers = a.toInt();
    if (d is bool) _allowDownloads = d;
    if (resetField) _limitCtrl.text = _limit.toString();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _settingsLoading = true;
      _settingsError = null;
    });
    try {
      final r = await ApiClient.call('GET', '/admin/settings');
      if (!mounted) return;
      setState(() {
        _applySettings(r);
        _settingsLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _settingsError = e.message;
        _settingsLoading = false;
      });
    }
  }

  /// null = valid, otherwise the problem to show under the field.
  String? get _limitProblem {
    final t = _limitCtrl.text.trim();
    if (t.isEmpty) return 'Enter a number';
    final n = int.tryParse(t);
    if (n == null) return 'Whole numbers only';
    if (n < _kMinLimit || n > _kMaxLimit) return 'Use $_kMinLimit to $_kMaxLimit';
    return null;
  }

  bool get _limitChanged => int.tryParse(_limitCtrl.text.trim()) != _limit;

  Future<void> _saveLimit() async {
    if (_limitProblem != null || !_limitChanged || _savingLimit) return;
    FocusScope.of(context).unfocus();
    final n = int.parse(_limitCtrl.text.trim());
    setState(() => _savingLimit = true);
    try {
      final r = await ApiClient.call('PUT', '/admin/settings', body: {'maxConcurrentUsers': n});
      if (!mounted) return;
      setState(() => _applySettings(r));
      _toast('Limit saved: $n user(s) can be online at once.');
    } on ApiException catch (e) {
      _toast('Could not save: ${e.message}');
    } finally {
      if (mounted) setState(() => _savingLimit = false);
    }
  }

  Future<void> _setDownloads(bool value) async {
    if (_savingToggle) return;
    if (!value) {
      final ok = await neoConfirm(
        context,
        title: 'Turn off downloads?',
        message: 'Users will not be able to start new downloads and downloads in '
            'progress will be stopped. Videos already downloaded stay available offline.',
        confirmLabel: 'TURN OFF',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _savingToggle = true);
    try {
      final r = await ApiClient.call('PUT', '/admin/settings', body: {'allowDownloads': value});
      if (!mounted) return;
      setState(() => _applySettings(r, resetField: false));
      _toast(value ? 'Downloads are ON for users.' : 'Downloads are OFF for users.');
    } on ApiException catch (e) {
      _toast('Could not save: ${e.message}');
    } finally {
      if (mounted) setState(() => _savingToggle = false);
    }
  }

  // ------------------------------------------------------------------ per-user downloads
  /// allow: true = always allowed, false = blocked, null = follow the global switch.
  Future<void> _setUserDownloads(Map<String, dynamic> u, bool? allow) async {
    final uid = (u['uid'] ?? '').toString();
    if (uid.isEmpty || _dlBusy.contains(uid)) return;
    setState(() => _dlBusy.add(uid));
    try {
      await ApiClient.call('PUT', '/admin/users/$uid/downloads', body: {'allow': allow});
      if (!mounted) return;
      setState(() => u['downloadOverride'] = allow);
      _toast(allow == null
          ? 'Downloads: follows the global switch.'
          : allow
              ? 'Downloads allowed for this user.'
              : 'Downloads blocked for this user.');
    } on ApiException catch (e) {
      _toast('Could not save: ${e.message}');
    } finally {
      if (mounted) setState(() => _dlBusy.remove(uid));
    }
  }

  // ------------------------------------------------------------------ delete account
  Future<void> _deleteUser(Map<String, dynamic> u) async {
    final uid = (u['uid'] ?? '').toString();
    if (uid.isEmpty || _delBusy.contains(uid)) return;
    final email = (u['email'] ?? '').toString();
    final raw = (u['displayName'] ?? '').toString().trim();
    final label = raw.isNotEmpty ? raw : (email.isNotEmpty ? email : 'this user');
    final ok = await neoConfirm(
      context,
      title: 'Delete account?',
      message: '"$label"${email.isNotEmpty && raw.isNotEmpty ? ' ($email)' : ''} account permanently delete aagum: '
          'login, saved list, watch progress ellaam poidum. Thirumba edukka mudiyaadhu.',
      confirmLabel: 'DELETE',
      danger: true,
      icon: Icons.delete_forever_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _delBusy.add(uid));
    try {
      await ApiClient.call('DELETE', '/admin/users/$uid', timeout: const Duration(seconds: 60));
      if (!mounted) return;
      setState(() => _users.removeWhere((x) => x['uid'] == uid));
      _toast('Account deleted.');
    } on ApiException catch (e) {
      _toast('Could not delete: ${e.message}');
    } finally {
      if (mounted) setState(() => _delBusy.remove(uid));
    }
  }

  // ------------------------------------------------------------------ users
  Future<void> _loadUsers({required bool reset}) async {
    if (reset) {
      setState(() {
        _usersLoading = true;
        _usersError = null;
      });
    } else {
      if (_moreLoading || _nextToken == null) return;
      setState(() => _moreLoading = true);
    }
    try {
      final token = reset ? null : _nextToken;
      final path = '/admin/users?pageSize=$_kPageSize'
          '${token == null ? '' : '&pageToken=${Uri.encodeQueryComponent(token)}'}';
      final r = await ApiClient.call('GET', path);
      if (!mounted) return;
      final list = (r['users'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      setState(() {
        if (reset) _users.clear();
        _users.addAll(list);
        final t = r['nextPageToken'];
        _nextToken = t is String && t.isNotEmpty ? t : null;
        _usersLoading = false;
        _moreLoading = false;
        _usersError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (reset) {
        setState(() {
          _usersError = e.message;
          _usersLoading = false;
        });
      } else {
        setState(() => _moreLoading = false);
        _toast('Could not load more: ${e.message}');
      }
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_loadSettings(), _loadUsers(reset: true)]);
  }

  List<Map<String, dynamic>> get _visibleUsers {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _users;
    return _users.where((u) {
      final hay = '${u['displayName'] ?? ''} ${u['email'] ?? ''}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return NeoScaffold(
      overline: 'Admin // Controls',
      title: 'Controls',
      body: NeoRefresh(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
          children: [
            const SectionHeader(title: 'App Settings', tag: 'live', color: Neo.amber),
            const SizedBox(height: 12),
            _buildSettings(),
            const SizedBox(height: 28),
            SectionHeader(
              title: 'Registered Users',
              tag: _usersLoading ? 'loading' : '${_users.length}${_nextToken != null ? '+' : ''} users',
              color: Neo.cyan,
            ),
            const SizedBox(height: 12),
            NeoSearchField(controller: _search, hint: 'Search name or email'),
            const SizedBox(height: 12),
            ..._buildUsers(),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child, Color? border}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Neo.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: border ?? Neo.line),
        ),
        child: child,
      );

  Widget _buildSettings() {
    if (_settingsLoading) {
      return _card(
        child: const SizedBox(
          height: 150,
          child: Center(child: CircularProgressIndicator(color: Neo.cyan)),
        ),
      );
    }
    if (_settingsError != null) {
      return _card(
        border: Neo.pink.withValues(alpha: 0.4),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_rounded, color: Neo.pink, size: 34),
            const SizedBox(height: 10),
            Text(
              _settingsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Neo.text, fontSize: 14),
            ),
            const SizedBox(height: 14),
            SizedBox(width: 160, child: NeoButton(label: 'RETRY', onTap: _loadSettings)),
          ],
        ),
      );
    }

    final problem = _limitProblem;
    final canSave = problem == null && _limitChanged && !_savingLimit;

    return Column(
      children: [
        // ---- Maximum Concurrent Users
        _card(
          border: Neo.cyan.withValues(alpha: 0.25),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.groups_rounded, color: Neo.cyan, size: 24),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Maximum Concurrent Users',
                      style: TextStyle(color: Neo.text, fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'How many users may be signed in and active at the same time. '
                'Admins are not counted. Online now: $_activeUsers of $_limit.',
                style: const TextStyle(color: Neo.muted, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: NeoInput(
                      controller: _limitCtrl,
                      label: '',
                      hint: '$_kMinLimit - $_kMaxLimit',
                      icon: Icons.tag_rounded,
                      keyboardType: TextInputType.number,
                      action: TextInputAction.done,
                      onChanged: (_) => setState(() {}),
                      enabled: !_savingLimit,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: NeoSmallButton(
                      label: 'SAVE',
                      primary: true,
                      icon: Icons.check_rounded,
                      loading: _savingLimit,
                      onTap: canSave ? _saveLimit : null,
                    ),
                  ),
                ],
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(problem!, style: const TextStyle(color: Neo.pink, fontSize: 11.5)),
                ),
              const SizedBox(height: 6),
              const Text(
                'Applies to new sign-ins right away. People already online are not signed out.',
                style: TextStyle(color: Neo.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // ---- Allow User Video Downloads
        _card(
          border: (_allowDownloads ? Neo.cyan : Neo.pink).withValues(alpha: 0.25),
          child: Row(
            children: [
              Icon(
                _allowDownloads ? Icons.download_done_rounded : Icons.download_for_offline_outlined,
                color: _allowDownloads ? Neo.cyan : Neo.muted,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Allow User Video Downloads',
                      style: TextStyle(color: Neo.text, fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _allowDownloads
                          ? 'ON: users can download videos for offline viewing.'
                          : 'OFF: users cannot start downloads. Admins are not affected.',
                      style: TextStyle(
                        color: _allowDownloads ? Neo.cyan : Neo.muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _NeoSwitch(
                value: _allowDownloads,
                busy: _savingToggle,
                onChanged: _setDownloads,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildUsers() {
    if (_usersLoading) {
      return List.generate(
        4,
        (i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: const SizedBox(height: 86, width: double.infinity, child: Shimmer()),
          ),
        ),
      );
    }
    if (_usersError != null) {
      return [
        SizedBox(height: 260, child: ErrorState(text: _usersError!, onRetry: () => _loadUsers(reset: true))),
      ];
    }
    if (_users.isEmpty) {
      return const [
        SizedBox(
          height: 240,
          child: EmptyState(
            icon: Icons.people_outline_rounded,
            text: 'No users yet',
            sub: 'Accounts appear here after people sign up.',
          ),
        ),
      ];
    }
    final shown = _visibleUsers;
    return [
      if (shown.isEmpty)
        SizedBox(
          height: 200,
          child: EmptyState(
            icon: Icons.search_off_rounded,
            text: 'No match',
            sub: _nextToken != null
                ? 'Search covers the users loaded so far. Tap "Load more" to include the rest.'
                : 'Nobody matches "${_search.text.trim()}".',
          ),
        ),
      for (final u in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _UserCard(
            user: u,
            globalAllow: _allowDownloads,
            busy: _dlBusy.contains((u['uid'] ?? '').toString()),
            onDownloads: (allow) => _setUserDownloads(u, allow),
            deleting: _delBusy.contains((u['uid'] ?? '').toString()),
            onDelete: () => _deleteUser(u),
          ),
        ),
      if (_nextToken != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Center(
            child: SizedBox(
              width: 200,
              child: NeoButton(
                label: 'LOAD MORE',
                icon: Icons.expand_more_rounded,
                loading: _moreLoading,
                onTap: _moreLoading ? null : () => _loadUsers(reset: false),
              ),
            ),
          ),
        ),
    ];
  }
}

// ======================================================================
// USER CARD
// ======================================================================
class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool globalAllow;
  final bool busy;
  final ValueChanged<bool?> onDownloads;
  final bool deleting;
  final VoidCallback onDelete;
  const _UserCard({
    required this.user,
    required this.globalAllow,
    required this.busy,
    required this.onDownloads,
    required this.deleting,
    required this.onDelete,
  });

  Future<void> _pickDownloads(BuildContext context) async {
    final cur = user['downloadOverride'];
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Neo.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) {
        Widget opt(String value, IconData icon, Color color, String title, String sub, bool selected) => ListTile(
              leading: Icon(icon, color: color),
              title: Text(title, style: const TextStyle(color: Neo.text, fontWeight: FontWeight.w800)),
              subtitle: Text(sub, style: const TextStyle(color: Neo.muted, fontSize: 12)),
              trailing: selected ? Icon(Icons.check_circle_rounded, color: color) : null,
              onTap: () => Navigator.pop(ctx, value),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Video downloads for this user',
                        style: TextStyle(color: Neo.text, fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                ),
                opt('allow', Icons.download_done_rounded, Neo.cyan, 'Allow',
                    'Can download even if the global switch is OFF.', cur == true),
                opt('block', Icons.block_rounded, Neo.pink, 'Not allowed',
                    'Cannot download even if the global switch is ON.', cur == false),
                opt('default', Icons.tune_rounded, Neo.violet, 'Use global setting',
                    'Follows "Allow User Video Downloads" (now ${globalAllow ? 'ON' : 'OFF'}).', cur == null),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    onDownloads(choice == 'allow' ? true : (choice == 'block' ? false : null));
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _date(dynamic iso) {
    final d = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
    if (d == null) return '—';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${_months[d.month - 1]} ${d.year}, $hh:$mm';
  }

  static String _provider(String id) {
    switch (id) {
      case 'password':
        return 'EMAIL';
      case 'google.com':
        return 'GOOGLE';
      default:
        return id.split('.').first.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = (user['email'] ?? '').toString();
    final rawName = (user['displayName'] ?? '').toString().trim();
    final name = rawName.isNotEmpty
        ? rawName
        : (email.contains('@') ? email.split('@').first : 'Unnamed user');
    final photo = (user['photoUrl'] ?? '').toString();
    final isAdmin = user['role'] == 'admin';
    final online = user['online'] == true;
    final disabled = user['disabled'] == true;
    final providers = (user['providers'] as List? ?? const []).map((e) => _provider(e.toString())).toSet().toList();
    final lastSeen = user['lastSignInAt'] ?? user['lastLoginAt'];

    final initial = Text(
      name.isEmpty ? '?' : name[0].toUpperCase(),
      style: const TextStyle(color: Neo.text, fontSize: 20, fontWeight: FontWeight.w800),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neo.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isAdmin ? Neo.amber.withValues(alpha: 0.35) : Neo.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Neo.bg2),
                alignment: Alignment.center,
                child: photo.isEmpty
                    ? initial
                    : ClipOval(
                        child: Image.network(
                          photo,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => initial,
                        ),
                      ),
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online ? _kOnline : Neo.muted.withValues(alpha: 0.6),
                    border: Border.all(color: Neo.surface, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Neo.text, fontSize: 15, fontWeight: FontWeight.w800),
                ),
                if (email.isNotEmpty)
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neo.muted, fontFamily: Neo.mono, fontSize: 11.5),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (online) const NeoTag('ONLINE', color: _kOnline),
                    NeoTag(isAdmin ? 'ADMIN' : 'USER', color: isAdmin ? Neo.amber : Neo.violet),
                    for (final p in providers) NeoTag(p, color: Neo.cyan),
                    if (disabled) const NeoTag('DISABLED', color: Neo.pink),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Joined ${_date(user['createdAt'])}',
                  style: const TextStyle(color: Neo.muted, fontSize: 11.5),
                ),
                Text(
                  'Last sign-in ${_date(lastSeen)}',
                  style: const TextStyle(color: Neo.muted, fontSize: 11.5),
                ),
                if (!isAdmin) ...[
                  const SizedBox(height: 10),
                  Builder(builder: (context) {
                    final ov = user['downloadOverride'];
                    final allowed = ov is bool ? ov : globalAllow;
                    final color = allowed ? Neo.cyan : Neo.pink;
                    final label = ov is bool
                        ? (allowed ? 'DOWNLOADS: ALLOWED' : 'DOWNLOADS: BLOCKED')
                        : 'DOWNLOADS: ${allowed ? 'ON' : 'OFF'} (GLOBAL)';
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: busy ? null : () => _pickDownloads(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: color.withValues(alpha: 0.5)),
                          color: color.withValues(alpha: 0.08),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            busy
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: color))
                                : Icon(allowed ? Icons.download_done_rounded : Icons.block_rounded,
                                    size: 15, color: color),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: color, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.expand_more_rounded, size: 16, color: color),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          if (!isAdmin)
            deleting
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Neo.pink)),
                  )
                : IconButton(
                    tooltip: 'Delete account',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded, color: Neo.pink),
                  ),
        ],
      ),
    );
  }
}

// ======================================================================
// LEFT-TO-RIGHT TOGGLE SWITCH
// ======================================================================
class _NeoSwitch extends StatelessWidget {
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;
  const _NeoSwitch({required this.value, required this.busy, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const w = 58.0, h = 32.0, pad = 3.0, knob = h - pad * 2;
    return Semantics(
      toggled: value,
      button: true,
      label: 'Allow User Video Downloads',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: w,
          height: h,
          padding: const EdgeInsets.all(pad),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(h),
            color: value ? Neo.cyan.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: value ? Neo.cyan : Neo.line, width: 1.2),
            boxShadow: value ? [BoxShadow(color: Neo.cyan.withValues(alpha: 0.3), blurRadius: 14)] : null,
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: knob,
              height: knob,
              decoration: BoxDecoration(shape: BoxShape.circle, color: value ? Neo.cyan : Neo.muted),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Neo.bg),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
