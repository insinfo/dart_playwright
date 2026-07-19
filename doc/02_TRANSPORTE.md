# 02 — Camada de Transporte

## 1. Visão Geral

O Playwright usa dois mecanismos de transporte para comunicação com navegadores:

1. **PipeTransport** — Comunicação via stdin/stdout do processo do navegador
2. **WebSocketTransport** — Comunicação via WebSocket (para conexão remota)

Ambos implementam a interface `ConnectionTransport`.

---

## 2. Interface ConnectionTransport

### 2.1. TypeScript Original

```typescript
// packages/playwright-core/src/server/transport.ts

export type ProtocolRequest = {
  id: number;
  method: string;
  params: any;
  sessionId?: string;
};

export type ProtocolResponse = {
  id?: number;
  method?: string;
  sessionId?: string;
  error?: { message: string; data: any; code?: number };
  params?: any;
  result?: any;
  pageProxyId?: string;       // WebKit specific
  browserContextId?: string;  // WebKit specific
};

export interface ConnectionTransport {
  send(s: ProtocolRequest): void;
  close(): void;
  onmessage?: (message: ProtocolResponse) => void;
  onclose?: (reason?: string) => void;
}
```

### 2.2. Port para Dart

```dart
// lib/src/transport/transport.dart

/// Requisição do protocolo do navegador
class ProtocolRequest {
  final int id;
  final String method;
  final Map<String, dynamic>? params;
  final String? sessionId;
  
  ProtocolRequest({
    required this.id,
    required this.method,
    this.params,
    this.sessionId,
  });
  
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'method': method,
    };
    if (params != null) json['params'] = params;
    if (sessionId != null) json['sessionId'] = sessionId;
    return json;
  }
}

/// Resposta do protocolo do navegador
class ProtocolResponse {
  final int? id;
  final String? method;
  final String? sessionId;
  final ProtocolError? error;
  final Map<String, dynamic>? params;
  final Map<String, dynamic>? result;
  final String? pageProxyId;        // WebKit specific
  final String? browserContextId;   // WebKit specific
  
  ProtocolResponse({
    this.id,
    this.method,
    this.sessionId,
    this.error,
    this.params,
    this.result,
    this.pageProxyId,
    this.browserContextId,
  });
  
  factory ProtocolResponse.fromJson(Map<String, dynamic> json) {
    return ProtocolResponse(
      id: json['id'] as int?,
      method: json['method'] as String?,
      sessionId: json['sessionId'] as String?,
      error: json['error'] != null 
          ? ProtocolError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
      params: json['params'] as Map<String, dynamic>?,
      result: json['result'] as Map<String, dynamic>?,
      pageProxyId: json['pageProxyId'] as String?,
      browserContextId: json['browserContextId'] as String?,
    );
  }
}

class ProtocolError {
  final String message;
  final dynamic data;
  final int? code;
  
  ProtocolError({required this.message, this.data, this.code});
  
  factory ProtocolError.fromJson(Map<String, dynamic> json) {
    return ProtocolError(
      message: json['message'] as String,
      data: json['data'],
      code: json['code'] as int?,
    );
  }
}

/// Interface abstrata para transporte de protocolo
abstract class ConnectionTransport {
  /// Enviar mensagem para o navegador
  void send(ProtocolRequest message);
  
  /// Fechar a conexão
  Future<void> close();
  
  /// Stream de mensagens recebidas do navegador
  Stream<ProtocolResponse> get onMessage;
  
  /// Stream de evento de fechamento
  Stream<String?> get onClose;
}
```

---

## 3. PipeTransport — Comunicação via Stdio

### 3.1. Como funciona

O navegador é lançado com flags especiais:
- **Chromium**: `--remote-debugging-pipe` → usa file descriptors 3 e 4
- **Firefox**: pipes stdio (stdin/stdout do processo)
- **WebKit**: pipes stdio do processo

As mensagens são separadas pelo caractere **null byte** (`\0`).

### 3.2. TypeScript Original

