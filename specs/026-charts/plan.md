# 026 — Plano técnico

- Runtime: `ana.chart(spec)` valida e normaliza (tipos, tamanhos, números,
  máx. 8 séries com "Outros", donut ≤ 6 fatias) e emite o evento `chart`.
- Interface: `charts.js` (`AnaCharts.render`) desenha SVG: escala "redonda"
  no eixo vertical, rótulos do eixo horizontal espaçados, grade em linhas
  finas sólidas; barras ≤ 24 px com ponta arredondada de 4 px e base reta,
  2 px de espaço entre barras/segmentos; linhas de 2 px; marcadores de 8 px
  com anel da cor da superfície; área a 10 % de opacidade.
- Cores por classe (`.s1`…`.s8`) sobre variáveis CSS com os valores claro e
  escuro da paleta validada (`validate_palette.js`: passa nos dois temas; no
  claro, 3 cores abaixo de 3:1 → rótulos diretos e tabela obrigatórios).
- Interação: linha guia + dica com todas as séries (linha/área), dica por
  barra/fatia; foco por teclado nas marcas; botão "Ver tabela".
- `ResizeObserver` redesenha quando o quadro muda de tamanho.
