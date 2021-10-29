import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/blocs/message_bloc.dart';
import 'package:bluebubbles/helpers/constants.dart';
import 'package:bluebubbles/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/reaction.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/group_event.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/message_content/media_players/url_preview_widget.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/message_content/message_attachments.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/message_content/message_time_stamp_separator.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/reactions_widget.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/received_message.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/sent_message.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/stickers_widget.dart';
import 'package:bluebubbles/managers/current_chat.dart';
import 'package:bluebubbles/managers/event_dispatcher.dart';
import 'package:bluebubbles/managers/new_message_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/handle.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:get/get_state_manager/src/rx_flutter/rx_obx_widget.dart';
import 'package:get/get_utils/src/extensions/context_extensions.dart';

class MessageWidget extends StatefulWidget {
  MessageWidget({
    Key? key,
    required this.message,
    required this.olderMessage,
    required this.newerMessage,
    required this.showHandle,
    required this.isFirstSentMessage,
    required this.showHero,
    required this.showReplies,
    this.onUpdate,
    this.bloc,
    required this.autoplayEffect,
  }) : super(key: key);

  final Message message;
  final Message? newerMessage;
  final Message? olderMessage;
  final bool showHandle;
  final bool isFirstSentMessage;
  final bool showHero;
  final bool showReplies;
  final Message? Function(NewMessageEvent event)? onUpdate;
  final MessageBloc? bloc;
  final bool autoplayEffect;

  @override
  _MessageState createState() => _MessageState();
}

class _MessageState extends State<MessageWidget> {
  bool showTail = true;
  Completer<void>? associatedMessageRequest;
  Completer<void>? attachmentsRequest;
  Completer<void>? handleRequest;
  int lastRequestCount = -1;
  int attachmentCount = 0;
  int associatedCount = 0;
  CurrentChat? currentChat;
  StreamSubscription<NewMessageEvent>? subscription;
  late Message _message;
  Message? _newerMessage;
  Message? _olderMessage;
  RxBool tapped = false.obs;
  double baseOffset = 0;
  RxDouble offset = 0.0.obs;
  bool gaveHapticFeedback = false;

  @override
  void initState() {
    super.initState();
    currentChat = CurrentChat.activeChat;
    _message = widget.message;
    _newerMessage = widget.newerMessage;
    _olderMessage = widget.olderMessage;
    init();
  }

