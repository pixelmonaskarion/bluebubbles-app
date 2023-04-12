import 'dart:async';
import 'dart:math';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:bluebubbles/app/components/mentionable_text_editing_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/send_animation.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/picked_attachments_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/reply_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/components/custom/custom_bouncing_scroll_physics.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:chunked_stream/chunked_stream.dart';
import 'package:collection/collection.dart';
import 'package:emojis/emoji.dart';
import 'package:file_picker/file_picker.dart' hide PlatformFile;
import 'package:file_picker/file_picker.dart' as pf;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:giphy_get/giphy_get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';

class ConversationTextField extends CustomStateful<ConversationViewController> {
  ConversationTextField({
    Key? key,
    required super.parentController,
  }) : super(key: key);

  static ConversationTextFieldState? of(BuildContext context) {
    return context.findAncestorStateOfType<ConversationTextFieldState>();
  }

  @override
  ConversationTextFieldState createState() => ConversationTextFieldState();
}

class ConversationTextFieldState extends CustomState<ConversationTextField, void, ConversationViewController> with TickerProviderStateMixin {
  final recorderController = kIsWeb ? null : RecorderController();

  // emoji
  final Map<String, Emoji> emojiNames = Map.fromEntries(Emoji.all().map((e) => MapEntry(e.shortName, e)));
  final Map<String, Emoji> emojiFullNames = Map.fromEntries(Emoji.all().map((e) => MapEntry(e.name, e)));

  // typing indicators
  String oldText = "\n";
  Timer? _debounceTyping;

  // emoji
  String oldEmojiText = "";

  // previous text state
  String oldTextFieldText = "";
  TextSelection oldTextFieldSelection = const TextSelection.collapsed(offset: 0);

  Chat get chat => controller.chat;

  String get chatGuid => chat.guid;

  bool get showAttachmentPicker => controller.showAttachmentPicker;

  @override
  void initState() {
    super.initState();
    forceDelete = false;

    // Load the initial chat drafts
    getDrafts();

    controller.textController.processMentions();

    // Save state
    oldTextFieldText = controller.textController.text;
    oldTextFieldSelection = controller.textController.selection;

    if (controller.fromChatCreator) {
      controller.focusNode.requestFocus();
    } else if (ss.settings.autoOpenKeyboard.value) {
      updateObx(() {
        controller.focusNode.requestFocus();
      });
    }

    controller.focusNode.addListener(() => focusListener(false));
    controller.subjectFocusNode.addListener(() => focusListener(true));

    controller.textController.addListener(() => textListener(false));
    controller.subjectTextController.addListener(() => textListener(true));
  }

  void getDrafts() async {
    getTextDraft();
    await getAttachmentDrafts();
  }

  void getTextDraft({String? text}) {
    // Only change the text if the incoming text is different.
    final incomingText = text ?? chat.textFieldText;
    if (incomingText != null && incomingText.isNotEmpty && incomingText != controller.textController.text) {
      controller.textController.text = incomingText;
    }
  }

  Future<void> getAttachmentDrafts({List<String> attachments = const []}) async {
    // Only change the attachments if the incoming attachments are different.
    final incomingAttachments = attachments.isEmpty ? chat.textFieldAttachments : attachments;
    final currentPicked = controller.pickedAttachments.map((element) => element.path).toList();
    if (incomingAttachments.any((element) => !currentPicked.contains(element))) {
      controller.pickedAttachments.clear();
    }

    for (String s in incomingAttachments) {
      final file = File(s);
      if (!currentPicked.contains(s) && await file.exists()) {
        final bytes = await file.readAsBytes();
        controller.pickedAttachments.add(PlatformFile(
          name: file.path.split("/").last,
          bytes: bytes,
          size: bytes.length,
          path: s,
        ));
      }
    }
  }

  void focusListener(bool subject) async {
    final _focusNode = subject ? controller.subjectFocusNode : controller.focusNode;
    if (_focusNode.hasFocus && showAttachmentPicker) {
      setState(() {
        controller.showAttachmentPicker = !showAttachmentPicker;
      });
    }
  }

