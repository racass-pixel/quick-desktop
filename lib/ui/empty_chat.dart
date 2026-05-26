import 'package:flutter/material.dart';
import '../theme/theme.dart';

class EmptyChat extends StatelessWidget {
  const EmptyChat({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.panel,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.line),
            ),
            child: const Icon(Icons.chat_bubble_outline,
                color: AppColors.ink3, size: 26),
          ),
          const SizedBox(height: 16),
          const Text('Select a chat to start messaging',
              style: TextStyle(color: AppColors.ink2, fontSize: 14)),
        ],
      ),
    );
  }
}
