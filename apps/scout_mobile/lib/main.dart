import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/features/auth/presentation/pages/sign_in_page.dart';
import 'package:scout_mobile/src/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  runApp(const MyApp());
}