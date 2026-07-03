import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:core/core.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import '../../../observations/data/observation_local_db.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _isSavingUsername = false;
  bool _isSavingPassword = false;
  bool _isUploadingAvatar = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  Map<String, dynamic>? _profile;
  DateTime? _lastBackPress;
  int _pendingCount = 0;

  @override
  void initState() {
    super.initState();
    _checkPending();
    if (NetworkService.instance.isOnline && Supabase.instance.client.auth.currentUser != null) {
      _fetchProfile();
    }
  }

  Future<void> _checkPending() async {
    final pending = await ObservationLocalDb.instance.getPending();
    if (mounted) {
      setState(() {
        _pendingCount = pending.length;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _fetchProfile() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final profileData = await Supabase.instance.client
            .from('users')
            .select('role, user_name, avatar_url, email')
            .eq('user_id', user.id)
            .maybeSingle();

        if (mounted) {
          if (profileData != null) {
            setState(() {
              _profile = profileData;
              _usernameController.text = profileData['user_name'] ?? '';
              _isLoading = false;
            });
          } else {
            setState(() {
              _isLoading = false;
            });
            _showToast('User profile not found in database.');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showToast('Failed to load profile: $e');
      }
    }
  }

  Future<void> _updateUsername() async {
    final newUsername = _usernameController.text.trim();
    if (newUsername.isEmpty) {
      _showToast('Username cannot be empty');
      return;
    }

    setState(() {
      _isSavingUsername = true;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final updatedData = await Supabase.instance.client.from('users').update({
          'user_name': newUsername,
        }).eq('user_id', user.id).select();

        if (updatedData.isEmpty) {
          throw Exception('No rows were modified. This is usually due to missing RLS update policies on the users table.');
        }

        // Update local state
        setState(() {
          _profile?['user_name'] = newUsername;
        });

        _showToast('Username updated successfully', isError: false);
      }
    } catch (e) {
      _showToast('Failed to update username: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSavingUsername = false;
        });
      }
    }
  }

  Future<void> _updatePassword() async {
    if (_passwordController.text != _confirmPasswordController.text) {
      _showToast('Passwords do not match');
      return;
    }

    final passwordErr = Validators.validatePassword(_passwordController.text);
    if (passwordErr != null) {
      _showToast(passwordErr);
      return;
    }

    setState(() {
      _isSavingPassword = true;
    });

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: _passwordController.text),
      );
      _passwordController.clear();
      _confirmPasswordController.clear();
      _showToast('Password updated successfully', isError: false);
    } catch (e) {
      _showToast('Failed to update password: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSavingPassword = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadAvatar(ImageSource source) async {
    final picker = ImagePicker();
    try {
      final image = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );

      if (image == null) return;

      final mimeType = lookupMimeType(image.path);
      if (mimeType != 'image/jpeg' && mimeType != 'image/jpg') {
        _showToast('Only JPG/JPEG files are allowed.', isError: true);
        return;
      }

      setState(() {
        _isUploadingAvatar = true;
      });

      final file = File(image.path);
      final bytes = await file.readAsBytes();
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not logged in');

      String fileExtension = 'jpg';

      final fileName = '${user.id}_avatar.$fileExtension';

      // Ensure 'avatars' bucket exists in your Supabase project
      await Supabase.instance.client.storage.from('avatars').uploadBinary(
            fileName,
            bytes,
            fileOptions: FileOptions(
              cacheControl: '3600',
              upsert: true,
              contentType: mimeType ?? 'image/jpeg',
            ),
          );

      final publicUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(fileName);

      // Add timestamp to force image refresh in UI
      final timestampUrl = '$publicUrl?t=${DateTime.now().millisecondsSinceEpoch}';

      final updatedData = await Supabase.instance.client.from('users').update({
        'avatar_url': timestampUrl,
      }).eq('user_id', user.id).select();

      if (updatedData.isEmpty) {
        throw Exception('No rows were modified. This is usually due to missing RLS update policies on the users table.');
      }

      setState(() {
        _profile?['avatar_url'] = timestampUrl;
      });

      _showToast('Avatar updated successfully', isError: false);
    } catch (e) {
      _showToast('Failed to upload avatar: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingAvatar = false;
        });
      }
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.0)),
      ),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAndUploadAvatar(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take a Photo'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAndUploadAvatar(ImageSource.camera);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    if (mounted) {
      if (Supabase.instance.client.auth.currentUser != null) {
        _showToast('Failed to sign out. Please try again.');
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    }
  }

  Widget _buildOfflineProfileView(bool isOnline) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 20),
            const Text(
              "You're Offline",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            Text(
              "You can still record observations offline. Once you connect to the internet, you can sign in to sync your data.",
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: isOnline
                  ? () async {
                      final pendingCount = (await ObservationLocalDb.instance.getPending()).length;
                      if (!mounted) return;
                      
                      if (pendingCount > 0) {
                        final shouldSync = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Sync Offline Observations'),
                            content: Text(
                              'You have $pendingCount offline observations waiting to sync. For security purposes, to ensure these observations are attributed to the correct account, your sign in credentials will be asked to verify your credentials. Do you wish to proceed?'
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(false),
                                child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.of(context).pop(true),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700], foregroundColor: Colors.white),
                                child: const Text('Proceed'),
                              ),
                            ],
                          ),
                        );
                        if (shouldSync != true) return;
                        
                        try {
                          await Supabase.instance.client.auth.signOut();
                        } catch (e) {
                          debugPrint('Sign out error: $e');
                        }
                        
                        if (!mounted) return;
                        
                        if (Supabase.instance.client.auth.currentUser != null) {
                          _showToast('Failed to securely sign out. Please check your connection and try again.');
                          return;
                        }
                        
                        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false, arguments: {'autoSync': true});
                      } else {
                        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
                      }
                    }
                  : null,
              icon: const Icon(Icons.login),
              label: Text(
                isOnline ? "Sign In Now" : "Connect to Internet to Sign In",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineProfileView() {
    final userName = _profile?['user_name'] ?? 'User';
    final email = _profile?['email'] ?? Supabase.instance.client.auth.currentUser?.email ?? 'N/A';
    final avatarUrl = _profile?['avatar_url'] as String?;
    final defaultAvatar = 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(userName)}&background=4CAF50&color=FFFFFF&size=128';
    final displayAvatar = avatarUrl != null && avatarUrl.isNotEmpty ? avatarUrl : defaultAvatar;

    final user = Supabase.instance.client.auth.currentUser;
    final isGoogleUser = user?.appMetadata['provider'] == 'google' ||
        (user?.appMetadata['providers'] as List?)?.contains('google') == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Avatar edit section
            Center(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.green[50],
                      backgroundImage: NetworkImage(displayAvatar),
                    ),
                  ),
                  if (_isUploadingAvatar)
                    Positioned.fill(
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black38,
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                    ),
                  if (!isGoogleUser)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _isUploadingAvatar ? null : _showImageSourceDialog,
                        child: Container(
                          padding: const EdgeInsets.all(10.0),
                          decoration: BoxDecoration(
                            color: Colors.green[700],
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16.0),
            Center(
              child: Text(
                email,
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
              ),
            ),
            if (isGoogleUser) ...[
              const SizedBox(height: 20.0),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue[100]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue[800]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You are signed in with Google. Password and avatar updates are managed by Google.',
                        style: TextStyle(
                          color: Colors.blue[900],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32.0),

            // Edit Username Card
            Card(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PERSONAL INFORMATION',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 16.0),
                    TextFormField(
                      controller: _usernameController,
                      decoration: InputDecoration(
                        labelText: 'Username',
                        prefixIcon: const Icon(Icons.person_outline, color: Colors.green),
                        filled: true,
                        fillColor: Colors.grey[50],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16.0),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green[700],
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _isSavingUsername ? null : _updateUsername,
                        icon: _isSavingUsername
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: const Text(
                          'Save Username',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20.0),

            if (!isGoogleUser) ...[
              // Change Password Card
              Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                elevation: 2,
                shadowColor: Colors.black.withValues(alpha: 0.04),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SECURITY',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 16.0),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: 'New Password',
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.green),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          filled: true,
                          fillColor: Colors.grey[50],
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey[300]!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16.0),
                      TextFormField(
                        controller: _confirmPasswordController,
                        obscureText: _obscureConfirmPassword,
                        decoration: InputDecoration(
                          labelText: 'Confirm Password',
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.green),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureConfirmPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                          ),
                          filled: true,
                          fillColor: Colors.grey[50],
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey[300]!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16.0),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green[700],
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: _isSavingPassword ? null : _updatePassword,
                          icon: _isSavingPassword
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Icon(Icons.lock_reset),
                          label: const Text(
                            'Update Password',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32.0),
            ],

            // Logout Button
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red[700],
                side: BorderSide(color: Colors.red[200]!),
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16.0),
                ),
              ),
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
              label: const Text(
                'Sign Out',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24.0),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: NetworkService.instance.onConnectivityChanged,
      initialData: NetworkService.instance.isOnline,
      builder: (context, snapshot) {
        final isOnline = snapshot.data ?? false;
        final hasSession = Supabase.instance.client.auth.currentSession != null;
        final showOffline = !hasSession || !isOnline || _pendingCount > 0;

        // If online but we have no profile loaded yet, try fetching it
        if (isOnline && hasSession && _profile == null && !_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _fetchProfile());
        }

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final now = DateTime.now();
            if (_lastBackPress != null && now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
              SystemNavigator.pop();
            } else {
              _lastBackPress = now;
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Press back again to exit'),
                  duration: const Duration(seconds: 2),
                  backgroundColor: Colors.grey[800],
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              );
            }
          },
          child: Scaffold(
            backgroundColor: Colors.grey[50],
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text(
                'My Profile',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
              backgroundColor: Colors.green[700],
              elevation: 0,
            ),
          body: showOffline
              ? _buildOfflineProfileView(isOnline)
              : (_isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.green))
                  : _buildOnlineProfileView()),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: BottomNavigationBar(
              currentIndex: 2,
              onTap: (index) {
                if (index == 0) {
                  Navigator.of(context).pushReplacementNamed('/observations');
                } else if (index == 1) {
                  Navigator.of(context).pushReplacementNamed('/map');
                } else if (index == 2) {
                  // already on profile
                }
              },
              type: BottomNavigationBarType.fixed,
              backgroundColor: Colors.white,
              selectedItemColor: Colors.green[700],
              unselectedItemColor: Colors.grey[500],
              selectedFontSize: 12.0,
              unselectedFontSize: 12.0,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
              elevation: 0,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.assignment_outlined),
                  activeIcon: Icon(Icons.assignment),
                  label: 'Observations',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.map_outlined),
                  activeIcon: Icon(Icons.map),
                  label: 'Map',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          ),
          ),  // closes Scaffold
        );  // closes PopScope
      },
    );
  }
}