```typescript
// packages/playwright-core/src/server/pipeTransport.ts

export class PipeTransport implements ConnectionTransport {
  private _pipeRead: NodeJS.ReadableStream;
  private _pipeWrite: NodeJS.WritableStream;
  private _pendingBuffers: Buffer[] = [];
  
  constructor(pipeWrite: NodeJS.WritableStream, pipeRead: NodeJS.ReadableStream) {
    this._pipeRead = pipeRead;
    this._pipeWrite = pipeWrite;
    pipeRead.on('data', buffer => this._dispatch(buffer));
    pipeRead.on('close', () => { /* ... */ });
  }
  
  send(message: ProtocolRequest) {
    this._pipeWrite.write(JSON.stringify(message));
    this._pipeWrite.write('\0');
  }
  
  _dispatch(buffer: Buffer) {
    let end = buffer.indexOf('\0');
    if (end === -1) {
      this._pendingBuffers.push(buffer);
      return;
    }
    // ... parse null-separated JSON messages
  }
}
```

### 3.3. Port para Dart

```dart
// lib/src/transport/pipe_transport.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Transporte via pipe stdin/stdout do processo do navegador.
///
/// As mensagens são JSON separadas por null byte (\0).
/// Usado quando o navegador é lançado localmente.
class PipeTransport implements ConnectionTransport {
  final IOSink _pipeWrite;
  final Stream<List<int>> _pipeRead;
  
  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();
  
  final _pendingChunks = <List<int>>[];
  bool _closed = false;
  late final StreamSubscription<List<int>> _readSubscription;
  
  PipeTransport({
    required IOSink pipeWrite,
    required Stream<List<int>> pipeRead,
  })  : _pipeWrite = pipeWrite,
        _pipeRead = pipeRead {
    _readSubscription = _pipeRead.listen(
      _dispatch,
      onDone: () {
        _closed = true;
        _closeController.add(null);
        _closeController.close();
        _messageController.close();
      },
      onError: (error) {
        // Log error but don't crash
        _logger.warning('Pipe read error: $error');
      },
    );
  }
  
  /// Criar PipeTransport a partir de um Process
  /// 
  /// Para Chromium com --remote-debugging-pipe:
  ///   O Chromium usa file descriptors 3 (write) e 4 (read),
  ///   mas no Dart acessamos via stdio do processo.
  /// 
  /// Para Firefox/WebKit:
  ///   Usam stdin/stdout diretamente.
  factory PipeTransport.fromProcess(Process process) {
    return PipeTransport(
      pipeWrite: process.stdin,
      pipeRead: process.stdout,
    );
  }
  
  @override
  void send(ProtocolRequest message) {
    if (_closed) throw StateError('Pipe has been closed');
    
    final jsonStr = jsonEncode(message.toJson());
    _pipeWrite.write(jsonStr);
    _pipeWrite.write('\x00'); // null byte separator
  }
  
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _readSubscription.cancel();
    await _pipeWrite.close();
    _closeController.add(null);
    await _closeController.close();
    await _messageController.close();
  }
  
  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;
  
  @override
  Stream<String?> get onClose => _closeController.stream;
  
  /// Despachar buffer recebido, separando por null bytes
  void _dispatch(List<int> buffer) {
    // Procurar null bytes no buffer
    int start = 0;
    
    for (int i = 0; i < buffer.length; i++) {
      if (buffer[i] == 0) { // null byte found
        // Adicionar a parte antes do null byte aos chunks pendentes
        if (i > start) {
          _pendingChunks.add(buffer.sublist(start, i));
        }
        
        // Concatenar todos os chunks em uma mensagem completa
        final completeMessage = _concatenateChunks();
        _pendingChunks.clear();
        
        // Parse e dispatch
        try {
          final jsonStr = utf8.decode(completeMessage);
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          final response = ProtocolResponse.fromJson(json);
          
          // Schedulemicrotask para evitar múltiplas mensagens no mesmo task
          scheduleMicrotask(() {
            if (!_messageController.isClosed) {
              _messageController.add(response);
            }
          });
        } catch (e) {
          _logger.severe('Failed to parse protocol message: $e');
        }
        
        start = i + 1; // Pular o null byte
      }
    }
    
    // Guardar bytes restantes (sem null byte) para o próximo buffer
    if (start < buffer.length) {
      _pendingChunks.add(buffer.sublist(start));
    }
  }
  
  List<int> _concatenateChunks() {
    if (_pendingChunks.isEmpty) return [];
    if (_pendingChunks.length == 1) return _pendingChunks.first;
    
    final totalLength = _pendingChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final result = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in _pendingChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }
}
```