  void textListener(bool subject) {
    if (!subject) {
      chat.textFieldText = controller.textController.text;
    }

    // Clean mentions
    if (!subject) {
      // After each edit, the worst that can happen is a chunk gets removed,
      // so we can figure out exactly what changed by searching for where the chunk could be removed from
      // along with the old selection data

      String nText = controller.textController.text;
      String oText = oldTextFieldText;

      // Need fewer chars for anything bad to happen
      if (nText.length < oText.length) {
        // Search for the new state in the old state starting from the old selection's end
        String textSearchPart = oText.substring(oldTextFieldSelection.end);
        int indexInNew = textSearchPart == "" ? nText.length : nText.indexOf(textSearchPart, controller.textController.selection.end);
        if (indexInNew == -1) {
          // This means that the cursor was behind the deleted portion (user used delete key probably)
          textSearchPart = oText.substring(0, oldTextFieldSelection.start);
          indexInNew = textSearchPart == "" ? 0 : nText.indexOf(textSearchPart);
          indexInNew += textSearchPart.length;
        }

        if (indexInNew != -1) { // Just in case
          bool deletingBadMention = false;

          String textPart1 = nText.substring(0, indexInNew);
          String textPart2 = nText.substring(indexInNew);

          if (MentionTextEditingController.escapingChar.allMatches(textPart1).length % 2 != 0) {
            final badMentionIndex = textPart1.lastIndexOf(MentionTextEditingController.escapingChar);
            textPart1 = textPart1.substring(0, badMentionIndex);
            deletingBadMention = true;
          }
          if (MentionTextEditingController.escapingChar.allMatches(textPart2).length % 2 != 0) {
            final badMentionIndex = textPart2.indexOf(MentionTextEditingController.escapingChar);
            textPart2 = textPart2.substring(badMentionIndex + 1);
            deletingBadMention = true;
          }

          if (deletingBadMention) {
            oldTextFieldText = textPart1 + textPart2;
            oldTextFieldSelection = TextSelection.collapsed(offset: textPart1.length);
            controller.textController.value = TextEditingValue(text: textPart1 + textPart2, selection: TextSelection.collapsed(offset: textPart1.length));
            controller.textController.processMentions();
            return;
          }
        }
      }

      // Also handle people arrow-keying or clicking into mentions
      String text = controller.textController.text;
      TextSelection selection = controller.textController.selection;
      if (selection.isCollapsed && selection.start != -1) {
        final behind = text.substring(0, selection.baseOffset);
        final behindMatches = MentionTextEditingController.escapingChar.allMatches(behind);
        if (behindMatches.length % 2 != 0) {
          // Assuming the rest of the code works, we're guaranteed to be inside a mention now
          final ahead = text.substring(selection.baseOffset);
          final aheadMatches = MentionTextEditingController.escapingChar.allMatches(ahead);

          // Now we determine which side of the mention to put the cursor on.
          // We can use the old selection to figure out if the user is moving left/right
          if (oldTextFieldSelection.isCollapsed) {
            if (oldTextFieldSelection.baseOffset > selection.baseOffset) {
              // moving left
              oldTextFieldSelection = TextSelection.collapsed(offset: behindMatches.last.start);
              controller.textController.selection = oldTextFieldSelection;
              return;
            } else if (oldTextFieldSelection.baseOffset < selection.baseOffset) {
              // moving right
              oldTextFieldSelection = TextSelection.collapsed(offset: behind.length + aheadMatches.first.end);
              controller.textController.selection = oldTextFieldSelection;
              return;
            }
          }

          // If we get here then we need to pick the closest side
          if (selection.baseOffset - behindMatches.last.end < aheadMatches.first.start - selection.baseOffset) {
            // moving left
            oldTextFieldSelection = TextSelection.collapsed(offset: behindMatches.last.start);
            controller.textController.selection = oldTextFieldSelection;
            return;
          } else {
            // Closer to right
            oldTextFieldSelection = TextSelection.collapsed(offset: behind.length + aheadMatches.first.end);
            controller.textController.selection = oldTextFieldSelection;
            return;
          }
        }
      }

      if (!selection.isCollapsed && oldTextFieldSelection.baseOffset == selection.baseOffset) {
        if (oldTextFieldSelection.extentOffset < selection.extentOffset) {
          // Means we're shift+selecting rightwards
          final behind = text.substring(0, selection.extentOffset);
          final ahead = text.substring(selection.extentOffset);
          final aheadMatches = MentionTextEditingController.escapingChar.allMatches(ahead);
          if (aheadMatches.length % 2 != 0) {
            // Assuming the rest of the code works, we're guaranteed to be inside a mention now
            oldTextFieldSelection = TextSelection(baseOffset: selection.baseOffset, extentOffset: behind.length + aheadMatches.first.end);
            controller.textController.selection = oldTextFieldSelection;
            return;
          }
        } else if (oldTextFieldSelection.extentOffset > selection.extentOffset) {
          // Means we're shift+selecting leftwards
          final behind = text.substring(0, selection.extentOffset);
          final behindMatches = MentionTextEditingController.escapingChar.allMatches(behind);
          if (behindMatches.length % 2 != 0) {
            // Assuming the rest of the code works, we're guaranteed to be inside a mention now
            oldTextFieldSelection = TextSelection(baseOffset: selection.baseOffset, extentOffset: behindMatches.last.start);
            controller.textController.selection = oldTextFieldSelection;
            return;
          }
        }
      }

      oldTextFieldText = controller.textController.text;
      oldTextFieldSelection = controller.textController.selection;
    }

    // typing indicators
    final newText = "${controller.subjectTextController.text}\n${controller.textController.text}";
    if (newText != oldText) {
      _debounceTyping?.cancel();
      oldText = newText;
      // don't send a bunch of duplicate events for every typing change
      if (ss.settings.enablePrivateAPI.value &&
          (chat.autoSendTypingIndicators ?? ss.settings.privateSendTypingIndicators.value)) {
        if (_debounceTyping == null) {
          socket.sendMessage("started-typing", {"chatGuid": chatGuid});
        }
        _debounceTyping = Timer(const Duration(seconds: 3), () {
          socket.sendMessage("stopped-typing", {"chatGuid": chatGuid});
          _debounceTyping = null;
        });
      }
    }
    // emoji picker
    final _controller = subject ? controller.subjectTextController : controller.textController;
    final newEmojiText = _controller.text;
    if (newEmojiText.contains(":") && newEmojiText != oldEmojiText) {
      oldEmojiText = newEmojiText;
      final regExp = RegExp(r"(?<=^|[^a-zA-Z\d]):[^: \n]{2,}(?:(?=[ \n]|$)|:)", multiLine: true);
      final matches = regExp.allMatches(newEmojiText);
      List<Emoji> allMatches = [];
      String emojiName = "";
      if (matches.isNotEmpty && matches.first.start < _controller.selection.start) {
        RegExpMatch match = matches.lastWhere((m) => m.start < _controller.selection.start);
        if (newEmojiText[match.end - 1] == ":") {
          // Full emoji text (do not search for partial matches)
          emojiName = newEmojiText.substring(match.start + 1, match.end - 1).toLowerCase();
          if (emojiNames.keys.contains(emojiName)) {
            allMatches = [Emoji.byShortName(emojiName)!];
            // We can replace the :emoji: with the actual emoji here
            String _text = newEmojiText.substring(0, match.start) + allMatches.first.char + newEmojiText.substring(match.end);
            _controller.value = TextEditingValue(text: _text, selection: TextSelection.fromPosition(TextPosition(offset: match.start + allMatches.first.char.length)));
            allMatches.clear();
          } else {
            allMatches = Emoji.byKeyword(emojiName).toList();
          }
        } else if (match.end >= _controller.selection.start) {
          emojiName = newEmojiText.substring(match.start + 1, match.end).toLowerCase();
          Iterable<Emoji> emojiExactlyMatches = emojiNames.containsKey(emojiName) ? [emojiNames[emojiName]!] : [];
          Iterable<String> emojiNameMatches = emojiNames.keys.where((name) => name.startsWith(emojiName));
          Iterable<String> emojiNameAnywhereMatches = emojiNames.keys
              .where((name) => name.substring(1).contains(emojiName))
              .followedBy(emojiFullNames.keys.where((name) => name.contains(emojiName))); // Substring 1 to avoid dupes
          Iterable<Emoji> emojiMatches = emojiNameMatches.followedBy(emojiNameAnywhereMatches).map((n) => emojiNames[n] ?? emojiFullNames[n]!);
          Iterable<Emoji> keywordMatches = Emoji.byKeyword(emojiName);
          allMatches = emojiExactlyMatches.followedBy(emojiMatches.followedBy(keywordMatches)).toSet().toList();
          // Remove tone variations
          List<Emoji> withoutTones = allMatches.toList();
          withoutTones.removeWhere((e) => e.shortName.contains("_tone"));
          if (withoutTones.isNotEmpty) {
            allMatches = withoutTones;
          }
        }
        Logger.info("${allMatches.length} matches found for: $emojiName");
      }
      controller.mentionMatches.value = [];
      controller.mentionSelectedIndex.value = 0;
      if (allMatches.isNotEmpty) {
        controller.emojiMatches.value = allMatches;
        controller.emojiSelectedIndex.value = 0;
      } else {
        controller.emojiMatches.value = [];
        controller.emojiSelectedIndex.value = 0;
      }
    } else if (!subject && newEmojiText.contains("@")) {
      oldEmojiText = newEmojiText;
      final regExp = RegExp(r"(?<=^|[^a-zA-Z\d])@(?:[^@ \n]+|$)(?=[ \n]|$)", multiLine: true);
      final matches = regExp.allMatches(newEmojiText);
      List<Mentionable> allMatches = [];
      String mentionName = "";
      if (matches.isNotEmpty && matches.first.start < _controller.selection.start) {
        RegExpMatch match = matches.lastWhere((m) => m.start < _controller.selection.start);
        final text = newEmojiText.substring(match.start, match.end);
        if (text.endsWith("@")) {
          allMatches = controller.mentionables;
        } else if (newEmojiText[match.end - 1] == "@") {
          mentionName = newEmojiText.substring(match.start + 1, match.end - 1).toLowerCase();
          allMatches = controller.mentionables.where((e) => e.address.toLowerCase().startsWith(mentionName.toLowerCase()) || e.displayName.toLowerCase().startsWith(mentionName.toLowerCase())).toList();
          allMatches.addAll(controller.mentionables.where((e) => !allMatches.contains(e) && (e.address.isCaseInsensitiveContains(mentionName) || e.displayName.isCaseInsensitiveContains(mentionName))).toList());
        } else if (match.end >= _controller.selection.start) {
          mentionName = newEmojiText.substring(match.start + 1, match.end).toLowerCase();
          allMatches = controller.mentionables.where((e) => e.address.toLowerCase().startsWith(mentionName.toLowerCase()) || e.displayName.toLowerCase().startsWith(mentionName.toLowerCase())).toList();
          allMatches.addAll(controller.mentionables.where((e) => !allMatches.contains(e) && (e.address.isCaseInsensitiveContains(mentionName) || e.displayName.isCaseInsensitiveContains(mentionName))).toList());
        }
        Logger.info("${allMatches.length} matches found for: $mentionName");
      }
      controller.emojiMatches.value = [];
      controller.emojiSelectedIndex.value = 0;
      if (allMatches.isNotEmpty) {
        controller.mentionMatches.value = allMatches;
        controller.mentionSelectedIndex.value = 0;
      } else {
        controller.mentionMatches.value = [];
        controller.mentionSelectedIndex.value = 0;
      }
    } else {
      oldEmojiText = newEmojiText;
      controller.emojiMatches.value = [];
      controller.emojiSelectedIndex.value = 0;
      controller.mentionMatches.value = [];
      controller.mentionSelectedIndex.value = 0;
    }
  }

