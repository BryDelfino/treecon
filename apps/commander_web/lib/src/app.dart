import 'package:flutter/material.dart';
import 'package:commander_web/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:commander_web/src/features/map/presentation/pages/map.dart';


class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Treecon Commander - Sign In',
      home: SignInPage(), 
    );
  }
}