---

## 4. WebSocketTransport — Comunicação via WebSocket

### 4.1. Quando é usado

- Conectar a um browser já rodando: `browser.connect(wsEndpoint)`
- Servidor remoto Playwright
- Debugging remoto do Chromium via `--remote-debugging-port`

### 4.2. Port para Dart

```dart
// lib/src/transport/web_socket_transport.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Transporte via WebSocket para conexão remota com navegadores.
class WebSocketTransport implements ConnectionTransport {
  final WebSocket _ws;
  final String wsEndpoint;
  
  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();
  
  WebSocketTransport._(this._ws, this.wsEndpoint) {
    _ws.listen(
      (data) {
        if (data is String) {
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final response = ProtocolResponse.fromJson(json);
            _messageController.add(response);
          } catch (e) {
            _logger.severe('Failed to parse WebSocket message: $e');
          }
        }
      },
      onDone: () {
        _closeController.add(_ws.closeReason);
        _closeController.close();
        _messageController.close();
      },
      onError: (error) {
        _logger.warning('WebSocket error: $error');
      },
    );
  }
  
  /// Conectar a um WebSocket endpoint
  static Future<WebSocketTransport> connect(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final ws = await WebSocket.connect(
      url,
      headers: headers,
    ).timeout(timeout ?? const Duration(seconds: 30));
    
    return WebSocketTransport._(ws, url);
  }
  
  @override
  void send(ProtocolRequest message) {
    _ws.add(jsonEncode(message.toJson()));
  }
  
  @override
  Future<void> close() async {
    await _ws.close();
    if (!_closeController.isClosed) {
      _closeController.add(null);
      await _closeController.close();
    }
    await _messageController.close();
  }
  
  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;
  
  @override
  Stream<String?> get onClose => _closeController.stream;
}
```

---

## 5. Conexão de Protocolo (Browser Connection)

### 5.1. Conceito

Acima do transporte, existe a **Connection** que:
1. Gerencia callbacks pendentes (request → response por ID)
2. Despacha eventos para os objetos corretos (por session ID)
3. Implementa timeout e cancelamento

### 5.2. Port para Dart

```dart
// lib/src/transport/browser_connection.dart

/// Conexão de protocolo com o navegador.
/// Gerencia requisições/respostas por ID e despacho de eventos por session.
class BrowserConnection {
  final ConnectionTransport _transport;
  int _lastId = 0;
  
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, CDPSession>{};
  
  final _eventController = StreamController<ProtocolEvent>.broadcast();
  final _closeController = StreamController<void>.broadcast();
  
  bool _closed = false;
  
  BrowserConnection(this._transport) {
    _transport.onMessage.listen(_onMessage);
    _transport.onClose.listen((_) => close());
  }
  
  /// Enviar comando e esperar resposta
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
    Duration? timeout,
  }) async {
    if (_closed) throw StateError('Connection is closed');
    
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    
    _transport.send(ProtocolRequest(
      id: id,
      method: method,
      params: params,
      sessionId: sessionId,
    ));
    
    if (timeout != null) {
      return completer.future.timeout(timeout, onTimeout: () {
        _callbacks.remove(id);
        throw TimeoutException('Command $method timed out after $timeout');
      });
    }
    
    return completer.future;
  }
  
  /// Processar mensagem recebida
  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      // É uma resposta a um comando
      final completer = _callbacks.remove(response.id);
      if (completer == null) return;
      
      if (response.error != null) {
        completer.completeError(
          ProtocolException(
            response.error!.message,
            code: response.error!.code,
            data: response.error!.data,
          ),
        );
      } else {
        completer.complete(response.result ?? {});
      }
    } else if (response.method != null) {
      // É um evento
      final event = ProtocolEvent(
        method: response.method!,
        params: response.params ?? {},
        sessionId: response.sessionId,
        pageProxyId: response.pageProxyId,
      );
      
      // Despachar para a session correta
      if (response.sessionId != null) {
        final session = _sessions[response.sessionId!];
        session?.handleEvent(event);
      } else {
        _eventController.add(event);
      }
    }
  }
  
  /// Criar uma CDP session
  CDPSession createSession(String sessionId) {
    final session = CDPSession(this, sessionId);
    _sessions[sessionId] = session;
    return session;
  }
  
  /// Stream de eventos da conexão principal
  Stream<ProtocolEvent> get onEvent => _eventController.stream;
  
  /// Fechar a conexão
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    
    for (final completer in _callbacks.values) {
      completer.completeError(StateError('Connection closed'));
    }
    _callbacks.clear();
    
    await _transport.close();
    _closeController.add(null);
    await _closeController.close();
    await _eventController.close();
  }
}

/// Evento do protocolo
class ProtocolEvent {
  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;
  final String? pageProxyId;
  
  ProtocolEvent({
    required this.method,
    required this.params,
    this.sessionId,
    this.pageProxyId,
  });
}
```