  @override
  void dispose() {
    chat.textFieldText = controller.textController.text;
    chat.textFieldAttachments = controller.pickedAttachments.where((e) => e.path != null).map((e) => e.path!).toList();
    chat.save(updateTextFieldText: true, updateTextFieldAttachments: true);

    controller.focusNode.dispose();
    controller.subjectFocusNode.dispose();
    controller.textController.dispose();
    controller.subjectTextController.dispose();
    recorderController?.dispose();
    if (chat.autoSendTypingIndicators ?? ss.settings.privateSendTypingIndicators.value) {
      socket.sendMessage("stopped-typing", {"chatGuid": chatGuid});
    }

    super.dispose();
  }

  Future<void> sendMessage({String? effect}) async {
    if (controller.scheduledDate.value != null) {
      final date = controller.scheduledDate.value!;
      if (date.isBefore(DateTime.now())) return showSnackbar("Error", "Pick a date in the future!");
      if (controller.textController.text.contains(MentionTextEditingController.escapingChar)) return showSnackbar("Error", "Mentions are not allowed in scheduled messages!");
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: context.theme.colorScheme.properSurface,
            title: Text(
              "Scheduling message...",
              style: context.theme.textTheme.titleLarge,
            ),
            content: Container(
              height: 70,
              child: Center(
                child: CircularProgressIndicator(
                  backgroundColor: context.theme.colorScheme.properSurface,
                  valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                ),
              ),
            ),
          );
        },
      );
      final response = await http.createScheduled(chat.guid, controller.textController.text, date.toUtc(), {"type": "once"});
      Navigator.of(context).pop();
      if (response.statusCode == 200 && response.data != null) {
        showSnackbar("Notice", "Message scheduled successfully for ${buildFullDate(date)}");
      } else {
        Logger.error("Scheduled message error: ${response.statusCode}");
        Logger.error(response.data);
        showSnackbar("Error", "Something went wrong!");
      }
    } else {
      final text = controller.textController.text;
      if (text.isEmpty && controller.subjectTextController.text.isEmpty && !ss.settings.privateAPIAttachmentSend.value) {
        if (controller.replyToMessage != null) {
          return showSnackbar("Error", "Turn on Private API Attachment Send to send replies with media!");
        } else if (effect != null) {
          return showSnackbar("Error", "Turn on Private API Attachment Send to send effects with media!");
        }
      }
      if (effect == null && ss.settings.enablePrivateAPI.value) {
        final cleansed = text.replaceAll("!", "").toLowerCase();
        switch (cleansed) {
          case "congratulations":
          case "congrats":
            effect = effectMap["confetti"];
            break;
          case "happy birthday":
            effect = effectMap["balloons"];
            break;
          case "happy new year":
            effect = effectMap["fireworks"];
            break;
          case "happy chinese new year":
          case "happy lunar new year":
            effect = effectMap["celebration"];
            break;
          case "pew pew":
            effect = effectMap["lasers"];
            break;
        }
      }
      await controller.send(
        controller.pickedAttachments,
        text,
        controller.subjectTextController.text,
        controller.replyToMessage?.item1.threadOriginatorGuid ?? controller.replyToMessage?.item1.guid,
        controller.replyToMessage?.item2,
        effect,
        false,
      );
    }
    controller.pickedAttachments.clear();
    controller.textController.clear();
    controller.subjectTextController.clear();
    controller.replyToMessage = null;
    controller.scheduledDate.value = null;
    _debounceTyping = null;
    // Remove the saved text field draft
    if ((chat.textFieldText ?? "").isNotEmpty) {
      chat.textFieldText = "";
      chat.save(updateTextFieldText: true);
    }
  }

  Future<void> openFullCamera({String type = 'camera'}) async {
    bool granted = (await Permission.camera.request()).isGranted;
    if (!granted) {
      showSnackbar(
        "Error",
        "Camera access was denied!"
      );
      return;
    }

    late final XFile? file;
    if (type == 'camera') {
      file = await ImagePicker().pickImage(source: ImageSource.camera);
    } else {
      file = await ImagePicker().pickVideo(source: ImageSource.camera);
    }
    if (file != null) {
      controller.pickedAttachments.add(PlatformFile(
        path: file.path,
        name: file.path.split('/').last,
        size: await file.length(),
        bytes: await file.readAsBytes(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      left: false,
      right: false,
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 5.0, top: 10.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (!kIsWeb && iOS && Platform.isAndroid)
                GestureDetector(
                  onLongPress: () {
                    openFullCamera(type: 'video');
                  },
                  child: IconButton(
                    padding: const EdgeInsets.only(left: 10),
                    icon: Icon(
                      CupertinoIcons.camera_fill,
                      color: context.theme.colorScheme.outline,
                      size: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      openFullCamera();
                    }
                  ),
                ),
              IconButton(
                icon: Icon(
                  iOS
                      ? CupertinoIcons.square_arrow_up_on_square_fill
                      : material
                          ? Icons.add_circle_outline
                          : Icons.add,
                  color: context.theme.colorScheme.outline,
                  size: 28,
                ),
                visualDensity: Platform.isAndroid ? VisualDensity.compact : null,
                onPressed: () async {
                  if (kIsDesktop) {
                    final res = await FilePicker.platform.pickFiles(withReadStream: true, allowMultiple: true);
                    if (res == null || res.files.isEmpty || res.files.first.readStream == null) return;

                    for (pf.PlatformFile e in res.files) {
                      if (e.size / 1024000 > 1000) {
                        showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.");
                        continue;
                      }
                      controller.pickedAttachments.add(PlatformFile(
                        path: e.path,
                        name: e.name,
                        size: e.size,
                        bytes: await readByteStream(e.readStream!),
                      ));
                    }
                  } else if (kIsWeb) {
                    showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                              title: Text("What would you like to do?", style: context.theme.textTheme.titleLarge),
                              content: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: <Widget>[
                                ListTile(
                                  title: Text("Upload file", style: Theme.of(context).textTheme.bodyLarge),
                                  onTap: () async {
                                    final res = await FilePicker.platform.pickFiles(withData: true, allowMultiple: true);
                                    if (res == null || res.files.isEmpty || res.files.first.bytes == null) return;

                                    for (pf.PlatformFile e in res.files) {
                                      if (e.size / 1024000 > 1000) {
                                        showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.");
                                        continue;
                                      }
                                      controller.pickedAttachments.add(PlatformFile(
                                        path: null,
                                        name: e.name,
                                        size: e.size,
                                        bytes: e.bytes!,
                                      ));
                                    }
                                    Get.back();
                                  },
                                ),
                                ListTile(
                                  title: Text("Send location", style: Theme.of(context).textTheme.bodyLarge),
                                  onTap: () async {
                                    Share.location(chat);
                                    Get.back();
                                  },
                                ),
                              ]),
                              backgroundColor: context.theme.colorScheme.properSurface,
                            ));
                  } else {
                    if (!showAttachmentPicker) {
                      controller.focusNode.unfocus();
                      controller.subjectFocusNode.unfocus();
                    }
                    setState(() {
                      controller.showAttachmentPicker = !showAttachmentPicker;
                    });
                  }
                },
              ),
              if (!kIsWeb && !Platform.isAndroid)
                IconButton(
                    icon: Icon(Icons.gif, color: context.theme.colorScheme.outline, size: 28),
                    onPressed: () async {
                      if (kIsDesktop || kIsWeb) {
                        controller.showingOverlays = true;
                      }
                      GiphyGif? gif = await GiphyGet.getGif(
                        context: context,
                        apiKey: kIsWeb ? GIPHY_API_KEY : dotenv.get('GIPHY_API_KEY'),
                        tabColor: context.theme.primaryColor,
                        showEmojis: false,
                      );
                      if (kIsDesktop || kIsWeb) {
                        controller.showingOverlays = false;
                      }
                      if (gif?.images?.original != null) {
                        final response = await http.downloadFromUrl(gif!.images!.original!.url);
                        if (response.statusCode == 200) {
                          try {
                            final Uint8List data = response.data;
                            controller.pickedAttachments.add(PlatformFile(
                              path: null,
                              name: "${gif.title ?? randomString(8)}.gif",
                              size: data.length,
                              bytes: data,
                            ));
                            return;
                          } catch (_) {}
                        }
                      }
                    }),
              if (kIsDesktop && Platform.isWindows)
                IconButton(
                  icon: Icon(iOS ? CupertinoIcons.location_solid : Icons.location_on_outlined, color: context.theme.colorScheme.outline, size: 28),
                  onPressed: () async {
                    await Share.location(chat);
                  },
                ),
              Expanded(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.none,
                  children: [
                    TextFieldComponent(
                      key: controller.textFieldKey,
                      subjectTextController: controller.subjectTextController,
                      textController: controller.textController,
                      controller: controller,
                      recorderController: recorderController,
                      sendMessage: sendMessage,
                    ),
                    if (!kIsWeb)
                      Positioned(
                          top: 0,
                          bottom: 0,
                          child: Obx(() => AnimatedSize(
                                duration: const Duration(milliseconds: 500),
                                curve: controller.showRecording.value ? Curves.easeOutBack : Curves.easeOut,
                                child: !controller.showRecording.value
                                    ? const SizedBox.shrink()
                                    : Builder(builder: (context) {
                                        final box = controller.textFieldKey.currentContext?.findRenderObject() as RenderBox?;
                                        final textFieldSize = box?.size ?? const Size(250, 35);
                                        return AudioWaveforms(
                                          size: Size(textFieldSize.width - (samsung ? 0 : 80), textFieldSize.height - 15),
                                          recorderController: recorderController!,
                                          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 15),
                                          waveStyle: const WaveStyle(
                                            waveColor: Colors.white,
                                            waveCap: StrokeCap.square,
                                            spacing: 4.0,
                                            showBottom: true,
                                            extendWaveform: true,
                                            showMiddleLine: false,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.fromBorderSide(BorderSide(
                                              color: context.theme.colorScheme.outline,
                                              width: 1,
                                            )),
                                            borderRadius: BorderRadius.circular(20),
                                            color: context.theme.colorScheme.properSurface,
                                          ),
                                        );
                                      }),
                              ))),
                    SendAnimation(parentController: controller),
                  ],
                ),
              ),
              if (samsung)
                Padding(
                  padding: const EdgeInsets.only(right: 5.0),
                  child: TextFieldSuffix(
                    subjectTextController: controller.subjectTextController,
                    textController: controller.textController,
                    controller: controller,
                    recorderController: recorderController,
                    sendMessage: sendMessage,
                  ),
                ),
            ]),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeIn,
              alignment: Alignment.bottomCenter,
              child: !showAttachmentPicker
                  ? SizedBox(width: ns.width(context))
                  : AttachmentPicker(
                      controller: controller,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class TextFieldComponent extends StatelessWidget {
  const TextFieldComponent({
    Key? key,
    required this.subjectTextController,
    required this.textController,
    required this.controller,
    required this.recorderController,
    required this.sendMessage,
    this.focusNode,
    this.initialAttachments = const [],
  }) : super(key: key);

  final TextEditingController subjectTextController;
  final MentionTextEditingController textController;
  final ConversationViewController? controller;
  final RecorderController? recorderController;
  final Future<void> Function({String? effect}) sendMessage;
  final FocusNode? focusNode;

  final List<PlatformFile> initialAttachments;

  bool get iOS => ss.settings.skin.value == Skins.iOS;

  bool get samsung => ss.settings.skin.value == Skins.Samsung;

  Chat? get chat => controller?.chat;

  bool get isChatCreator => controller == null;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKey: (_, ev) => isChatCreator ? KeyEventResult.ignored : handleKey(_, ev, context),
      child: Padding(
        padding: const EdgeInsets.only(right: 5.0),
        child: Container(
          decoration: iOS
              ? BoxDecoration(
                  border: Border.fromBorderSide(BorderSide(
                    color: context.theme.colorScheme.properSurface,
                    width: 1.5,
                  )),
                  borderRadius: BorderRadius.circular(20),
                )
              : BoxDecoration(
                  color: context.theme.colorScheme.properSurface,
                  borderRadius: BorderRadius.circular(20),
                ),
          clipBehavior: Clip.antiAlias,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 400),
            alignment: Alignment.bottomCenter,
            curve: Curves.easeOutBack,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isChatCreator) ReplyHolder(controller: controller!),
                if (initialAttachments.isNotEmpty || !isChatCreator)
                  PickedAttachmentsHolder(
                    controller: controller,
                    textController: textController,
                    subjectTextController: controller?.subjectTextController ?? TextEditingController(),
                    initialAttachments: initialAttachments,
                  ),
                if (!isChatCreator)
                  Obx(() {
                    if (controller!.pickedAttachments.isNotEmpty && iOS) {
                      return Divider(
                        height: 1.5,
                        thickness: 1.5,
                        color: context.theme.colorScheme.properSurface,
                      );
                    }
                    return const SizedBox.shrink();
                  }),
                if (!isChatCreator && ss.settings.enablePrivateAPI.value && ss.settings.privateSubjectLine.value && chat!.isIMessage)
                  TextField(
                    textCapitalization: TextCapitalization.sentences,
                    focusNode: controller!.subjectFocusNode,
                    autocorrect: true,
                    controller: controller!.subjectTextController,
                    scrollPhysics: const CustomBouncingScrollPhysics(),
                    style: context.theme.extension<BubbleText>()!.bubbleText.copyWith(fontWeight: FontWeight.bold),
                    keyboardType: TextInputType.multiline,
                    maxLines: 14,
                    minLines: 1,
                    selectionControls: iOS ? cupertinoTextSelectionControls : materialTextSelectionControls,
                    enableIMEPersonalizedLearning: !ss.settings.incognitoKeyboard.value,
                    textInputAction: TextInputAction.next,
                    cursorColor: context.theme.colorScheme.primary,
                    cursorHeight: context.theme.extension<BubbleText>()!.bubbleText.fontSize! * 1.25,
                    decoration: InputDecoration(
                      contentPadding: EdgeInsets.all(iOS && !kIsDesktop && !kIsWeb ? 10 : 12.5),
                      isDense: true,
                      isCollapsed: true,
                      hintText: "Subject",
                      enabledBorder: InputBorder.none,
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      fillColor: Colors.transparent,
                      hintStyle: context.theme
                          .extension<BubbleText>()!
                          .bubbleText
                          .copyWith(color: context.theme.colorScheme.outline, fontWeight: FontWeight.bold),
                      suffixIconConstraints: const BoxConstraints(minHeight: 0),
                    ),
                    onTap: () {
                      HapticFeedback.selectionClick();
                    },
                    onSubmitted: (String value) {
                      controller!.subjectFocusNode.requestFocus();
                    },
                    // contentInsertionConfiguration: ContentInsertionConfiguration(onContentInserted: onContentCommit),
                  ),
                if (!isChatCreator && ss.settings.enablePrivateAPI.value && ss.settings.privateSubjectLine.value && chat!.isIMessage && iOS)
                  Divider(
                    height: 1.5,
                    thickness: 1.5,
                    indent: 10,
                    color: context.theme.colorScheme.properSurface,
                  ),
                TextField(
                  textCapitalization: TextCapitalization.sentences,
                  focusNode: controller?.focusNode,
                  autocorrect: true,
                  controller: textController,
                  scrollPhysics: const CustomBouncingScrollPhysics(),
                  style: context.theme.extension<BubbleText>()!.bubbleText,
                  keyboardType: TextInputType.multiline,
                  maxLines: 14,
                  minLines: 1,
                  autofocus: (kIsWeb || kIsDesktop) && !isChatCreator,
                  enableIMEPersonalizedLearning: !ss.settings.incognitoKeyboard.value,
                  textInputAction: ss.settings.sendWithReturn.value && !kIsWeb && !kIsDesktop ? TextInputAction.send : TextInputAction.newline,
                  cursorColor: context.theme.colorScheme.primary,
                  cursorHeight: context.theme.extension<BubbleText>()!.bubbleText.fontSize! * 1.25,
                  decoration: InputDecoration(
                    contentPadding: EdgeInsets.all(iOS && !kIsDesktop && !kIsWeb ? 10 : 12.5),
                    isDense: true,
                    isCollapsed: true,
                    hintText: isChatCreator
                        ? "New Message"
                        : ss.settings.recipientAsPlaceholder.value == true
                            ? chat!.getTitle()
                            : chat!.isTextForwarding
                                ? "Text Forwarding"
                                : "iMessage",
                    enabledBorder: InputBorder.none,
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                    hintStyle: context.theme.extension<BubbleText>()!.bubbleText.copyWith(color: context.theme.colorScheme.outline),
                    suffixIconConstraints: const BoxConstraints(minHeight: 0),
                    suffixIcon: samsung && !isChatCreator
                        ? null
                        : Padding(
                            padding: EdgeInsets.only(right: iOS ? 0.0 : 5.0),
                            child: TextFieldSuffix(
                              subjectTextController: subjectTextController,
                              textController: textController,
                              controller: controller,
                              recorderController: recorderController,
                              sendMessage: sendMessage,
                            ),
                          ),
                  ),
                  contextMenuBuilder: (BuildContext context, EditableTextState editableTextState) {
                    final start = editableTextState.textEditingValue.selection.start;
                    final end = editableTextState.textEditingValue.selection.end;
                    final text = editableTextState.textEditingValue.text;
                    final selected = editableTextState.textEditingValue.text.substring((start - 1).clamp(0, text.length), (end + 1).clamp(min(1, text.length), text.length));
                    return AdaptiveTextSelectionToolbar.editableText(
                      editableTextState: editableTextState,
                    )..buttonItems?.addAllIf(
                      MentionTextEditingController.escapingRegex.allMatches(selected).length == 1,
                      [
                        ContextMenuButtonItem(
                          onPressed: () {
                            final TextSelection selection = editableTextState.textEditingValue.selection;
                            if (selection.isCollapsed) {
                              return;
                            }
                            String text = editableTextState.textEditingValue.text;
                            final textPart = text.substring(0, (end + 1).clamp(1, text.length));
                            final mentionMatch = MentionTextEditingController.escapingRegex.allMatches(textPart).lastOrNull;
                            if (mentionMatch == null) return; // Shouldn't happen
                            final mentionText = textPart.substring(mentionMatch.start, mentionMatch.end);
                            int? mentionIndex = int.tryParse(mentionText.substring(1, mentionText.length - 1));
                            if (mentionIndex == null) return; // Shouldn't happen
                            final mention = controller?.mentionables[mentionIndex];
                            final replacement = mention != null ? "@${mention.displayName}" : "";
                            text = editableTextState.textEditingValue.text.replaceRange((start - 1).clamp(0, text.length), (end + 1).clamp(min(1, text.length), text.length), replacement);
                            final checkSpace = end + replacement.length - 1;
                            final spaceAfter = checkSpace < text.length && text.substring(end + replacement.length - 1, end + replacement.length) == " ";
                            controller?.textController.value = TextEditingValue(text: text, selection: TextSelection.fromPosition(TextPosition(offset: selection.baseOffset + replacement.length + (spaceAfter ? 1 : 0))));
                            editableTextState.hideToolbar();
                          },
                          label: "Remove Mention",
                        ),
                        ContextMenuButtonItem(
                          onPressed: () async {
                            final text = editableTextState.textEditingValue.text;
                            final textPart = text.substring(0, (end + 1).clamp(1, text.length));
                            final mentionMatch = MentionTextEditingController.escapingRegex.allMatches(textPart).lastOrNull;
                            if (mentionMatch == null) return; // Shouldn't happen
                            final mentionText = textPart.substring(mentionMatch.start, mentionMatch.end);
                            int? mentionIndex = int.tryParse(mentionText.substring(1, mentionText.length - 1));
                            if (mentionIndex == null) return; // Shouldn't happen
                            final mention = controller?.mentionables[mentionIndex];
                            final TextEditingController mentionController = TextEditingController(text: mention?.displayName);
                            String? changed;
                            if (kIsDesktop || kIsWeb) {
                              controller?.showingOverlays = true;
                            }
                            await showDialog(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  actions: [
                                    TextButton(
                                      child: Text("Cancel", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                                      onPressed: () => Get.back(),
                                    ),
                                    TextButton(
                                      child: Text("OK", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                                      onPressed: () {
                                        if (isNullOrEmptyString(mentionController.text)) {
                                          changed = mention?.handle.displayName ?? "";
                                        } else {
                                          changed = mentionController.text;
                                        }
                                        Get.back();
                                      },
                                    ),
                                  ],
                                  content: TextField(
                                    controller: mentionController,
                                    textCapitalization: TextCapitalization.sentences,
                                    autocorrect: true,
                                    scrollPhysics: const CustomBouncingScrollPhysics(),
                                    autofocus: true,
                                    enableIMEPersonalizedLearning: !ss.settings.incognitoKeyboard.value,
                                    decoration: InputDecoration(
                                      labelText: "Custom Mention",
                                      hintText: mention?.handle.displayName ?? "",
                                      border: const OutlineInputBorder(),
                                    ),
                                    onSubmitted: (val) {
                                      if (isNullOrEmptyString(val)) {
                                        val = mention?.handle.displayName ?? "";
                                      }
                                      changed = val;
                                      Get.back();
                                    },
                                  ),
                                  title: Text("Custom Mention", style: context.theme.textTheme.titleLarge),
                                  backgroundColor: context.theme.colorScheme.properSurface,
                                );
                              }
                            );
                            if (kIsDesktop || kIsWeb) {
                              controller?.showingOverlays = false;
                            }
                            if (!isNullOrEmpty(changed)! && mention != null) {
                              mention.customDisplayName = changed!;
                            }
                            final spaceAfter = end < text.length && text.substring(end, end + 1) == " ";
                            controller?.textController.selection = TextSelection.fromPosition(TextPosition(offset: end + (spaceAfter ? 1 : 0)));
                            editableTextState.hideToolbar();
                          },
                          label: "Custom Mention"
                        ),
                      ],
                    );
                  },
                  onTap: () {
                    HapticFeedback.selectionClick();
                  },
                  onSubmitted: (String value) {
                    controller?.focusNode.requestFocus();
                    if (isNullOrEmpty(value)! && (controller?.pickedAttachments.isEmpty ?? false)) return;
                    sendMessage.call();
                  },
                  // contentInsertionConfiguration: ContentInsertionConfiguration(onContentInserted: onContentCommit),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void onContentCommit(dynamic content) async {
    // Add some debugging logs
    Logger.info("[Content Commit] Keyboard received content");
    Logger.info("  -> Content Type: ${content.mimeType}");
    Logger.info("  -> URI: ${content.uri}");
    Logger.info("  -> Content Length: ${content.hasData ? content.data!.length : "null"}");

    // Parse the filename from the URI and read the data as a List<int>
    String filename = fs.uriToFilename(content.uri, content.mimeType);

    // Save the data to a location and add it to the file picker
    if (content.hasData) {
      controller?.pickedAttachments.add(PlatformFile(
        name: filename,
        size: content.data!.length,
        bytes: content.data,
      ));
    } else {
      showSnackbar('Insertion Failed', 'Attachment has no data!');
    }
  }

  KeyEventResult handleKey(FocusNode _, RawKeyEvent ev, BuildContext context) {
    if (ev is RawKeyDownEvent) {
      RawKeyEventDataWindows? windowsData;
      RawKeyEventDataLinux? linuxData;
      RawKeyEventDataWeb? webData;
      RawKeyEventDataAndroid? androidData;
      if (ev.data is RawKeyEventDataWindows) {
        windowsData = ev.data as RawKeyEventDataWindows;
      } else if (ev.data is RawKeyEventDataLinux) {
        linuxData = ev.data as RawKeyEventDataLinux;
      } else if (ev.data is RawKeyEventDataWeb) {
        webData = ev.data as RawKeyEventDataWeb;
      } else if (ev.data is RawKeyEventDataAndroid) {
        androidData = ev.data as RawKeyEventDataAndroid;
      }

      int maxShown = context.height / 3 ~/ 40;
      int upMovementIndex = maxShown ~/ 3;
      int downMovementIndex = maxShown * 2 ~/ 3;

      // Down arrow
      if (windowsData?.keyCode == 40 ||
          linuxData?.keyCode == 65364 ||
          webData?.code == "ArrowDown" ||
          androidData?.physicalKey == PhysicalKeyboardKey.arrowDown) {
        if (controller!.mentionSelectedIndex.value < controller!.mentionMatches.length - 1) {
          controller!.mentionSelectedIndex.value++;
          if (controller!.mentionSelectedIndex.value >= downMovementIndex &&
              controller!.mentionSelectedIndex < controller!.mentionMatches.length - maxShown + downMovementIndex + 1) {
            controller!.emojiScrollController
                .jumpTo(max((controller!.mentionSelectedIndex.value - downMovementIndex) * 40, controller!.emojiScrollController.offset));
          }
          return KeyEventResult.handled;
        }
        if (controller!.emojiSelectedIndex.value < controller!.emojiMatches.length - 1) {
          controller!.emojiSelectedIndex.value++;
          if (controller!.emojiSelectedIndex.value >= downMovementIndex &&
              controller!.emojiSelectedIndex < controller!.emojiMatches.length - maxShown + downMovementIndex + 1) {
            controller!.emojiScrollController
                .jumpTo(max((controller!.emojiSelectedIndex.value - downMovementIndex) * 40, controller!.emojiScrollController.offset));
          }
          return KeyEventResult.handled;
        }
      }

      // Up arrow
      if (windowsData?.keyCode == 38 ||
          linuxData?.keyCode == 65362 ||
          webData?.code == "ArrowUp" ||
          androidData?.physicalKey == PhysicalKeyboardKey.arrowUp) {
        if (controller!.mentionSelectedIndex.value > 0) {
          controller!.mentionSelectedIndex.value--;
          if (controller!.mentionSelectedIndex.value >= upMovementIndex &&
              controller!.mentionSelectedIndex < controller!.mentionMatches.length - maxShown + upMovementIndex + 1) {
            controller!.emojiScrollController
                .jumpTo(min((controller!.mentionSelectedIndex.value - upMovementIndex) * 40, controller!.emojiScrollController.offset));
          }
          return KeyEventResult.handled;
        }
        if (controller!.emojiSelectedIndex.value > 0) {
          controller!.emojiSelectedIndex.value--;
          if (controller!.emojiSelectedIndex.value >= upMovementIndex &&
              controller!.emojiSelectedIndex < controller!.emojiMatches.length - maxShown + upMovementIndex + 1) {
            controller!.emojiScrollController
                .jumpTo(min((controller!.emojiSelectedIndex.value - upMovementIndex) * 40, controller!.emojiScrollController.offset));
          }
          return KeyEventResult.handled;
        }
      }

      // Tab or Enter
      if (windowsData?.keyCode == 9 ||
          linuxData?.keyCode == 65289 ||
          webData?.code == "Tab" ||
          androidData?.physicalKey == PhysicalKeyboardKey.tab ||
          windowsData?.keyCode == 13 ||
          linuxData?.keyCode == 65293 ||
          webData?.code == "Enter" ||
          androidData?.physicalKey == PhysicalKeyboardKey.enter) {
        if (controller!.focusNode.hasPrimaryFocus && controller!.mentionMatches.length > controller!.mentionSelectedIndex.value) {
          int index = controller!.mentionSelectedIndex.value;
          TextEditingController textField =
          controller!.subjectFocusNode.hasPrimaryFocus ? controller!.subjectTextController : controller!.textController;
          String text = textField.text;
          RegExp regExp = RegExp(r"@(?:[^@ \n]+|$)(?=[ \n]|$)", multiLine: true);
          Iterable<RegExpMatch> matches = regExp.allMatches(text);
          if (matches.isNotEmpty && matches.any((m) => m.start < textField.selection.start)) {
            RegExpMatch match = matches.lastWhere((m) => m.start < textField.selection.start);
            controller!.textController.addMention(text.substring(match.start, match.end), controller!.mentionMatches[index]);
          } else {
            // If the user moved the cursor before trying to insert a mention, reset the picker
            controller!.emojiScrollController.jumpTo(0);
          }
          controller!.mentionSelectedIndex.value = 0;
          controller!.mentionMatches.value = <Mentionable>[];

          return KeyEventResult.handled;
        }
        if (controller!.emojiMatches.length > controller!.emojiSelectedIndex.value) {
          int index = controller!.emojiSelectedIndex.value;
          TextEditingController textField =
              controller!.subjectFocusNode.hasPrimaryFocus ? controller!.subjectTextController : controller!.textController;
          String text = textField.text;
          RegExp regExp = RegExp(r":[^: \n]+([ \n:]|$)", multiLine: true);
          Iterable<RegExpMatch> matches = regExp.allMatches(text);
          if (matches.isNotEmpty && matches.any((m) => m.start < textField.selection.start)) {
            RegExpMatch match = matches.lastWhere((m) => m.start < textField.selection.start);
            String char = controller!.emojiMatches[index].char;
            String _text = "${text.substring(0, match.start)}$char ${text.substring(match.end)}";
            textField.value = TextEditingValue(text: _text, selection: TextSelection.fromPosition(TextPosition(offset: match.start + char.length + 1)));
          } else {
            // If the user moved the cursor before trying to insert an emoji, reset the picker
            controller!.emojiScrollController.jumpTo(0);
          }
          controller!.emojiSelectedIndex.value = 0;
          controller!.emojiMatches.value = <Emoji>[];

          return KeyEventResult.handled;
        }
        if (ss.settings.privateSubjectLine.value) {
          if (windowsData?.keyCode == 9 ||
              linuxData?.keyCode == 65289 ||
              webData?.code == "Tab" ||
              androidData?.physicalKey == PhysicalKeyboardKey.tab) {
            // Tab to switch between text fields
            if (!ev.isShiftPressed && controller!.subjectFocusNode.hasPrimaryFocus) {
              controller!.focusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (ev.isShiftPressed && controller!.focusNode.hasPrimaryFocus) {
              controller!.subjectFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
          }
        }
      }

      // Escape
      if (windowsData?.keyCode == 27 ||
          linuxData?.keyCode == 65307 ||
          webData?.code == "Escape" ||
          androidData?.physicalKey == PhysicalKeyboardKey.escape) {
        if (controller!.mentionMatches.isNotEmpty) {
          controller!.mentionMatches.value = <Mentionable>[];
          return KeyEventResult.handled;
        }
        if (controller!.emojiMatches.isNotEmpty) {
          controller!.emojiMatches.value = <Emoji>[];
          return KeyEventResult.handled;
        }
        if (controller!.replyToMessage != null) {
          controller!.replyToMessage = null;
          return KeyEventResult.handled;
        }
      }
    }

    if (ev is! RawKeyDownEvent) return KeyEventResult.ignored;
    RawKeyEventDataWindows? windowsData;
    RawKeyEventDataLinux? linuxData;
    RawKeyEventDataWeb? webData;
    if (ev.data is RawKeyEventDataWindows) {
      windowsData = ev.data as RawKeyEventDataWindows;
    } else if (ev.data is RawKeyEventDataLinux) {
      linuxData = ev.data as RawKeyEventDataLinux;
    } else if (ev.data is RawKeyEventDataWeb) {
      webData = ev.data as RawKeyEventDataWeb;
    }
    if ((windowsData?.keyCode == 13 || linuxData?.keyCode == 65293 || webData?.code == "Enter") && !ev.isShiftPressed) {
      sendMessage();
      controller!.focusNode.requestFocus();
      return KeyEventResult.handled;
    }

    if (windowsData != null) {
      if ((windowsData.physicalKey == PhysicalKeyboardKey.keyV || windowsData.logicalKey == LogicalKeyboardKey.keyV) && (ev.isControlPressed)) {
        Pasteboard.image.then((image) {
          if (image != null) {
            controller!.pickedAttachments.add(PlatformFile(
              name: "${randomString(8)}.png",
              bytes: image,
              size: image.length,
            ));
          }
        });
      }
    }

    if (linuxData != null) {
      if ((linuxData.physicalKey == PhysicalKeyboardKey.keyV || linuxData.logicalKey == LogicalKeyboardKey.keyV) && (ev.isControlPressed)) {
        Pasteboard.image.then((image) {
          if (image != null) {
            controller!.pickedAttachments.add(PlatformFile(
              name: "${randomString(8)}.png",
              bytes: image,
              size: image.length,
            ));
          }
        });
      }
    }

    if (webData != null) {
      if ((webData.physicalKey == PhysicalKeyboardKey.keyV || webData.logicalKey == LogicalKeyboardKey.keyV) && (ev.isControlPressed)) {
        Pasteboard.image.then((image) {
          if (image != null) {
            controller!.pickedAttachments.add(PlatformFile(
              name: "${randomString(8)}.png",
              bytes: image,
              size: image.length,
            ));
          }
        });
      }
      return KeyEventResult.ignored;
    }
    if (kIsDesktop || kIsWeb) return KeyEventResult.ignored;
    if (ev.physicalKey == PhysicalKeyboardKey.enter && ss.settings.sendWithReturn.value) {
      if (!isNullOrEmpty(textController.text)! || !isNullOrEmpty(controller!.subjectTextController.text)!) {
        sendMessage();
        controller!.focusNode.previousFocus(); // I genuinely don't know why this works
        return KeyEventResult.handled;
      } else {
        controller!.subjectTextController.text = "";
        textController.text = ""; // Stop pressing physical enter with enterIsSend from creating newlines
        controller!.focusNode.previousFocus(); // I genuinely don't know why this works
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}
