// SPDX-FileCopyrightText: 2026 LE Devices
// SPDX-License-Identifier: AGPL-3.0-or-later
// Error messages people understand (spec 050, T-050-04; constitution P18): what happened and what to
// do, never a technical code on an operation screen. Business errors from programs already speak
// Portuguese (their message is shown as is); technical ones are translated here. Developers and
// administrators also see the code and the original message, to investigate.
(function () {
  "use strict";
  const ROUTINE = ["Não foi possível concluir por um problema na rotina",
                   "Nada foi gravado. Avise o responsável pela rotina — o registro da execução já tem os detalhes."];
  const BUSY = ["O sistema está ocupado agora", "Tente de novo em instantes; nada foi gravado."];
  const AWAY = ["Um serviço necessário não respondeu", "Tente de novo em instantes; nada foi gravado."];
  const BIG = ["O resultado ficou grande demais", "Use filtros ou um período menor para reduzir o resultado."];
  const HEAVY = (what) => [`A operação precisou de ${what} demais`,
                           "Reduza o período ou os filtros. Se a rotina é usada assim todo dia, peça ao administrador para ajustar os limites."];
  const CATALOG = {
    TIMEOUT: ["A operação demorou além do limite", "Tente de novo com filtros menores; se repetir, avise o administrador."],
    CPU_LIMIT: HEAVY("processamento"),
    MEMORY: HEAVY("memória"),
    EXCEPTION: ROUTINE, SYNTAX: ROUTINE, PROCESS_EXITED: ROUTINE, PROTOCOL: ROUTINE, INTERNAL: ROUTINE,
    SQL: ROUTINE, SQL_PARAMETER: ROUTINE, MAX_DEPTH: ROUTINE,
    OVERLOAD: BUSY, PROGRAM_BUSY: BUSY,
    UNAVAILABLE: AWAY, REMOTE_UNAVAILABLE: AWAY, CONNECTOR_UNAVAILABLE: AWAY, CONNECTOR_FAILED: AWAY,
    RESULT_TOO_LARGE: BIG, ROW_LIMIT: BIG, SQL_LIMIT: BIG,
    RATE_LIMITED: ["Você atingiu o limite de uso por minuto", "Aguarde um minuto ou peça ao administrador para ajustar sua cota."],
    QUOTA_EXCEEDED: ["Você atingiu a sua cota de uso", "Peça ao administrador para ajustar sua cota."],
    FORBIDDEN: ["Você não tem permissão para isso", "Peça acesso ao administrador."],
    NOT_AUTHENTICATED: ["Sua sessão terminou", "Entre de novo para continuar."],
    LICENSE_RESTRICTED: ["A licença está vencida ou inválida", "O ERP está só para consulta; peça ao administrador para instalar a licença."],
    CONFLICT: ["Outra pessoa alterou isto enquanto você editava", "Recarregue para ver a versão atual e refaça a alteração."],
    NOT_FOUND: ["Não encontrado", "Pode ter sido removido ou você não tem acesso; atualize a tela."],
    PROGRAM_NOT_FOUND: ["Rotina não encontrada", "Pode ter sido removida ou desativada; atualize a tela."],
    INTERNAL_DOCUMENT: ["Este documento é interno", "Só documentos para clientes e fornecedores podem sair da empresa."],
    // Spec 050 (D5): the standard undo.
    UNDO_EXPIRED: ["O prazo para desfazer terminou", "Use a rotina que reverte o documento (por exemplo, reabrir ou estornar)."],
    UNDO_USED: ["Isto já foi desfeito", "Atualize a tela para ver a situação atual."],
    UNDO_NOT_FOUND: ["Nada a desfazer", "Atualize a tela para ver a situação atual."],
  };
  // Codes whose server message is already written for people: shown as is, with the action.
  const KEEP_MESSAGE = { DATA_SCOPE: "Peça ao administrador para ampliar os dados que você vê.",
                         INVALID_PARAMETER: "Corrija o campo indicado e tente de novo.",
                         SIMULATION_READ_ONLY: "" };

  function technicalViewer() {
    const u = window.AnaStudio && window.AnaStudio.user && window.AnaStudio.user();
    return !!u && (u.role === "developer" || u.role === "admin");
  }

  /** {title, action, technical}: technical is null for operation users. */
  function describe(err) {
    const code = (err && (err.code || err.status)) || "";
    const message = (err && err.message) || "";
    const tech = technicalViewer() && code ? `${code}${message ? ": " + message : ""}` : null;
    if (CATALOG[code]) return { title: CATALOG[code][0], action: CATALOG[code][1], technical: tech };
    if (code in KEEP_MESSAGE) return { title: message || "Não foi possível concluir", action: KEEP_MESSAGE[code], technical: tech };
    // A business rule of a program: its message already says what happened.
    return { title: message || "Não foi possível concluir", action: "", technical: technicalViewer() && code ? String(code) : null };
  }

  /** One line for toasts and banners. */
  function text(err) {
    const d = describe(err);
    return [d.title + (d.title.endsWith(".") ? "" : "."), d.action, d.technical ? `(${d.technical})` : ""].filter(Boolean).join(" ");
  }

  window.AnaErrors = { describe, text, CATALOG };
})();
