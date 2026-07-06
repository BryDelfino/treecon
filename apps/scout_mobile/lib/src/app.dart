import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_up_page.dart';
import 'package:scout_mobile/src/features/observations/presentation/pages/observation_page.dart';
import 'package:scout_mobile/src/features/profile/presentation/pages/profile_page.dart';
import 'package:scout_mobile/src/features/map/presentation/pages/map_page.dart';
import 'core/services/network_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isOnline = NetworkService.instance.isOnline;
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    // If offline or already has a session, go straight to observations.
    // Only show sign-in when online with no session.
    final String initialRoute = (isOnline && !hasSession) ? '/' : '/observations';

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
