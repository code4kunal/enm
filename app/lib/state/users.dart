import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/app_user.dart';
import 'providers.dart';
import 'session.dart';

enum UserFilter { all, active, inactive }

final userFilterProvider = NotifierProvider<UserFilterController, UserFilter>(
  UserFilterController.new,
);

class UserFilterController extends Notifier<UserFilter> {
  @override
  UserFilter build() => UserFilter.all;

  void set(UserFilter f) => state = f;
}

/// Free-text filter over name, User ID and email.
final userQueryProvider = NotifierProvider<UserQueryController, String>(
  UserQueryController.new,
);

class UserQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q;
}

class UsersController extends AsyncNotifier<List<AppUser>> {
  @override
  Future<List<AppUser>> build() {
    // Who is visible depends on who is asking.
    ref.watch(sessionProvider.select((s) => s.user?.id));
    return ref.watch(userRepositoryProvider).fetchUsers();
  }

  UserRepository get _repo => ref.read(userRepositoryProvider);

  /// Creates or updates. On create, returns the temporary password the admin
  /// must hand over — it is shown once and never retrievable again.
  ///
  /// Throws [ApiException] with a message fit for the inline form error.
  Future<({AppUser user, String? temporaryPassword})> save(
    UserDraft draft,
  ) async {
    final name = draft.name.trim();
    final userId = draft.userId.trim().toUpperCase();
    final actor = ref.read(sessionProvider).user;

    if (name.isEmpty || userId.isEmpty) {
      throw const ApiException('Name and User ID are required');
    }
    if (actor != null && !actor.role.grantableRoles.contains(draft.role)) {
      throw ApiException(
        'A ${actor.role.label} cannot assign the ${draft.role.label} role',
      );
    }
    // A super admin reaches every site, so site access is meaningless for one.
    if (!draft.role.governsAllSites && draft.sites.isEmpty) {
      throw const ApiException('Select at least one site');
    }
    if (draft.password.isNotEmpty && draft.password.trim().length < 8) {
      throw const ApiException('Password must be at least 8 characters');
    }
    if (await _repo.isUserIdTaken(userId, exceptId: draft.id)) {
      throw const ApiException('User ID already exists');
    }

    final existingId = draft.id;
    if (existingId != null) {
      final current = (state.valueOrNull ?? const <AppUser>[])
          .firstWhere((u) => u.id == existingId);
      final saved = await _repo.updateUser(
        current.copyWith(
          name: name,
          userId: userId,
          email: draft.email.trim(),
          role: draft.role,
          sites: draft.role.governsAllSites
              ? const <String>[]
              : List<String>.of(draft.sites),
        ),
      );
      _patch((list) => list.map((u) => u.id == saved.id ? saved : u).toList());
      // Editing yourself must not leave the session holding a stale role.
      ref.read(sessionProvider.notifier).refreshUser(saved);
      return (user: saved, temporaryPassword: null);
    }

    final created = await _repo.createUser(
      name: name,
      userId: userId,
      email: draft.email.trim(),
      role: draft.role,
      sites: List<String>.of(draft.sites),
      password: draft.password.isEmpty ? null : draft.password.trim(),
    );
    _patch((list) => <AppUser>[created.user, ...list]);
    return (user: created.user, temporaryPassword: created.temporaryPassword);
  }

  /// Soft delete / restore.
  Future<AppUser> setActive(String id, bool active) async {
    final saved = await _repo.setActive(id, active);
    _patch((list) => list.map((u) => u.id == saved.id ? saved : u).toList());
    return saved;
  }

  /// Issues a new temporary password and revokes every live session.
  Future<String> resetPassword(String id, {String? password}) async {
    if (password != null && password.trim().length < 8) {
      throw const ApiException('Password must be at least 8 characters');
    }
    final temp = await _repo.resetPassword(id, password: password);
    _patch(
      (list) => list
          .map((u) => u.id == id ? u.copyWith(mustResetPassword: true) : u)
          .toList(),
    );
    return temp;
  }

  void _patch(List<AppUser> Function(List<AppUser>) transform) {
    state = AsyncData<List<AppUser>>(
      transform(state.valueOrNull ?? const <AppUser>[]),
    );
  }
}

final usersProvider =
    AsyncNotifierProvider<UsersController, List<AppUser>>(UsersController.new);

final filteredUsersProvider = Provider<List<AppUser>>((ref) {
  final users = ref.watch(usersProvider).valueOrNull ?? const <AppUser>[];
  final filter = ref.watch(userFilterProvider);
  final needle = ref.watch(userQueryProvider).trim().toLowerCase();

  return users.where((u) {
    final passesFilter = switch (filter) {
      UserFilter.all => true,
      UserFilter.active => u.active,
      UserFilter.inactive => !u.active,
    };
    if (!passesFilter) return false;
    if (needle.isEmpty) return true;
    return u.name.toLowerCase().contains(needle) ||
        u.userId.toLowerCase().contains(needle) ||
        u.email.toLowerCase().contains(needle);
  }).toList();
});

/// Working copy behind the create/edit user card. [id] null means "new user".
@immutable
class UserDraft {
  const UserDraft({
    this.id,
    this.name = '',
    this.userId = '',
    this.email = '',
    this.role = UserRole.executive,
    this.sites = const <String>[],
    this.password = '',
  });

  UserDraft.fromUser(AppUser u)
      : id = u.id,
        name = u.name,
        userId = u.userId,
        email = u.email,
        role = u.role,
        sites = List<String>.of(u.sites),
        password = '';

  final String? id;
  final String name;
  final String userId;
  final String email;
  final UserRole role;
  final List<String> sites;

  /// Optional. Blank means the server generates a temporary password.
  final String password;

  bool get isEdit => id != null;

  String get title => isEdit ? 'Edit user' : 'Create user';

  String get cta => isEdit ? 'Save changes' : 'Create user';

  /// Super admins reach every site, so the access picker is hidden for them.
  bool get needsSiteAccess => !role.governsAllSites;

  UserDraft copyWith({
    String? name,
    String? userId,
    String? email,
    UserRole? role,
    List<String>? sites,
    String? password,
  }) {
    return UserDraft(
      id: id,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      role: role ?? this.role,
      sites: sites ?? this.sites,
      password: password ?? this.password,
    );
  }

  UserDraft toggleSite(String site) {
    final next = List<String>.of(sites);
    next.contains(site) ? next.remove(site) : next.add(site);
    return copyWith(sites: next);
  }
}
