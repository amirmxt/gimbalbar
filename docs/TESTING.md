# GimbalBar 1.1 — instalação e validação

Projeto derivado do GimbalBar original de https://github.com/amirmxt/gimbalbar. Histórico e licença MIT preservados. Compilação e testes devem ser realizados localmente para economizar GitHub Actions.

## Requisitos

- Mac Apple Silicon com macOS 14 ou posterior
- Xcode Command Line Tools
- DJI Osmo Pocket 3 conectada por USB-C e configurada em **Webcam**
- Permissão de câmera para o GimbalBar no macOS

## Recursos disponíveis

- Prévia ao vivo e controle USB do gimbal
- Reconexão automática da câmera
- Interface horizontal em português brasileiro, com duas colunas e **sem rolagem**
- Três posições persistentes (P1, P2, P3) e recuperação com movimento em etapas
- Movimento por software em ritmos **Suave**, **Normal** e **Rápida**
- Atalhos globais habilitáveis e três perfis de modificadores (⌃⌥, ⌘⌥, ⌃⇧), com setas, C e teclas 1–3
- Interromper movimento iniciado por preset; operação manual cancela a trajetória programada

A movimentação suave é implementada enviando pequenas posições absolutas, não por ajuste direto da velocidade do motor. A câmera pode continuar completando um comando já recebido mesmo após interromper o envio de novas etapas. Não constitui parada de emergência.

## Instalar a compilação consolidada

Após as PRs #2 e #3 serem integradas à `main`, feche o GimbalBar e execute:

```bash
cd ~/Projects/gimbalbar
git switch main
git pull --ff-only
./build.sh
```

**Continue apenas se aparecer `Built .../GimbalBar.app` e não houver erro.**

```bash
pkill -x GimbalBar 2>/dev/null || true
backup="$HOME/Desktop/GimbalBar-backup-antes-1.1.app"
if [ -d /Applications/GimbalBar.app ] && [ ! -e "$backup" ]; then
  ditto /Applications/GimbalBar.app "$backup"
fi
ditto ./GimbalBar.app /Applications/GimbalBar.app
open /Applications/GimbalBar.app
```

Isso preserva um backup único da versão anterior na Mesa e substitui o aplicativo instalado somente depois da compilação bem-sucedida. O identificador do aplicativo foi mantido, preservando as preferências locais.

## Testes essenciais da versão 1.1

1. Confirmar que o painel horizontal aparece inteiro, sem barra de rolagem, em português.
2. Validar prévia, movimentação pelo pad e setas, inversão horizontal e centralização.
3. Salvar P1, P2 e P3; retornar a cada uma e conferir persistência após fechar/reabrir.
4. Testar movimentos Suave, Normal e Rápida e o comando **Interromper**.
5. Durante um retorno a posição salva, movimentar manualmente e verificar cancelamento da trajetória programada.
6. Ativar/desativar atalhos, alternar perfis ⌃⌥ / ⌘⌥ / ⌃⇧ e recuperar P1–P3.
7. Desconectar/reconectar a Pocket 3 em Webcam e conferir retomada da prévia e controles.
8. Confirmar que a ausência da câmera não executa movimentos de gimbal.

**Segurança:** manter motores desobstruídos, iniciar com ritmo Suave e evitar movimentos sem supervisão.

## Histórico de validação — 21/10/2026

- Versão 1.0: compilação local e controles USB funcionando; reconexão validada pelo usuário.
- Versão 1.1, PR #2: usuário confirmou que a versão experimental funcionou.
- Versão 1.1, PR #3: a primeira tentativa de layout com `ScrollView` ficou praticamente invisível. Foi substituída por um painel horizontal de largura e altura fixas, sem rolagem, traduzido para português.
- Usuário aprovou o novo layout e posteriormente confirmou: **"Tudo ok"**, em resposta à solicitação de validação funcional de atalhos, cancelamento e reconexão.
- Confirmação de compilação/instalação do executável **consolidado da `main`** ainda é necessária; o teste anterior foi feito na branch experimental, antes da atualização dos metadados da versão.

## Diagnóstico do compilador

Uma versão anterior falhou com `SwiftUIMacros.StateMacro` não encontrado nas Command Line Tools. O ajuste `@StoredState` contornou essa incompatibilidade no MacBook testado.

Em caso de erro no build:

```bash
xcode-select -p
xcrun --find swiftc
swiftc --version
```

Referência do problema: https://github.com/drumih/turbo-fieldfare/issues/185

## Política de integração

Desenvolvimento em branches, PRs de revisão e testes de hardware locais. Não habilitar automações de CI custosas apenas para reproduzir testes que exigem a câmera.
