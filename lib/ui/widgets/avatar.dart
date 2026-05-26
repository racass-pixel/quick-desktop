import 'package:flutter/material.dart';
import '../../theme/theme.dart';

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.colorHex,
    this.size = 40,
  });

  final String name;
  final String colorHex;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: avatarColor(colorHex, name),
        shape: BoxShape.circle,
      ),
      child: Text(
        avatarInitials(name),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
