import 'package:flutter/material.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_up_page.dart';
import 'package:scout_mobile/src/features/home/presentation/pages/home_page.dart';

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
        '/home': (context) => const HomePage(),
      },
    );
  }
}
