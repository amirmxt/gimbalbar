# GimbalBar 1.2 — teste experimental de zoom nativo

Esta branch implementa o primeiro controle de câmera além de pan/tilt. **Não substitua o GimbalBar 1.1 em `/Applications` nesta fase.**

## Evidência USB da Pocket 3 — 21/10/2026

O usuário conectou sua DJI Osmo Pocket 3 por USB-C em modo Webcam e executou o diagnóstico nativo em macOS. Camera Terminal **ID 1**, VideoControl interface **0**, seletor UVC **Zoom Absolute = 0x0B**:

| Consulta | Resposta (little-endian) | Valor decimal | Enquadramento |
|---|---|---:|---|
| `GET_INFO` | GET=sim / SET=sim | — | escrita anunciada, ainda não testada |
| `GET_CUR` | `0x6400` | 100 | 1× |
| `GET_MIN` | `0x6400` | 100 | 1× |
| `GET_MAX` | `0x9001` | 400 | 4× |

O resultado confirma **leitura real** do dispositivo. O suporte a `SET_CUR` é apenas anunciado pelo firmware; não há confirmação física de que a escrita funcionará até o próximo teste.

Exposição, foco e balanço de branco não aparecem nos controles UVC anunciados. Não estamos simulando esses controles.

## Ajuste de responsividade — feedback de 21/10/2026

Na primeira versão do slider, a Pocket 3 aplicava zoom, porém havia atraso nos botões e divergência entre a posição mostrada e o zoom efetivamente aplicado, relatados pelo usuário com captura de tela.

A revisão mantém duas grandezas distintas:

- **Selecionado (valor acima do controle)**: pedido do usuário. Move imediatamente com o dedo/mouse.
- **Câmera (valor abaixo do controle)**: último valor confirmado via `GET_CUR` da Pocket 3.
- Durante o arraste, os pedidos USB são **agrupados em janelas de 160 ms**: somente o destino mais recente é mantido na fila, sem gerar escrita para cada pixel movimentado.
- O botão `1×` aceita uma nova solicitação mesmo enquanto a anterior está em andamento.
- A posição do slider não é corrigida por leituras iniciadas antes do ajuste. Depois de um período de estabilização de aproximadamente 1,2 s, passa a acompanhar novamente as leituras efetivas do dispositivo.
- O driver usa os limites de zoom conferidos na conexão ao enviar `SET_CUR`, evitando repetir `GET_MIN` e `GET_MAX` para cada pequena alteração.

**Atenção:** o número `Câmera:` representa a resposta UVC. Ela pode mudar antes ou depois da transição visual do sensor/ISP, e o firmware pode impor passos próprios. Não interpretar o valor selecionado como zoom efetivamente aplicado até a leitura confirmar.

### Validar a revisão

Após atualizar a branch e compilar localmente, arraste lentamente de 1× para 2× e observe se a prévia responde durante o arraste (não apenas ao soltar). Verifique se **Selecionado** e **Câmera** convergem depois de parar. Experimente o botão 1× enquanto a câmera ainda está aproximando. Confirme também funcionamento de pan/tilt e de P1–P3.

Se ainda existir divergência persistente, registrar os dois valores em que ocorreu. Não integrar à versão instalada até esclarecer.

## Implementação experimental

- `ptz.h` / `ptz.c`: métodos de consulta do zoom e envio de `SET_CUR` com 2 bytes little-endian, usando o Camera Terminal existente. Cada escrita só ocorre depois de reler `GET_MIN`/`GET_MAX` e validar os limites.
- `GimbalBar.swift`: estado do zoom, consulta inicial, atualização periódica moderada via mesma fila serial USB do pan/tilt, slider no painel horizontal sem `ScrollView` e botão para retornar a 1×.
- O slider é responsivo e envia comandos agrupados em intervalos de 160 ms durante o arraste; ao soltar, confirma o último alvo. A interface exibe o valor selecionado e o valor lido da câmera separadamente.
- O controle permanece desabilitado até verificar os limites reais de 1×–4× da câmera. Uma desconexão desabilita o slider e provoca nova descoberta ao reconectar.
- Versão do executável experimental: **1.2**; a instalação estável deve permanecer **1.1**.
- Os atalhos globais existentes e as três posições salvas continuam preservados. O zoom **ainda não faz parte dos presets**.

## Teste local sem instalar outro app

1. Feche a versão 1.1 pelo botão **Sair**.
2. Deixe a Pocket 3 em uma superfície estável, conecte USB-C e escolha **Webcam**. Não teste durante reunião ou gravação importante.
3. Execute:

```bash
cd ~/Projects/gimbalbar
git fetch origin
git switch --track origin/feat/v1.2-native-zoom
./build.sh && open ./GimbalBar.app
```

Se a branch já existir, utilize `git switch feat/v1.2-native-zoom` e `git pull --ff-only`. O build gera o aplicativo **somente dentro do repositório**: não copie para `/Applications` nem inicie duas instâncias ao mesmo tempo.

4. Confira o bloco **Zoom da câmera** na coluna direita, o valor inicial 1,0× e o controle habilitado. Se estiver indisponível, registre a mensagem; não force o envio.
5. Primeiro teste apenas **1,2×**. Arraste o slider de 1,0× para 1,2× e solte. Verifique se a imagem da Pocket 3 mudou e se o valor permanece ao atualizar.
6. Teste **2×** e volte a **1×** pelo botão. Evite pular diretamente para 4× antes de validar os pequenos movimentos.
7. Confirme que os controles PTZ, prévia, posições e atalhos continuam funcionando.
8. Desconecte/reconecte a câmera em modo Webcam e verifique se o zoom é consultado novamente.
9. Se o app falhar ao compilar, registre o erro completo do Terminal e não execute uma compilação incompleta.

**Segurança:** A escrita altera o zoom nativo do dispositivo e pode afetar a imagem de outros aplicativos conectados à mesma câmera. O sistema não envia comandos de foco, exposição, reset USB nem alterações de firmware.

## Encerrar o teste sem múltiplas instalações

Na própria interface experimental, escolha **Sair**, depois abra a versão estável:

```bash
open /Applications/GimbalBar.app
```

Somente após validar podemos consolidar o zoom na `main`, reconstruir uma única cópia em `/Applications` e limpar o binário experimental dentro de `~/Projects/gimbalbar`. Não consumir GitHub Actions para testes dependentes da Pocket 3.

## Situação

- [x] GET_INFO, GET_CUR, GET_MIN e GET_MAX testados na Pocket 3 real.
- [x] Controle SwiftUI e driver de zoom escritos em branch separada.
- [ ] Compilação nativa do novo código no MacBook.
- [ ] Primeiro comando `SET_CUR` validado fisicamente (1,2×).
- [ ] Testes de zoom progressivo e responsividade, retorno 1×, reconexão e regressão.
- [ ] Merge e atualização da instalação estável (somente após testes).

Referência para o seletor de controle UVC: https://github.com/microsoft/Windows-driver-samples/blob/main/usb/usbview/uvcdesc.h