  void init() {
    checkHandle();
    fetchAssociatedMessages();
    fetchAttachments();

    // If we already are listening to the stream, no need to do it again
    if (subscription != null) return;

    // Listen for new messages
    subscription = NewMessageManager().stream.listen((data) {
      // If the message doesn't apply to this chat, ignore it
      if (data.chatGuid != currentChat?.chat.guid) return;

      if (data.type == NewMessageType.ADD) {
        // Check if the new message has an associated GUID that matches this message
        bool fetchAssoc = false;
        bool fetchAttach = false;
        Message? message = data.event["message"];
        if (message == null) return;
        if (message.associatedMessageGuid == widget.message.guid) fetchAssoc = true;
        if (message.hasAttachments) fetchAttach = true;

        if (kIsWeb && message.associatedMessageGuid != null) {
          // someone removed their reaction (remove original)
          if (message.associatedMessageType!.startsWith("-") &&
              ReactionTypes.toList().contains(message.associatedMessageType!.replaceAll("-", ""))) {
            MapEntry? entry = widget.bloc?.reactionMessages.entries.firstWhereOrNull((entry) =>
                entry.value.handle?.address == message.handle?.address &&
                entry.value.associatedMessageType == message.associatedMessageType!.replaceAll("-", ""));
            if (entry != null) widget.bloc?.reactionMessages.remove(entry.key);
            // someone changed their reaction (remove original and add new)
          } else if (widget.bloc?.reactionMessages.entries.firstWhereOrNull((e) =>
                      e.value.associatedMessageGuid == message.associatedMessageGuid &&
                      e.value.handle?.address == message.handle?.address) !=
                  null &&
              ReactionTypes.toList().contains(message.associatedMessageType)) {
            MapEntry? entry = widget.bloc?.reactionMessages.entries.firstWhereOrNull((e) =>
                e.value.associatedMessageGuid == message.associatedMessageGuid &&
                e.value.handle?.address == message.handle?.address);
            if (entry != null) widget.bloc?.reactionMessages.remove(entry.key);
            widget.bloc?.reactionMessages[message.guid!] = message;
            // we have a fresh reaction (add new)
          } else if (widget.bloc?.reactionMessages[message.guid!] == null &&
              ReactionTypes.toList().contains(message.associatedMessageType)) {
            widget.bloc?.reactionMessages[message.guid!] = message;
          }
        }

        // If the associated message GUID matches this one, fetch associated messages
        if (fetchAssoc) fetchAssociatedMessages(forceReload: true);
        if (fetchAttach) fetchAttachments(forceReload: true);
      } else if (data.type == NewMessageType.UPDATE) {
        String? oldGuid = data.event["oldGuid"];
        // If the guid does not match our current guid, then it's not meant for us
        if (oldGuid != _message.guid && oldGuid != _newerMessage?.guid) return;

        // Tell the [MessagesView] to update with the new event, to ensure that things are done synchronously
        if (widget.onUpdate != null) {
          Message? result = widget.onUpdate!(data);
          if (result != null) {
            if (mounted) {
              setState(() {
                if (_message.guid == oldGuid) {
                  _message = result;
                } else if (_newerMessage!.guid == oldGuid) {
                  _newerMessage = result;
                }
              });
            }
          }
        }
      }
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  Future<void> checkHandle() async {
    // If we've already started, return the request
    if (handleRequest != null) return handleRequest!.future;
    handleRequest = Completer();

    // Checks ordered in a specific way to ever so slightly reduce processing
    if (_message.isFromMe!) return handleRequest!.complete();
    if (_message.handle != null) return handleRequest!.complete();

    try {
      Handle? handle = await _message.getHandle();
      if (mounted && handle != null) {
        setState(() {});
      }
    } catch (ex) {
      handleRequest!.completeError(ex);
    }
  }

  Future<void> fetchAssociatedMessages({bool forceReload = false}) async {
    // If there is already a request being made, return that request
    if (!forceReload && associatedMessageRequest != null) return associatedMessageRequest!.future;

    // Create a new request and get the messages
    associatedMessageRequest = Completer();

    try {
      await _message.fetchAssociatedMessages(bloc: widget.bloc);
    } catch (ex) {
      return associatedMessageRequest!.completeError(ex);
    }

    bool hasChanges = false;
    if (_message.associatedMessages.length != associatedCount || forceReload) {
      associatedCount = _message.associatedMessages.length;
      hasChanges = true;
    }

    // If there are changes, re-render
    if (hasChanges) {
      // If we don't think there are reactions, and we found reactions,
      // Update the DB so it saves that we have reactions
      if (!_message.hasReactions && _message.getReactions().isNotEmpty) {
        _message.hasReactions = true;
        _message.update();
      }

      if (mounted) setState(() {});
    }

    associatedMessageRequest!.complete();
  }

  Future<void> fetchAttachments({bool forceReload = false}) async {
    // If there is already a request being made, return that request
    if (!forceReload && attachmentsRequest != null) return attachmentsRequest!.future;

    // Create a new request and get the attachments
    attachmentsRequest = Completer();
    if (!mounted) return attachmentsRequest!.complete();

    try {
      await _message.fetchAttachments(currentChat: currentChat);
    } catch (ex) {
      return attachmentsRequest!.completeError(ex);
    }

    bool hasChanges = false;
    if (_message.attachments.length != attachmentCount || forceReload) {
      attachmentCount = _message.attachments.length;
      hasChanges = true;
    }

    // NOTE: Not sure if we need to re-render
    if (mounted && hasChanges) {
      setState(() {});
    }

    if (!attachmentsRequest!.isCompleted) attachmentsRequest!.complete();
  }

  @override
  Widget build(BuildContext context) {
    if (_newerMessage != null) {
      if (_newerMessage!.isGroupEvent()) {
        showTail = true;
      } else if (SettingsManager().settings.skin.value == Skins.Samsung) {
        showTail = MessageHelper.getShowTail(context, _message, _olderMessage);
      } else {
        showTail = MessageHelper.getShowTail(context, _message, _newerMessage);
      }
    }

    if (_message.isGroupEvent()) {
      return GroupEvent(key: Key("group-event-${_message.guid}"), message: _message);
    }

    ////////// READ //////////
    /// This widget and code below will handle building out the following:
    /// -> Attachments
    /// -> Reactions
    /// -> Stickers
    /// -> URL Previews
    /// -> Big Emojis??
    ////////// READ //////////

    // Build the attachments widget
    Widget widgetAttachments = MessageAttachments(
      message: _message,
      showTail: showTail,
      showHandle: widget.showHandle,
    );

    UrlPreviewWidget urlPreviewWidget = UrlPreviewWidget(
        key: Key("preview-${_message.guid}"), linkPreviews: _message.getPreviewAttachments(), message: _message);
    StickersWidget stickersWidget =
        StickersWidget(key: Key("stickers-${associatedCount.toString()}"), messages: _message.associatedMessages);
    ReactionsWidget reactionsWidget = ReactionsWidget(
        key: Key("reactions-${associatedCount.toString()}"), associatedMessages: _message.associatedMessages);
    final separator = MessageTimeStampSeparator(
      newerMessage: _message,
      message: _olderMessage ?? _message,
    );
    final separator2 = MessageTimeStampSeparator(
      newerMessage: _newerMessage,
      message: _message,
    );

    // Add the correct type of message to the message stack
    return Obx(
      () {
        Widget message;
        bool _tapped = tapped.value;
        if (_message.isFromMe!) {
          message = SentMessage(
            showTail: showTail,
            olderMessage: widget.olderMessage,
            newerMessage: widget.newerMessage,
            message: _message,
            messageBloc: widget.bloc,
            hasTimestampAbove: separator.buildTimeStamp().isNotEmpty,
            hasTimestampBelow: separator2.buildTimeStamp().isNotEmpty,
            showReplies: widget.showReplies,
            urlPreviewWidget: urlPreviewWidget,
            stickersWidget: stickersWidget,
            attachmentsWidget: widgetAttachments,
            reactionsWidget: reactionsWidget,
            shouldFadeIn: currentChat?.sentMessages.firstWhereOrNull((e) => e?.guid == _message.guid) != null,
            showHero: widget.showHero,
            showDeliveredReceipt: widget.isFirstSentMessage || _tapped,
            autoplayEffect: widget.autoplayEffect,
          );
        } else {
          message = ReceivedMessage(
            showTail: showTail,
            olderMessage: widget.olderMessage,
            newerMessage: widget.newerMessage,
            message: _message,
            messageBloc: widget.bloc,
            hasTimestampAbove: separator.buildTimeStamp().isNotEmpty,
            hasTimestampBelow: separator2.buildTimeStamp().isNotEmpty,
            showReplies: widget.showReplies,
            showHandle: widget.showHandle,
            urlPreviewWidget: urlPreviewWidget,
            stickersWidget: stickersWidget,
            attachmentsWidget: widgetAttachments,
            reactionsWidget: reactionsWidget,
            showTimeStamp: _tapped,
            autoplayEffect: widget.autoplayEffect,
          );
        }

        double replyThreshold = 40;

        return Obx(
          () => GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onTap: kIsDesktop || kIsWeb ? () => tapped.value = !tapped.value : null,
            onHorizontalDragStart: (details) {
              baseOffset = details.localPosition.dx;
            },
            onHorizontalDragUpdate: (details) {
              offset.value = min(max((details.localPosition.dx - baseOffset) * (_message.isFromMe! ? -1 : 1), 0), replyThreshold * 1.5);
              if (!gaveHapticFeedback && offset.value >= replyThreshold) {
                HapticFeedback.lightImpact();
                gaveHapticFeedback = true;
              } else if (offset.value < replyThreshold) {
                gaveHapticFeedback = false;
              }
              CurrentChat.of(context)?.setReplyOffset(_message.guid ?? "", offset.value);
            },
            onHorizontalDragEnd: (details) {
              if (offset.value >= replyThreshold) {
                EventDispatcher().emit("focus-keyboard", _message);
              }
              offset.value = 0;
              CurrentChat.of(context)?.setReplyOffset(_message.guid ?? "", offset.value);
            },
            child: AnimatedContainer(
              duration: Duration(milliseconds: offset.value == 0 ? 150 : 0),
              padding: _message.isFromMe!
                  ? EdgeInsets.only(
                      right: max(0, offset.value),
                    )
                  : EdgeInsets.only(
                      left: max(0, offset.value),
                    ),
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: <Widget>[
                      AnimatedPositioned(
                        duration: Duration(milliseconds: offset.value == 0 ? 150 : 0),
                        left: !_message.isFromMe! ? -offset.value * 0.8 : null,
                        right: _message.isFromMe! ? -offset.value * 0.8 : null,
                        child: AnimatedContainer(
                          duration: Duration(milliseconds: offset.value == 0 ? 150 : 0),
                          width: min(replyThreshold, offset.value) * 0.8,
                          height: min(replyThreshold, offset.value) * 0.8,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(
                              Radius.circular(
                                min(replyThreshold, offset.value) * 0.4,
                              ),
                            ),
                            color: context.theme.accentColor,
                          ),
                          child: AnimatedScale(
                            scale: min(replyThreshold, offset.value) * (offset.value >= replyThreshold ? 0.5 : 0.4),
                            duration: Duration(milliseconds: offset.value == 0 ? 150 : 0),
                            child: Icon(SettingsManager().settings.skin.value == Skins.iOS ? CupertinoIcons.reply : Icons.reply,
                            size: 1,
                            color: context.textTheme.headline1!.color,),
                          ),
                        ),
                      ),
                      message,
                    ],
                  ),
                  separator2,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
