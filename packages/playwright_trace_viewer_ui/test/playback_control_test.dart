// Part of the Dart port of the Playwright trace viewer UI.

/// The arithmetic behind the playback scrubber.
///
/// Dragging the scrubber picks an action by time, and picking the wrong one is
/// invisible: the panel still fills in, just with the neighbour's data. These
/// tests pin the two decisions upstream makes -- round to the *nearest* action
/// rather than the previous one, and never leave the selected time window.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:playwright_trace_viewer_ui/src/ui/playback_math.dart';
import 'package:test/test.dart';

/// Actions at the given start times, which is all this arithmetic reads.
List<ActionEntry> actionsAt(List<double> startTimes) => [
      for (var i = 0; i < startTimes.length; i++)
        ActionEntry(
          callId: 'call@$i',
          startTime: startTimes[i],
          endTime: startTimes[i],
          className: 'Frame',
          method: 'click',
          params: const <String, dynamic>{},
        ),
    ];

int indexAt(List<ActionEntry> actions, double time, {int? first, int? last}) =>
    actionIndexAtTime(actions, time,
        firstIndex: first ?? 0, lastIndex: last ?? actions.length - 1);

void main() {
  group('actionIndexAtTime', () {
    final actions = actionsAt([0, 100, 200, 300]);

    test('Deve devolver -1 para uma lista vazia', () {
      expect(indexAt(const [], 10), -1);
    });

    test('Deve acertar o tempo exato de cada acao', () {
      for (var i = 0; i < actions.length; i++) {
        expect(indexAt(actions, actions[i].startTime), i);
      }
    });

    test('Deve arredondar para a acao mais proxima, nao para a anterior', () {
      // 140 esta mais perto de 100; 160, de 200. Uma busca binaria crua
      // devolveria a anterior nos dois casos.
      expect(indexAt(actions, 140), 1);
      expect(indexAt(actions, 160), 2);
    });

    test('Deve desempatar pela anterior no ponto medio', () {
      // Em 150 as distancias sao iguais, e o upstream so troca quando a
      // proxima esta estritamente mais perto.
      expect(indexAt(actions, 150), 1);
    });

    test('Deve prender nas pontas fora do intervalo', () {
      expect(indexAt(actions, -1000), 0);
      expect(indexAt(actions, 99999), 3);
    });

    test('Deve respeitar a janela de tempo selecionada', () {
      // Com a janela em [1, 2], um clique no comeco nao pode sair dela.
      expect(indexAt(actions, 0, first: 1, last: 2), 1);
      expect(indexAt(actions, 99999, first: 1, last: 2), 2);
      expect(indexAt(actions, 200, first: 1, last: 2), 2);
    });

    test('Deve funcionar com uma acao so', () {
      final uma = actionsAt([500]);
      expect(indexAt(uma, 0), 0);
      expect(indexAt(uma, 500), 0);
      expect(indexAt(uma, 100000), 0);
    });

    test('Deve tolerar acoes que comecam no mesmo instante', () {
      final iguais = actionsAt([0, 100, 100, 100, 200]);
      // Qualquer uma das tres serve; o que nao pode e sair do bloco.
      expect(indexAt(iguais, 100), inInclusiveRange(1, 3));
    });
  });

  group('playbackTicks', () {
    const boundaries = (minimum: 0.0, maximum: 1000.0);

    test('Deve devolver nulo sem acao nenhuma', () {
      expect(playbackTicks(const [], boundaries), isNull);
    });

    test('Deve posicionar cada acao em porcentagem do intervalo', () {
      expect(playbackTicks(actionsAt([0, 250, 500, 1000]), boundaries),
          [0.0, 25.0, 50.0, 100.0]);
    });

    test('Deve descontar o inicio do intervalo', () {
      expect(
          playbackTicks(
              actionsAt([100, 600]), (minimum: 100.0, maximum: 1100.0)),
          [0.0, 50.0]);
    });

    test('Deve desistir de desenhar acima de duzentas acoes', () {
      // O limite e do upstream: passando dele os tracos viram uma barra.
      final duzentas = actionsAt([for (var i = 0; i < 200; i++) i * 5.0]);
      expect(playbackTicks(duzentas, boundaries), hasLength(200));
      final duzentasEUma = actionsAt([for (var i = 0; i < 201; i++) i * 5.0]);
      expect(playbackTicks(duzentasEUma, boundaries), isNull);
    });

    test('Deve sobreviver a um intervalo de duracao zero', () {
      // Um trace de uma acao so: dividir pela duracao daria NaN, e o estilo
      // `left: NaN%` some com o traco sem erro nenhum no console.
      final ticks = playbackTicks(actionsAt([5]), (minimum: 5.0, maximum: 5.0));
      expect(ticks, [0.0]);
      expect(ticks!.single.isNaN, isFalse);
    });
  });
}
