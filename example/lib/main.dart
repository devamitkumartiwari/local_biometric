import 'package:flutter/material.dart';
import 'pages/home_page.dart';

void main() {
  runApp(const LocalBiometricExampleApp());
}

class LocalBiometricExampleApp extends StatelessWidget {
  const LocalBiometricExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Biometric Example',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
      ),
      home: const HomePage(),
    );
  }
}
