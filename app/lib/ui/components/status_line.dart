import 'package:flutter/material.dart';

import '../../services/core_session.dart';
import '../../theme/lenny_colors.dart';

/// Dot + label. The text says the same as the dot color, so state is never communicated by color alone.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.link, required this.text});
  final LinkState link;
  final String text;

  Color get _color => switch (link) {
        LinkState.streaming => LennyColors.success,
        LinkState.reconnecting || LinkState.awaitingApproval => LennyColors.primary,
        LinkState.closed => LennyColors.danger,
        _ => LennyColors.info,
      };

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Flexible(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
        ]),
      );
}
