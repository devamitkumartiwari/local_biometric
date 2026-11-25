import 'package:material_ui/material_ui.dart';

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
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 2),
      ),
      home: const HomePage(),
    );
  }
}
