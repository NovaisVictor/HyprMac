# Roadmap do HyprMac

Itens viáveis (✅) mapeados para desenvolvimento. O que é caro ou inviável está em [PENDENCIAS.md](PENDENCIAS.md).

Todos os itens são opt-in: sem configuração, o comportamento é o do upstream.

## Correção prioritária (antes de qualquer item novo)

**Eco das animações.** Cada frame que o animador escreve gera notificações de AX (moved/resized). Hoje só a janela agarrada pelo mouse é filtrada. As vizinhas animadas pela prévia ao vivo disparam um refresh completo a até 60 Hz por janela. Também há um caso em que as nossas escritas são confundidas com um arrasto nativo (`isManipulatedWithMouse`).
- **Correção:** um conjunto thread-safe com os ids das janelas em animação, mais uma margem de ~150 ms. Os observers de AX ignoram essas janelas.

## Ondas de desenvolvimento

As ondas existem para evitar conflitos entre worktrees paralelos. Cada worktree parte da `feat/hyprland-features` atualizada, e no fim tudo volta para ela por cherry-pick.

### Onda 0: preparação (sequencial)
- Integrar o backlog (agent em andamento).
- Correção do eco das animações.
- Mover o posicionamento de janelas novas (`MacWindow.swift`) para um arquivo próprio, porque `preselect` e `master-new-window` mexem nele.

### Onda 1 (paralela)
| Worktree | Itens | Esforço |
| --- | --- | --- |
| animations | `[animations]` unificado; curvas bezier; animação de todas as mudanças de layout; slide do scratchpad | M |
| layout-a | Smart gaps; pseudotile | S + M/L |
| dwindle | `toggle-split`, `swap-split`, `preselect` | S + M |
| workspace-rules | `[workspace.X]` com layout, orientação, gaps, normalização e placement por workspace | M |
| tree-binds | Comando `tree` (JSON e texto); atalho ao soltar a tecla; repeat | M + S |

### Onda 2 (paralela, depois da onda 1)
| Worktree | Itens | Esforço |
| --- | --- | --- |
| master | `master-new-window`; master central (ultrawide) | S + M/L |
| pin | `pin` para janelas flutuantes | M |
| title-rules | `[[on-window-title-changed]]` com debounce e disparo por borda | M/L |
| tab-bar | Barra de abas para accordion | M/L |
| borders | Borda nativa completa, substituindo o JankyBorders | L |
| modifier-tap | Atalho só com modificador (tocar `cmd` sozinho), depois de um spike de permissão | M/L |

## Decisões (padrão recomendado entre parênteses)

### Animações
1. Animar o reload da config? (não)
2. Animar o tamanho por padrão? (sim, com `animate-size = false` disponível para apps pesados)
3. Animar janela que muda de monitor? (não, ela pula)
4. Janela nova desliza de onde o app a abriu? (não, fica nas pendências)
5. Direção do scratchpad? (de baixo; sem fade)
6. Limite de janelas animadas por vez? (12)
7. Alias do `[mouse-grab] animation-duration-ms`? (mantido com aviso de obsoleto)

### Bordas e abas
8. Borda nativa: **decidido: completa, para testar 100% sem o JankyBorders.** Inclui:
   - borda ativa e inativas;
   - gradiente;
   - transição de cor;
   - giro na troca de foco;
   - animação contínua de ângulo.

   Tudo configurável e opt-in em `[borders]`. Otimizamos depois, a partir de medições de consumo comparadas com o JankyBorders.
9. APIs privadas do SkyLight: **decidido: liberadas só no módulo de bordas.** Elas funcionam sem SIP e são as mesmas que o JankyBorders usa para:
   - ordenar a borda logo acima da janela alvo;
   - movê-la junto com o grupo da janela;
   - receber eventos de movimento direto do WindowServer.

   A implementação fica isolada e carregada via `dlsym`, com fallback para API pública se algum símbolo sumir.
10. Referência: o JankyBorders é GPL-3.0 e o HyprMac é MIT. Estudamos a abordagem (quais chamadas, em que ordem), mas não copiamos código.
11. Barra de abas também em `v_accordion`? (sim)
12. Barra com um único filho? (sim)
13. Forçar `accordion-padding = 0` com a barra ligada? (sim)

### Layout
14. Smart gaps conta janelas de um accordion? (só quando há exatamente uma janela em tiling)
15. Pseudotile maior que o slot? (escala mantendo a proporção, como o Hyprland)
16. `resize` de teclado em pseudotile? (muda o slot)
17. `preselect` também com `new-window-placement = 'sibling'`? (sim)
18. Troca de foco cancela o `preselect`? (não; só o uso ou `preselect cancel`)
19. Renomear `isDwindleSplit` para `hasPinnedOrientation`? (sim)
20. Master central: só config ou também por container? (os dois: config por monitor + `layout center_master`)
21. Lado da primeira janela da pilha no master central? (direita)
22. Mínimo de janelas para centralizar? (3; abaixo disso, master à esquerda)

### Regras e workspaces
23. `pin` numa janela em tiling? (a torna flutuante e fixa)
24. `move-node-to-workspace` desfaz o pin? (sim)
25. Evento `window-pinned` no subscribe? (não por enquanto)
26. Regras de título: disparo por borda ou por nível? (borda: só quando o match passa de falso para verdadeiro)
27. Regras de título: bloco separado ou flag no `on-window-detected`? (bloco `[[on-window-title-changed]]`)
28. Debounce das regras de título? (300 ms)
29. Sintaxe por workspace? (`[workspace.G]`)
30. `new-window-placement` por workspace? (sim)
31. Comando de runtime do PR #2190 (`enable-normalization --workspace`)? (não)

### Atalhos e árvore
32. Sintaxe do atalho ao soltar? (tabela inline: `alt-x = { run = '...', on = 'release' }`)
33. Se o atalho só com modificador exigir a permissão de Monitoramento de Entrada? (aceitar o pedido único; polling gastaria CPU parado)
34. Modificadores esquerdo/direito distintos no atalho só com modificador? (sim, numa fatia posterior)
35. `schema-version` no JSON do `tree`? (sim)
36. `--floating-windows-as-tiling-windows` no `tree`? (depois)
37. `tree` sem `--workspace`, `--focused` ou `--all`? (erro, como o `list-windows`)
