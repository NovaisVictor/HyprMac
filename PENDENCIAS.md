# Pendências do HyprMac

Itens do Hyprland que o HyprMac ainda não cobre. Ficam de fora por serem caros (⚠️) ou inviáveis no macOS sem desativar o SIP (❌). O que é viável (✅) está no roadmap de desenvolvimento.

O limite estrutural é o mesmo em todos os casos: no macOS o compositor é o WindowServer da Apple, que é fechado. O HyprMac só consegue mover e redimensionar janelas de outros apps pela Accessibility API (assíncrona, por app). Não consegue desenhar, compor nem interceptar a criação dessas janelas.

## ⚠️ Viáveis, mas caros ou frágeis

### Animação ao abrir janela (popin/slide)
- **Problema:** a janela já aparece desenhada pelo macOS na posição que o app escolheu. O HyprMac só fica sabendo depois, pela notificação de AX.
- **O que dá para fazer:** animar a janela deslizando da posição inicial até o slot, reaproveitando o animador de layout. "Crescer do nada" (popin) não é possível.
- **Custo:** médio. Pode piorar a sensação de flash em vez de melhorar.

### Animação de troca de workspace (slide/fade)
- **Problema:** os workspaces são emulados escondendo as janelas num canto da tela. Animar a troca exige mover todas as janelas dos dois workspaces via AX ao mesmo tempo.
- **Caminhos:**
  1. Interpolar via AX todas as janelas. Engasga com muitas janelas ou com apps lentos (Electron, JetBrains).
  2. "Animação falsa" com snapshots: capturar as janelas via ScreenCaptureKit, animar as imagens num overlay próprio, trocar as janelas reais por baixo e fazer o fade-out do overlay quando o AX confirmar as posições.
- **Custos conhecidos do caminho 2:**
  - latência de captura;
  - snapshots desatualizados de workspaces escondidos (apps param de renderizar quando ocluídos);
  - cerca de 60 MB por frame 5K;
  - permissão de gravação de tela, que o macOS 15+ volta a pedir periodicamente.
- **Se for feito:** opt-in e curto (~100–150 ms).

### Animação ao fechar janela (popout)
- **Problema:** quando o HyprMac recebe a notificação, a janela já sumiu.
- **Caminho:** guardar um snapshot recente da janela e animar esse "fantasma" num overlay. Tem os mesmos custos de captura e permissão da troca de workspace.

### Gestos de trackpad (swipe entre workspaces)
- **Problema:** gestos de três ou quatro dedos não chegam como eventos públicos utilizáveis. O macOS os consome para Mission Control e Spaces.
- **Caminho:** o framework privado `MultitouchSupport` funciona sem SIP, mas não tem API pública e pode quebrar a cada versão do macOS.
- **Alternativa já documentada pelo upstream:** o "trackpad gestures trick" (BetterTouchTool ou similar chamando o CLI do `hyprmac`).

## ❌ Inviáveis sem desativar o SIP

São recursos de compositor, que o macOS só expõe ao próprio WindowServer. O yabai implementa parte deles injetando código no Dock.app, o que exige o SIP desativado, e isso contraria a proposta do HyprMac.

| Recurso do Hyprland | Por que não dá |
| --- | --- |
| Blur atrás das janelas | Exige compor os pixels de outras janelas |
| Cantos arredondados em janelas de outros apps | Mesmo motivo |
| Sombras customizadas | Mesmo motivo |
| Shaders de tela e por janela | Mesmo motivo |
| Opacidade e transparência por janela ou por regra | Só com APIs privadas do WindowServer e SIP desativado |
| Fade e escurecer janelas inativas (`dim_inactive`) | Depende de opacidade por janela |
| Ordem de sobreposição (always on top, z-order) | Sem API pública. Issue #4 do upstream |
| Plugins nativos carregados no processo (.so/.dylib) | Possível em teoria, mas sem ABI estável no Swift. O caminho prático é scripting via socket (`hyprmac subscribe` + CLI) |

## Adiados por decisão

- **Animações "falsas" com snapshots** (troca de workspace, abrir e fechar janela): ficam para depois das animações de layout via AX.
