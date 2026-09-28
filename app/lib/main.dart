import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'brand.dart';
import 'theme/lenny_tokens.dart';
import 'ui/screens/sender_screen.dart';

void main() => runApp(const ProviderScope(child: LennyApp()));

class LennyApp extends StatelessWidget {
  const LennyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: Brand.appName,
        theme: lennyTheme(),
        debugShowCheckedModeBanner: false,
        home: const SenderScreen(),
      );
}
