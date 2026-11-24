import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/presentation/widgets/now_playing_queue_view.dart';

void main() {
  testWidgets('phone handle drags up and down without playing a song', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final songs = ['First', 'Second', 'Third'];
    var songTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: songs.length,
              itemExtent: 64,
              onReorder: (from, to) => setState(() {
                songs.insert(to > from ? to - 1 : to, songs.removeAt(from));
              }),
              itemBuilder: (context, index) => ListTile(
                key: ValueKey(songs[index]),
                title: Text(songs[index]),
                onTap: () => songTaps++,
                trailing: QueueReorderHandle(
                  key: ValueKey('handle-${songs[index]}'),
                  index: index,
                  label: songs[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> dragThirdTo(Offset destination) async {
      final origin = tester.getCenter(
        find.byKey(const ValueKey('handle-Third')),
      );
      final gesture = await tester.startGesture(origin);
      for (var step = 1; step <= 12; step++) {
        await gesture.moveTo(Offset.lerp(origin, destination, step / 12)!);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final first = tester.getCenter(find.byKey(const ValueKey('handle-First')));
    await dragThirdTo(first - const Offset(0, 24));
    expect(songs, ['Third', 'First', 'Second']);
    expect(songTaps, 0);
    final last = tester.getCenter(find.byKey(const ValueKey('handle-Second')));
    await dragThirdTo(last + const Offset(0, 40));
    expect(songs, ['First', 'Second', 'Third']);
    expect(songTaps, 0);
    expect(tester.takeException(), isNull);
  });
}
