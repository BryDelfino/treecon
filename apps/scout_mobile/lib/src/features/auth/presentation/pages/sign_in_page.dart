import 'dart:async';
import 'package:flutter/material.dart';
import 'package:core/core.dart';
import 'package:shared_services/shared_services.dart';
import 'package:google_sign_in/google_sign_in.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _isNavigating = false;
  
  late final StreamSubscription<AuthState> _authSubscription;
  String? _username;

  @override
  void initState() {
    super.initState();
    
    // Listen to Auth state changes
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      final user = data.session?.user;
      
      if (user != null && !_isNavigating) {
        _isNavigating = true;
        setState(() {
          _isLoading = true;
        });

        // Ensure user has a profile in public.users (Scout Mobile automatically registers them as COMMUNITY)
        try {
          final existingProfile = await Supabase.instance.client
              .from('users')
              .select('role')
              .eq('user_id', user.id)
              .maybeSingle();

          if (existingProfile == null) {
            final fullName = user.userMetadata?['full_name'] ??
                user.userMetadata?['name'] ??
                user.email?.split('@').first ??
                'New User';

            await Supabase.instance.client.from('users').insert({
              'user_id': user.id,
              'role': 'COMMUNITY',
              'user_name': fullName,
              'email': user.email,
            });
          }
        } catch (e) {
          debugPrint('Error creating user profile: $e');
        }

        final hasAccess = await _validateUserRole(user);
        
        if (hasAccess && mounted) {
          _showToast('Welcome, ${_username ?? "User"}', isError: false);
          // Navigate to the main screen
          Navigator.of(context).pushReplacementNamed('/home');
        } else {
          _isNavigating = false;
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 12.0),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8.0),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
              onPressed: () {
                messenger.hideCurrentSnackBar();
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16.0,
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        margin: const EdgeInsets.all(16.0),
      ),
    );
  }

  /// Verifies if the authenticated user exists in public.users.
  /// Accepts 'scout' or 'expert' roles for mobile app access.
  Future<bool> _validateUserRole(User user) async {
    try {
      final userData = await Supabase.instance.client
          .from('users')
          .select('role, user_name')
          .eq('user_id', user.id)
          .maybeSingle();

      if (userData == null) {
        await Supabase.instance.client.auth.signOut();
        _showToast('Access denied. No profile found for this account.');
        return false;
      }

      final String? role = userData['role'];
      if (role != 'COMMUNITY' && role != 'EXPERT') {
        await Supabase.instance.client.auth.signOut();
        _showToast('Access denied. Insufficient app privileges.');
        return false;
      }

      _username = userData['user_name'];
      return true;
    } catch (e) {
      await Supabase.instance.client.auth.signOut();
      _showToast('Verification failed. Please try again.');
      return false;
    }
  }

  /// Trigger standard password sign in
  Future<void> _handleSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;

      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } on AuthException catch (e) {
      _showToast(e.message);
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      _showToast('An unexpected error occurred. Please try again.');
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Trigger Google OAuth Sign In using native SDK
  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Initialize GoogleSignIn
      final GoogleSignIn googleSignIn = GoogleSignIn.instance;
      const clientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
      debugPrint('Initializing GoogleSignIn with serverClientId: "$clientId"');
      await googleSignIn.initialize(
        serverClientId: clientId.isEmpty ? null : clientId,
      );
      
      // Clear cached state to force a fresh Google prompt (resolves stale credential errors)
      try {
        await googleSignIn.signOut();
      } catch (_) {}
      
      final googleUser = await googleSignIn.authenticate();
      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;

      if (idToken == null) {
        throw const AuthException('Could not retrieve Google ID Token.');
      }

      // Sign in to Supabase with the ID Token
      await Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
    } on AuthException catch (e) {
      _showToast(e.message);
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Google Sign-In Error: $e');
      _showToast('Google login failed: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showForgotPasswordPlaceholder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
        title: const Text('Reset Password'),
        content: const Text(
          'A password reset request feature is a placeholder. In a production build, it will trigger an email containing a recovery link.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  void _showSignUpPlaceholder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
        title: const Text('Registration'),
        content: const Text(
          'Scout registration is a placeholder. New user profiles are automatically created when signing in via Google OAuth or via administrator invitaton.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo & Brand Header
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20.0),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.park_rounded,
                        color: Colors.green,
                        size: 64,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24.0),
                  const Text(
                    'TREECON SCOUT',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Colors.green,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8.0),
                  Text(
                    'Field Observations & Data Collection',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40.0),

                  // Email Input
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    validator: Validators.validateEmail,
                    enabled: !_isLoading,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.email_outlined, color: Colors.green),
                      labelText: 'Email Address',
                      labelStyle: TextStyle(color: Colors.grey[600]),
                      filled: true,
                      fillColor: Colors.grey[50],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: const BorderSide(color: Colors.green, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16.0),

                  // Password Input
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    validator: Validators.validatePassword,
                    enabled: !_isLoading,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_outline_rounded, color: Colors.green),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: Colors.grey[600],
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      labelText: 'Password',
                      labelStyle: TextStyle(color: Colors.grey[600]),
                      filled: true,
                      fillColor: Colors.grey[50],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: const BorderSide(color: Colors.green, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12.0),

                  // Forgot Password
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _isLoading ? null : _showForgotPasswordPlaceholder,
                      child: const Text(
                        'Forgot Password?',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24.0),

                  // Sign In Button
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      elevation: 0,
                    ),
                    onPressed: _isLoading ? null : _handleSignIn,
                    child: _isLoading
                        ? const SizedBox(
                            height: 20.0,
                            width: 20.0,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Sign In',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                  const SizedBox(height: 20.0),

                  // Divider
                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey[300])),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(
                          'or connect with',
                          style: TextStyle(color: Colors.grey[500], fontSize: 14),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey[300])),
                    ],
                  ),
                  const SizedBox(height: 20.0),

                  // Google Button
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey[800],
                      side: BorderSide(color: Colors.grey[300]!),
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                    ),
                    onPressed: _isLoading ? null : _handleGoogleSignIn,
                    icon: Image.network(
                      'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                      width: 20,
                      height: 20,
                      errorBuilder: (context, error, stackTrace) => const Text(
                        'G',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 18),
                      ),
                    ),
                    label: const Text(
                      'Sign In with Google',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 32.0),

                  // Sign Up Link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account?",
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      TextButton(
                        onPressed: _isLoading ? null : _showSignUpPlaceholder,
                        child: const Text(
                          'Sign Up',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
