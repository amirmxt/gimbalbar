# GimbalBar 1.2 — diagnóstico dos controles da Pocket 3

Esta etapa identifica os controles de câmera acessíveis por USB no modo **Webcam/UVC**, antes de programar qualquer slider de zoom, exposição ou foco. A versão estável do GimbalBar continua sendo 1.1.

## Executar no MacBook

Conecte a DJI Osmo Pocket 3 ao Mac com USB-C e selecione **Webcam**. É permitido manter o GimbalBar 1.1 aberto para verificar o vídeo, mas, se o diagnóstico falhar, feche o aplicativo e repita.

No Terminal:

```bash
cd ~/Projects/gimbalbar
git fetch origin
git switch --track origin/feat/v1.2-camera-controls-diagnostics
zsh ./diagnose.sh | tee ~/Desktop/gimbalbar-uvc-diagnostico.txt
```

Caso essa branch já exista localmente, execute `git switch feat/v1.2-camera-controls-diagnostics` e `git pull --ff-only` antes do diagnóstico.

Se o relatório for gerado, envie **o texto completo do Terminal ou o arquivo `gimbalbar-uvc-diagnostico.txt`**. Não tente editar manualmente bytes da câmera.

## O que faz

1. Procura **somente** o dispositivo com VID `0x2ca3` e PID `0x0023`, utilizados pelo projeto original.
2. Lê os descritores USB, localizando a interface VideoControl (classe 0x0e, subclasse 1).
3. Localiza os IDs reais de cada Camera Terminal e Processing Unit nos descritores. Não presume que a Processing Unit tenha ID 2.
4. Inspeciona os bits de suporte anunciados nos descritores UVC e consulta `GET_INFO` apenas para controles anunciados.
5. Exibe se o dispositivo declarou suporte a leitura (`GET`) e escrita (`SET`); **não executa a escrita**.

O comando padrão só consulta capacidades (`GET_INFO`). Há um teste opcional para ler valores:

```bash
zsh ./diagnose.sh --values | tee ~/Desktop/gimbalbar-uvc-valores.txt
```

O teste opcional envia `GET_CUR`, `GET_MIN` e `GET_MAX` **somente** quando `GET_INFO` anuncia leitura. Os dados são impressos em bytes hexadecimais para evitar inventar escalas.

## Controles investigados

| Unidade UVC | Control selector | Conteúdo |
|---|---|---|
| Camera Terminal | 0x0B | Zoom absoluto |
| Camera Terminal | 0x02 / 0x04 | Exposição automática / tempo de exposição |
| Camera Terminal | 0x06 / 0x08 | Foco manual / automático |
| Camera Terminal | 0x0D | Pan/Tilt absoluto (já utilizado no 1.1) |
| Processing Unit | 0x0A / 0x0B | Temperatura de branco / automático |
| Processing Unit | 0x04 | Ganho |
| Processing Unit | 0x02 / 0x03 / 0x07 / 0x08 | Brilho, contraste, saturação e nitidez |
| Processing Unit | 0x01 | Compensação de contraluz |

## Como interpretar

- **não anunciado:** o descritor USB não declara esse controle como disponível. Isso não elimina a possibilidade de um comando proprietário da DJI.
- **anunciado, GET/SET = sim:** o dispositivo respondeu que oferece leitura e/ou escrita pelo padrão UVC; ainda é necessário testar compatibilidade e segurança antes de implementar comandos SET.
- **GET_INFO falhou:** o macOS, o firmware ou o dispositivo não aceitou a consulta; o motivo permanece indeterminado.
- **nenhuma unidade localizada:** confira Webcam/USB. Não conclua que o equipamento não suporta zoom ou exposição.

A ferramenta **não** envia `SET_CUR`, reinicializa o USB, altera configurações, toma posse da interface ou acessa Bluetooth. O projeto continua utilizando apenas APIs padrão do macOS e comandos UVC de leitura.

## Cuidados

- Esta é uma ferramenta diagnóstica experimental. Não é uma versão de produção e ainda depende de **compilação e validação no MacBook**.
- A câmera pode apresentar recursos na sua própria tela que não expõe ao Mac via UVC. O fato de haver zoom na Pocket 3 não comprova que o Mac consegue comandá-lo.
- Para o diagnóstico básico, não precisamos atualizar ou reinstalar `/Applications/GimbalBar.app`.
- Evitar GitHub Actions: compilação local com `clang`.

## Fontes técnicas

- Padrões de seletores e solicitações GET UVC: https://github.com/realsenseai/librealsense/blob/master/src/uvc/uvc-types.h
- Estrutura dos descritores UVC: https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/video.h
- `GetConfigurationDescriptorPtr` no IOKit Apple: https://github.com/apple-oss-distributions/IOUSBFamily/blob/main/IOUSBFamily/Headers/IOUSBLib.h

## Próximo desenvolvimento após os resultados

Só criar controles operacionais no GimbalBar quando os descritores e as consultas comprovaram suporte. Prioridade: zoom nativo, compensação/tempo de exposição, balanço de branco e foco. Sem suporte documentado, não gerar controles fictícios que alteram apenas a prévia local.
