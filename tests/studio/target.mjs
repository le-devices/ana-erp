// SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
// SPDX-License-Identifier: AGPL-3.0-or-later
// The ANA the Studio tests run against (ANA_URL, default http://localhost:8080 as in CI). Before anything else, it
// checks that the page there is ANA's Studio: on a developer's machine another site may answer on that port, and a
// test must never log in to it or write to it.
export const ANA_URL = (process.env.ANA_URL || "http://localhost:8080").replace(/\/+$/, "");

export async function ensureAna() {
  let html = "";
  try {
    html = await (await fetch(ANA_URL + "/")).text();
  } catch (e) {
    console.error(`ANA_URL=${ANA_URL}: nada responde (${e.message}). Suba o ANA (make subir) ou aponte ANA_URL para ele.`);
    process.exit(2);
  }
  if (!html.includes('id="login-screen"') || !html.includes("studio/errors.js")) {
    console.error(`ANA_URL=${ANA_URL} não é o Estúdio do ANA (outra aplicação respondeu nesse endereço). ` +
                  "Nada foi feito: aponte ANA_URL para o ANA (ex.: ANA_URL=http://localhost:8081 make teste-estudio).");
    process.exit(2);
  }
}
