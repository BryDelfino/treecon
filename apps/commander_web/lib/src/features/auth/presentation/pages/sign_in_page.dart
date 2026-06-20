import 'dart:async';
import 'package:flutter/material.dart';
import 'package:core/core.dart';
import 'package:shared_services/shared_services.dart';
import 'package:commander_web/src/features/home/presentation/pages/home_page.dart';

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

  @override
  void initState() {
    super.initState();
    
    // Listen to Auth state changes (triggers on email/password sign-in and OAuth redirect callbacks)
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      final user = data.session?.user;
      
      if (user != null && !_isNavigating) {
        _isNavigating = true;
        setState(() {
          _isLoading = true;
        });

        final hasAccess = await _validateUserRole(user);
        
        if (hasAccess && mounted) {
          _showToast('Signed in successfully!', isError: false);
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => const HomePage(),
            ),
          );
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
    ScaffoldMessenger.of(context).clearSnackBars();
    
    final screenWidth = MediaQuery.of(context).size.width;
    final leftMargin = screenWidth > 400 ? screenWidth - 360.0 : 16.0;

    ScaffoldMessenger.of(context).showSnackBar(
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
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
          borderRadius: BorderRadius.circular(10.0),
        ),
        margin: EdgeInsets.only(
          bottom: 16.0,
          right: 16.0,
          left: leftMargin,
        ),
      ),
    );
  }

  /// Verifies if the authenticated user exists in public.users with the 'expert' role.
  /// If unauthorized, signs them out.
  Future<bool> _validateUserRole(User user) async {
    try {
      final userData = await Supabase.instance.client
          .from('users')
          .select('role')
          .eq('user_id', user.id)
          .maybeSingle();

      if (userData == null) {
        await Supabase.instance.client.auth.signOut();
        _showToast('Access denied. No profile found for this account.');
        return false;
      }

      final String? role = userData['role'];
      if (role != 'EXPERT') {
        await Supabase.instance.client.auth.signOut();
        _showToast('Access denied. You do not have expert privileges.');
        return false;
      }

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

  /// Trigger Google OAuth Sign In
  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });

    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
      );
    } on AuthException catch (e) {
      _showToast(e.message);
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      _showToast('Google login failed. Please try again.');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: SizedBox(
              width: 460,
              child: Card(
                elevation: 4.0,
                shadowColor: Colors.black.withOpacity(0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16.0),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32.0,
                    vertical: 40.0,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header Brand
                        const Center(
                          child: Text.rich(
                            TextSpan(
                              text: 'TREECON ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 32,
                                color: Colors.green,
                                letterSpacing: 1.2,
                              ),
                              children: [
                                TextSpan(
                                  text: 'COMMANDER',
                                  style: TextStyle(
                                    fontStyle: FontStyle.italic,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8.0),
                        Center(
                          child: Text(
                            'Sign in to your account',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32.0),

                        // Email Field
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          validator: Validators.validateEmail,
                          enabled: !_isLoading,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: BorderSide(color: Colors.grey[300]!),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: BorderSide(color: Colors.grey[300]!),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: const BorderSide(color: Colors.green, width: 2),
                            ),
                            labelText: 'Email Address',
                            labelStyle: TextStyle(color: Colors.grey[600]),
                            prefixIcon: const Icon(Icons.email_outlined, color: Colors.green),
                            filled: true,
                            fillColor: Colors.grey[50],
                          ),
                        ),
                        const SizedBox(height: 20.0),

                        // Password Field
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          validator: Validators.validatePassword,
                          enabled: !_isLoading,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: BorderSide(color: Colors.grey[300]!),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: BorderSide(color: Colors.grey[300]!),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              borderSide: const BorderSide(color: Colors.green, width: 2),
                            ),
                            labelText: 'Password',
                            labelStyle: TextStyle(color: Colors.grey[600]),
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
                            filled: true,
                            fillColor: Colors.grey[50],
                          ),
                        ),
                        const SizedBox(height: 32.0),

                        // Sign In Button
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.0),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16.0),
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
                        const SizedBox(height: 24.0),

                        // Divider
                        Row(
                          children: [
                            Expanded(child: Divider(color: Colors.grey[300])),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Text(
                                'or continue with',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Expanded(child: Divider(color: Colors.grey[300])),
                          ],
                        ),
                        const SizedBox(height: 24.0),

                        // Google Sign In Button
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.grey[800],
                            side: BorderSide(color: Colors.grey[300]!),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.0),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16.0),
                          ),
                          onPressed: _isLoading ? null : _handleGoogleSignIn,
                          icon: Image.network(
                            'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                            width: 20,
                            height: 20,
                            errorBuilder: (context, error, stackTrace) {
                              return const Text(
                                'G',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue,
                                  fontSize: 18,
                                ),
                              );
                            },
                          ),
                          label: const Text(
                            'Sign In with Google',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}