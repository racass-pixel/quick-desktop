// Thin banner pinned at the top of a group/channel conversation when a voice
// chat is active. Shows the participant count + a Join button. When we're
// already in the call it shows a "You're in voice chat" return-to-call line
// instead.

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';
import '../state/group_call_state.dart';

class GroupCallBanner extends StatelessWidget {
  const GroupCallBanner({
    super.key,
    required this.conversationId,
    required this.group,
  });

  final String conversationId;
  final GroupCallNotifier group;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: group,
      builder: (_, _) {
        final call = group.activeByConv[conversationId];
        final weAreIn = group.lifecycle == GroupCallLifecycle.active &&
            group.conversationId == conversationId;
        if (call == null && !weAreIn) return const SizedBox.shrink();

        final label = weAreIn
            ? "You're in voice chat"
            : 'Voice chat  -  ${call?.participantCount ?? 0} participants';
        final btnLabel = weAreIn ? 'Return' : 'Join';
        final btnColor = weAreIn ? const Color(0xFF22C55E) : AppColors.ember;

        return Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: AppColors.raised,
            border: Border(bottom: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: [
              const Icon(Icons.graphic_eq, color: AppColors.ember, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.ink1,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                height: 30,
                child: ElevatedButton(
                  onPressed: () {
                    if (weAreIn) {
                      group.expand();
                    } else if (call != null) {
                      // ignore: discarded_futures
                      group.joinGroupCall(call.id, conversationId);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: btnColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.rSm),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(btnLabel),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
