import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/picked_attachment.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PickedAttachmentsHolder extends StatefulWidget {
  const PickedAttachmentsHolder({
    Key? key,
    required this.subjectTextController,
    required this.textController,
    required this.controller,
    this.initialAttachments = const [],
  }) : super(key: key);

  final ConversationViewController? controller;
  final TextEditingController subjectTextController;
  final TextEditingController textController;
  final List<PlatformFile> initialAttachments;

  @override
  OptimizedState createState() => _PickedAttachmentsHolderState();
}

class _PickedAttachmentsHolderState extends OptimizedState<PickedAttachmentsHolder> {
  
  List<PlatformFile> get pickedAttachments => widget.controller != null
      ? widget.controller!.pickedAttachments : widget.initialAttachments;
  
  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Obx(() {
          if (pickedAttachments.isNotEmpty) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: iOS ? 150 : 100,
                minHeight: iOS ? 150 : 100,
              ),
              child: Padding(
                padding: iOS ? EdgeInsets.zero : const EdgeInsets.only(left: 7.5, right: 7.5),
                child: CustomScrollView(
                  physics: ThemeSwitcher.getScrollPhysics(),
                  scrollDirection: Axis.horizontal,
                  slivers: [
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                            (context, index) {
                          return PickedAttachment(
                            key: ValueKey(pickedAttachments[index].name),
                            data: pickedAttachments[index],
                            controller: widget.controller,
                            onRemove: (file) {
                              if (widget.controller == null) {
                                pickedAttachments.removeWhere((e) => e.path == file.path);
                                setState(() {});
                              }
                            },
                          );
                        },
                        childCount: pickedAttachments.length,
                      ),
                    )
                  ],
                ),
              ),
            );
          } else {
            return const SizedBox.shrink();
          }
        }),
        if (widget.controller != null)
          Obx(() {
            if (widget.controller!.emojiMatches.isNotEmpty) {
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: min(widget.controller!.emojiMatches.length * 48, 150)),
                child: Padding(
                  padding: const EdgeInsets.all(5.0),
                  child: Container(
                    decoration: BoxDecoration(
                      border: iOS ? null : Border.fromBorderSide(
                        BorderSide(color: context.theme.colorScheme.background, strokeAlign: StrokeAlign.outside)
                      ),
                      borderRadius: BorderRadius.circular(20),
                      color: context.theme.colorScheme.properSurface,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Scrollbar(
                      radius: const Radius.circular(4),
                      controller: widget.controller!.emojiScrollController,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 0),
                        controller: widget.controller!.emojiScrollController,
                        physics: ThemeSwitcher.getScrollPhysics(),
                        shrinkWrap: true,
                        itemBuilder: (BuildContext context, int index) => Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTapDown: (details) {
                              widget.controller!.emojiSelectedIndex.value = index;
                            },
                            onTap: () {
                              final _controller = widget.controller!.focusNode.hasFocus ? widget.textController : widget.subjectTextController;
                              widget.controller!.emojiSelectedIndex.value = 0;
                              final text = _controller.text;
                              final regExp = RegExp(":[^: \n]{1,}([ \n:]|\$)", multiLine: true);
                              final matches = regExp.allMatches(text);
                              if (matches.isNotEmpty && matches.any((m) => m.start < _controller.selection.start)) {
                                final match = matches.lastWhere((m) => m.start < _controller.selection.start);
                                final char = widget.controller!.emojiMatches[index].char;
                                _controller.text = "${text.substring(0, match.start)}$char ${text.substring(match.end)}";
                                _controller.selection = TextSelection.fromPosition(TextPosition(offset: match.start + char.length + 1));
                              }
                              widget.controller!.emojiMatches.clear();
                            },
                            child: Obx(() => ListTile(
                                dense: true,
                                selectedTileColor: context.theme.colorScheme.properSurface.lightenOrDarken(20),
                                selected: widget.controller!.emojiSelectedIndex.value == index,
                                title: Row(
                                  children: <Widget>[
                                    Text(
                                      widget.controller!.emojiMatches[index].char,
                                      style:
                                      context.textTheme.labelLarge!.apply(fontFamily: "Apple Color Emoji"),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      ":${widget.controller!.emojiMatches[index].shortName}:",
                                      style: context.textTheme.labelLarge!.copyWith(fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                )),
                            ),
                          ),
                        ),
                        itemCount: widget.controller!.emojiMatches.length,
                      ),
                    ),
                  ),
                ),
              );
            } else {
              return const SizedBox.shrink();
            }
          }),
      ],
    );
  }
}