---

## 6. CDP Sessions

### 6.1. Conceito

No Chromium, cada target (page, worker, service worker) tem sua própria **session**. Comandos são endereçados por `sessionId`.

```dart
// lib/src/transport/cdp_session.dart

/// Session CDP para um target específico (página, worker, etc.)
class CDPSession {
  final BrowserConnection _connection;
  final String sessionId;
  
  final _eventController = StreamController<ProtocolEvent>.broadcast();
  
  CDPSession(this._connection, this.sessionId);
  
  /// Enviar comando nesta session
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) {
    return _connection.send(
      method,
      params: params,
      sessionId: sessionId,
      timeout: timeout,
    );
  }
  
  /// Processar evento recebido
  void handleEvent(ProtocolEvent event) {
    _eventController.add(event);
  }
  
  /// Escutar eventos de um domínio.método específico
  Stream<Map<String, dynamic>> on(String method) {
    return _eventController.stream
        .where((e) => e.method == method)
        .map((e) => e.params);
  }
  
  /// Fechar a session
  Future<void> detach() async {
    await _connection.send(
      'Target.detachFromTarget',
      params: {'sessionId': sessionId},
    );
  }
}
```

---

## 7. Diferenças por Navegador

### 7.1. Chromium
- Transporte: Pipe (`--remote-debugging-pipe`) ou WebSocket (`--remote-debugging-port`)
- Sessions: Sim (Target.attachToTarget → sessionId)
- Formato: JSON-RPC padrão com `id`, `method`, `params`, `result`, `error`

### 7.2. Firefox (Juggler)
- Transporte: Pipe (stdio do processo)
- Sessions: Não usa sessions — eventos vêm com `browsingContextId` e `pageId`
- Formato: JSON com null byte separator
- O Firefox Playwright espera um handshake inicial

### 7.3. WebKit
- Transporte: Pipe (stdio do processo)
- Sessions: Não usa CDP sessions — usa `pageProxyId` e `browserContextId`
- Formato: JSON com null byte separator
- Conceito de **PageProxy**: cada página tem um proxy separado
- Conceito de **ProvisionalPage**: páginas em transição durante navegação cross-origin

### 7.4. Tabela Comparativa

| Aspecto | Chromium | Firefox | WebKit |
|---|---|---|---|
| Protocolo | CDP | Juggler | WebKit Inspector |
| Transporte | Pipe/WebSocket | Pipe | Pipe |
| Session ID | `sessionId` | Não | `pageProxyId` |
| Separador | `\0` | `\0` | `\0` |
| Formato | JSON | JSON | JSON |
| Handshake | Não | Sim (`Browser.enable`) | Sim |
| Cross-origin | Novo target | Mesmo pageId | ProvisionalPage |
