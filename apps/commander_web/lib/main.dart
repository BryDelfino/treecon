import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:commander_web/src/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  runApp(const MyApp());
}
