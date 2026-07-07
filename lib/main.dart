import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'validator_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Wall-mounted validator: force portrait, keep the screen awake, immersive.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const TransUrbanValidatorApp());
}

class TransUrbanValidatorApp extends StatelessWidget {
  const TransUrbanValidatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TransUrban Validator',
      debugShowCheckedModeBanner: false,
      theme: MovaTheme.dark, // premium dark validator theme
      home: const ValidatorScreen(),
    );
  }
}
