import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_up_page.dart';
import 'package:scout_mobile/src/features/observations/presentation/pages/observation_page.dart';
import 'package:scout_mobile/src/features/profile/presentation/pages/profile_page.dart';
import 'package:scout_mobile/src/features/map/presentation/pages/map_page.dart';
import 'core/services/network_service.dart';

class MyApp extends StatefulWidget {
  final bool hasPending;
  const MyApp({super.key, this.hasPending = false});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final StreamSubscription<bool> _connectivitySub;

  @override
  void initState() {
    super.initState();
    // Auto-sync whenever internet connectivity is restored
    _connectivitySub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (isOnline) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) {
          // Trigger the page to sync if we're on the observation page
          // We can use a globally accessible or static trigger, or rely on page's onConnectivityChanged listener.
        }
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If we are offline, direct the user straight to Observations page
    // If online, we check for a valid Supabase session
    final isOnline = NetworkService.instance.isOnline;
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    final String initialRoute = (!isOnline || hasSession || widget.hasPending) ? '/observations' : '/';

    return MaterialApp(
      title: 'Treecon Scout',
      theme: ThemeData(
        primaryColor: Colors.green,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      initialRoute: initialRoute,
      routes: {
        '/': (context) => const SignInPage(),
        '/signup': (context) => const SignUpPage(),
        '/observations': (context) => const ObservationPage(),
        '/map' : (context) => const MapPage(),
        '/profile': (context) => const ProfilePage(),
      },
    );
  }
}

