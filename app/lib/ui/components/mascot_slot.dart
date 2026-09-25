import 'package:flutter/material.dart';

/// Reserved spot for the Lenny mascot on the home/connection screen.
/// TODO(mascot): drop the sprite assets in here once the artwork is delivered. Intentionally empty until then.
class MascotSlot extends StatelessWidget {
  const MascotSlot({super.key, this.size = 120});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size);
}
