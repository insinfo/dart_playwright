import 'package:playwright/playwright.dart';

void main() async {
  print('Iniciando Playwright Dart...');
  
  // 1. Inicializa o Playwright
  final playwright = await Playwright.create();
  
  // 2. Lança o Chromium localmente em modo headless
  print('Iniciando o Chromium...');
  final browser = await playwright.chromium.launch(headless: true);
  
  try {
    // 3. Cria um novo contexto (sessão isolada)
    print('Criando contexto...');
    final context = await browser.newContext();
    
    // 4. Cria uma nova aba
    print('Abrindo nova aba...');
    final page = await context.newPage();
    
    // 5. Navega para um site
    print('Navegando para example.com...');
    await page.goto('https://example.com');
    
    // 6. Extrai o título
    final title = await page.title();
    print('Título da página: $title');
    
    // 7. Extrai o conteúdo do <h1> usando um locator e executa código JS na página
    final header = page.locator('h1');
    final text = await header.textContent();
    print('Texto do cabeçalho H1: $text');
    
  } catch (e) {
    print('Erro ocorrido: $e');
  } finally {
    print('Fechando navegador...');
    await browser.close();
  }
}
