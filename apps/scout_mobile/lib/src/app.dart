import 'package:flutter/material.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_up_page.dart';
import 'package:scout_mobile/src/features/observations/presentation/pages/observation_page.dart';
import 'package:scout_mobile/src/features/profile/presentation/pages/profile_page.dart';
import 'package:scout_mobile/src/features/map/presentation/pages/map_page.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Treecon Scout',
      theme: ThemeData(
        primaryColor: Colors.green,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      initialRoute: '/',
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
