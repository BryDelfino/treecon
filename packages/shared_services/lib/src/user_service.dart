import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

class UserService {
  final SupabaseClient _client;

  UserService(this._client);

  /// Sign up a user with email and password, setting metadata like username.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String userName,
    String? avatarUrl,
  }) async {
    final finalAvatarUrl = avatarUrl ?? 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(userName)}&background=4CAF50&color=FFFFFF&size=128';
    return await _client.auth.signUp(
      email: email,
      password: password,
      data: {
        'user_name': userName,
        'avatar_url': finalAvatarUrl,
      },
    );
  }

  /// Upload an avatar to the Supabase avatars storage bucket.
  Future<String> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExtension,
  }) async {
    // Generate a unique filename using timestamp
    const String contentType = 'image/jpeg';
    final fileName = '$userId-${DateTime.now().millisecondsSinceEpoch}.$fileExtension';
    final filePath = fileName;

    await _client.storage.from('avatars').uploadBinary(
      filePath,
      bytes,
      fileOptions: const FileOptions(
        contentType: contentType,
        upsert: true,
      ),
    );

    return _client.storage.from('avatars').getPublicUrl(filePath);
  }

  /// Insert/update user profile in public.users.
  Future<void> createUserProfile({
    required String userId,
    required String userName,
    required String email,
    String? avatarUrl,
  }) async {
    final finalAvatarUrl = avatarUrl ?? 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(userName)}&background=4CAF50&color=FFFFFF&size=128';
    await _client.from('users').upsert({
      'user_id': userId,
      'role': 'COMMUNITY',
      'user_name': userName,
      'email': email,
      'avatar_url': finalAvatarUrl,
    });
  }
}
