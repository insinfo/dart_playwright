# Plano de Implementação: Pacote playwright_mcp

## Objetivo
Criar o pacote `playwright_mcp`, um servidor **Model Context Protocol (MCP)** nativo em Dart que expõe as capacidades do `playwright_dart` (recém-portado e estabilizado no Chromium) para o Claude Desktop ou outros clientes MCP.

O `playwright_mcp` utilizará a abstração nativa `Browser` e `Page` que construímos, eliminando a dependência do Node.js, e oferecerá ferramentas robustas de automação e extração de DOM/Acessibilidade.

---

## Fases de Implementação

### Fase 1: Estrutura do Pacote
1. Criar diretório `packages/playwright_mcp`.
2. Adicionar dependências no `pubspec.yaml`:
   - `playwright` (referenciando o pacote local por path).
   - `mcp_server` (pacote hipotético/real do protocolo MCP em Dart, ou implementação customizada de JSON-RPC via stdio).
   - Dependências de CLI (`args`).

### Fase 2: Configuração do Servidor JSON-RPC
Implementar um servidor JSON-RPC 2.0 sobre `stdin/stdout`, compatível com a especificação Model Context Protocol.
- **Transports:** `StdioTransport`.
- **Rotas MCP:**
  - `initialize` (retorna capacidades de Server).
  - `tools/list` (retorna lista de ferramentas do Playwright).
  - `tools/call` (executa as ferramentas e retorna resultados).

### Fase 3: Playwright Context Manager
Criar uma classe singleton para gerenciar o estado do navegador durante a sessão do MCP:
- Lançar o `playwright.chromium.launch()`.
- Criar o `BrowserContext`.
- Manter controle da `Page` atual (ativa).
- Manter rastreamento da `AccessibilitySnapshot` para gerar referência de UI para o LLM.

### Fase 4: Implementação das Ferramentas MCP
Expor as seguintes ferramentas no `tools/list` e tratá-las no `tools/call`:
1. `navigate(url)`: Navega para a URL usando `page.goto`.
2. `screenshot()`: Retorna um PNG base64 da página (`page.screenshot`).
3. `click(selector)`: Dispara clique no seletor (`page.locator.click`).
4. `fill(selector, text)`: Preenche texto (`page.locator.fill`).
5. `evaluate(expression)`: Executa JS arbitrário.
6. `get_dom_snapshot()`: Extrai a árvore de Acessibilidade da página usando `page.accessibilitySnapshot()` (que já implementamos no backend Chromium usando `Accessibility.getFullAXTree`).

### Fase 5: Compilação e Integração
1. Criar um binário final no diretório `bin/playwright_mcp.dart`.
2. Documentar como conectar ao `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "playwright-dart": {
      "command": "dart",
      "args": ["run", "C:\\MyDartProjects\\playwright\\packages\\playwright_mcp\\bin\\playwright_mcp.dart"]
    }
  }
}
```

---

## Status dos Motores (Chromium vs Firefox/WebKit)
No V0.1, o `playwright_mcp` utilizará exclusivamente o Chromium. 
*Investigação prévia confirmou que as implementações do Firefox (Juggler) e WebKit (WPE) utilizam APIs de alvo drasticamente divergentes (ex: `Browser.newPage` vs `Playwright.createPage`). O Chromium está maduro, validado com testes E2E e pronto para suportar as chamadas assíncronas do MCP.*
