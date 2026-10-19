"""Contrast audit of the Studio's color tokens, light and dark (spec 020, RF-020-09, T-020-07).

WCAG 2.1: normal text needs 4.5:1, interface parts (borders of fields, icons) 3:1. Reads the tokens from
priv/www/studio.css (`:root` and the dark `prefers-color-scheme` block) and checks the pairs the Studio
actually uses. Run: python3 tests/a11y/contrast.py (exit 1 when a pair fails)."""

import os
import re
import sys

CSS = os.path.join(os.path.dirname(__file__), "..", "..", "priv", "www", "studio.css")

# (foreground, background, minimum, where it is used)
PAIRS = [
    ("--text", "--bg", 4.5, "texto na página"), ("--text", "--surface", 4.5, "texto em painéis"),
    ("--text", "--surface-2", 4.5, "texto em faixas"), ("--text", "--accent-soft", 4.5, "item selecionado"),
    ("--text", "--row-hover", 4.5, "linha sob o mouse"),
    ("--text-2", "--surface", 4.5, "texto secundário"), ("--text-2", "--bg", 4.5, "texto secundário na página"),
    ("--text-2", "--surface-2", 4.5, "pílulas neutras"),
    ("--accent", "--surface", 4.5, "links e abas ativas"), ("--accent", "--bg", 4.5, "links na página"),
    ("--accent-text", "--accent", 4.5, "botão principal"), ("--accent-text", "--accent-hover", 4.5, "botão principal (mouse)"),
    ("--danger", "--surface", 4.5, "botão de exclusão, erros"), ("--danger", "--surface-2", 4.5, "pílula vermelha"),
    ("--warn", "--surface", 4.5, "avisos"), ("--warn", "--surface-2", 4.5, "pílula de aviso"),
    ("--ok", "--surface", 4.5, "sucesso"), ("--ok", "--surface-2", 4.5, "pílula verde"),
    ("--on-ok", "--ok", 4.5, "marca de etapa concluída"),
    ("--border-strong", "--surface", 3.0, "borda de campos"),
    ("--c", "--surface", 4.5, "comentários no editor"), ("--k", "--surface", 4.5, "palavras-chave no editor"),
    ("--s", "--surface", 4.5, "textos no editor"), ("--n", "--surface", 4.5, "números no editor"),
    ("--f", "--surface", 4.5, "funções no editor"), ("--d", "--surface", 4.5, "decoradores e selo restrito"),
    ("--b", "--surface", 4.5, "constantes no editor"),
    ("#ffffff", "#7b3fbf", 4.5, "faixa de instância de desenvolvimento"), ("#ffffff", "#b25e00", 4.5, "faixas de testes e de aviso"),
    ("#ffffff", "#b3261e", 4.5, "faixa de licença somente consulta"), ("#ffffff", "#5b5f97", 4.5, "faixa de licença de testes"),
]


def tokens(block):
    return dict(re.findall(r"(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})", block))


def themes(css):
    light = tokens(css[css.index(":root"):css.index("}", css.index(":root"))])
    i = css.index("@media (prefers-color-scheme: dark)")
    j = css.index("}", css.index(":root", i))
    return {"claro": light, "escuro": {**light, **tokens(css[i:j])}}


def lum(hexcolor):
    def ch(c):
        c = c / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hexcolor[k:k + 2], 16) for k in (1, 3, 5))
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def audit(css):
    failures = []
    for name, t in themes(css).items():
        for fg, bg, minimum, where in PAIRS:
            a = fg if fg.startswith("#") else t[fg]
            b = bg if bg.startswith("#") else t[bg]
            r = ratio(a, b)
            if r < minimum:
                failures.append(f"{name}: {fg} ({a}) sobre {bg} ({b}) = {r:.2f}:1 < {minimum}:1 — {where}")
    return failures


if __name__ == "__main__":
    fails = audit(open(CSS).read())
    print("\n".join(fails) if fails else f"contraste ok: {len(PAIRS)} pares × 2 temas")
    sys.exit(1 if fails else 0)
