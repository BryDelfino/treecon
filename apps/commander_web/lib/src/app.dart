import 'package:flutter/material.dart';
import 'package:commander_web/src/features/auth/presentation/pages/sign_in_page.dart';


class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Treecon Commander',
      home: SignInPage(), 
    );
  }
}