// ANA API client. Token kept in sessionStorage: no cookies → no CSRF
// (RNF-005-02).
"use strict";
(function () {
  const KEY = "ana.token";
  let token = null;
  try { token = sessionStorage.getItem(KEY); } catch (_) { /* storage unavailable */ }

  class ApiError extends Error {
    constructor(status, body) {
      const e = (body && body.error) || {};
      super(e.message || `HTTP ${status}`);
      this.status = status;
      this.code = e.code;
      this.body = body;
    }
  }

  /** fetch that turns "Failed to fetch" (server restarting, network down) into a clear message. */
  async function send(path, init) {
    try {
      return await fetch(path, init);
    } catch (e) {
      if (init && init.signal && init.signal.aborted) throw e;
      throw new ApiError(0, { error: { code: "OFFLINE",
        message: "sem conexão com o ERP (servidor reiniciando ou rede fora do ar); tente de novo em alguns segundos" } });
    }
  }

  const enc = encodeURIComponent;
  const query = (params) => {
    const q = Object.entries(params || {}).filter(([, v]) => v !== undefined && v !== null && v !== "")
      .map(([k, v]) => `${enc(k)}=${enc(v)}`).join("&");
    return q ? "?" + q : "";
  };

  function saveBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = filename;
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  }

  const API = {
    onExpired: () => {},
    onPasswordRequired: () => {},
    get authenticated() { return !!token; },

    async request(method, path, body, options = {}) {
      const headers = { "Accept": "application/json" };
      if (token) headers["Authorization"] = "Bearer " + token;
      if (body !== undefined) headers["Content-Type"] = "application/json";
      const resp = await send(path, {
        method, headers, signal: options.signal,
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: "no-store", credentials: "omit",
      });
      let data = null;
      if (resp.status !== 204) {
        const text = await resp.text();
        try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: { message: text } }; }
      }
      if (resp.status === 401 && path !== "/api/session") {
        API.setToken(null);
        API.onExpired();
      }
      if (resp.status === 403 && data && data.error && data.error.code === "PASSWORD_CHANGE_REQUIRED") {
        API.onPasswordRequired();
      }
      if (!resp.ok && !(options.accept || []).includes(resp.status)) throw new ApiError(resp.status, data);
      return data;
    },

    setToken(t) {
      token = t;
      try { t ? sessionStorage.setItem(KEY, t) : sessionStorage.removeItem(KEY); } catch (_) { /* ignore */ }
    },

    async login(username, password) {
      const r = await API.request("POST", "/api/session", { username, password });
      API.setToken(r.token);
      return r.user;
    },
    async logout() {
      try { await API.request("DELETE", "/api/session"); } finally { API.setToken(null); }
    },
    me: () => API.request("GET", "/api/me"),
    changePassword: (current, next) => API.request("POST", "/api/me/password", { current, new: next }),

    programs: (inactive) => API.request("GET", "/api/programs" + query({ inactive: inactive ? 1 : 0 })),
    programPerformance: (name) => API.request("GET", `/api/programs/${enc(name)}/performance`),
    program: (n) => API.request("GET", `/api/programs/${enc(n)}`),
    saveProgram: (n, fields) => API.request("PUT", `/api/programs/${enc(n)}`, fields),
    purgeProgram: (n) => API.request("DELETE", `/api/programs/${enc(n)}?purge=1`),
    versions: (n) => API.request("GET", `/api/programs/${enc(n)}/versions`),
    limits: (n) => API.request("GET", `/api/programs/${enc(n)}/limits`),
    version: (n, v) => API.request("GET", `/api/programs/${enc(n)}/versions/${v}`),
    restore: (n, v) => API.request("POST", `/api/programs/${enc(n)}/versions/${v}/restore`, {}),
    run: (n, body) => API.request("POST", `/api/programs/${enc(n)}/run`, body, { accept: [422] }),
    /** Authenticated download saved as a file (spec 034: data copies). */
    async download(path, filename) {
      const headers = {};
      if (token) headers["Authorization"] = "Bearer " + token;
      const resp = await send(path, { headers, cache: "no-store", credentials: "omit" });
      if (!resp.ok) throw new ApiError(resp.status, null);
      saveBlob(await resp.blob(), filename);
    },
    saveBlob: (blob, filename) => saveBlob(blob, filename),
    /** Raw body (file upload): bytes go as they are, with the session token. */
    async raw(method, path, blob) {
      const headers = { "Accept": "application/json", "Content-Type": "application/octet-stream" };
      if (token) headers["Authorization"] = "Bearer " + token;
      const resp = await send(path, { method, headers, body: blob, cache: "no-store", credentials: "omit" });
      const text = await resp.text();
      let data = null;
      try { data = text ? JSON.parse(text) : null; } catch (_) { data = { error: { message: text } }; }
      if (resp.status === 401) { API.setToken(null); API.onExpired(); }
      if (!resp.ok) throw new ApiError(resp.status, data);
      return data;
    },
    files: {
      list: (parent) => API.request("GET", "/api/files/folders" + query(parent ? { parent } : {})),
      createFolder: (parent, name) => API.request("POST", "/api/files/folders", { parent: parent || null, name }),
      detail: (id) => API.request("GET", `/api/files/files/${id}`),
      update: (id, body) => API.request("PUT", `/api/files/files/${id}`, body),
      remove: (id) => API.request("DELETE", `/api/files/files/${id}`),
      setExternal: (folder, external) => API.request("PUT", `/api/files/folders/${folder}/external`, { external }),
      download: (id, version, inline) => API.request("POST", `/api/files/files/${id}/download`, { version: version || null, inline: !!inline }),
      zip: (folder) => API.request("POST", `/api/files/folders/${folder}/zip`, {}),
      search: (q) => API.request("GET", "/api/files/search" + query(q)),
      grant: (body) => API.request("POST", "/api/files/grants", body),
      revoke: (id) => API.request("DELETE", `/api/files/grants/${id}`),
      link: (id, body) => API.request("POST", `/api/files/files/${id}/links`, body),
      unlink: (id) => API.request("DELETE", `/api/files/links/${id}`),
      uploadSmall: (folder, name, blob, comment) =>
        API.raw("POST", "/api/files/upload" + query({ folder, name, comment: comment || undefined }), blob),
      uploadInit: (folder, name, size, comment) => API.request("POST", "/api/files/uploads", { folder, name, size, comment: comment || null }),
      uploadStatus: (id) => API.request("GET", `/api/files/uploads/${id}`),
      uploadChunk: (id, offset, blob) => API.raw("PUT", `/api/files/uploads/${id}` + query({ offset }), blob),
      uploadComplete: (id) => API.request("POST", `/api/files/uploads/${id}/complete`, {}),
    },
    portalPrograms: () => API.request("GET", "/api/portal/programs"),
    executions: (program, mine) => API.request("GET", "/api/executions" + query({ limit: 50, program, mine: mine ? 1 : undefined })),
    execution: (id) => API.request("GET", `/api/executions/${enc(id)}`),
    events: (id, since, signal) => API.request("GET",
      `/api/executions/${enc(id)}/events?since=${since}&wait=1`, undefined, { signal }),
    command: (id, cmd) => API.request("POST", `/api/executions/${enc(id)}/command`, cmd),
    routines: () => API.request("GET", "/api/routines"),
    favorite: (p) => API.request("PUT", `/api/me/favorites/${enc(p)}`, {}),
    unfavorite: (p) => API.request("DELETE", `/api/me/favorites/${enc(p)}`),
    commands: () => API.request("GET", "/api/commands"),
    saveCommand: (code, body) => API.request("PUT", `/api/commands/${enc(code)}`, body),
    deleteCommand: (code) => API.request("DELETE", `/api/commands/${enc(code)}`),
    catalog: () => API.request("GET", "/api/catalog"),
    table: (s, t) => API.request("GET", `/api/catalog/${enc(s)}/${enc(t)}`),
    sql: (sql) => API.request("POST", "/api/sql", { sql }),

    scheduler: {
      jobs: (program) => API.request("GET", "/api/scheduler/jobs" + query({ program })),
      job: (id) => API.request("GET", `/api/scheduler/jobs/${id}`),
      create: (body) => API.request("POST", "/api/scheduler/jobs", body),
      update: (id, body) => API.request("PUT", `/api/scheduler/jobs/${id}`, body),
      remove: (id) => API.request("DELETE", `/api/scheduler/jobs/${id}`),
      run: (id, params) => API.request("POST", `/api/scheduler/jobs/${id}/run`, { params: params || null }),
      pause: (id) => API.request("POST", `/api/scheduler/jobs/${id}/pause`, {}),
      resume: (id) => API.request("POST", `/api/scheduler/jobs/${id}/resume`, {}),
      skipNext: (id) => API.request("POST", `/api/scheduler/jobs/${id}/skip-next`, {}),
      preview: (id) => API.request("GET", `/api/scheduler/jobs/${id}/preview?n=10`),
      occurrences: (id) => API.request("GET", `/api/scheduler/jobs/${id}/occurrences?limit=50`),
      holidays: () => API.request("GET", "/api/scheduler/holidays"),
      saveHoliday: (day, description) => API.request("PUT", `/api/scheduler/holidays/${enc(day)}`, { description }),
      deleteHoliday: (day) => API.request("DELETE", `/api/scheduler/holidays/${enc(day)}`),
      notifications: (unread) => API.request("GET", "/api/scheduler/notifications" + query({ unread: unread ? 1 : undefined })),
      markRead: (id) => API.request("POST", `/api/scheduler/notifications/${id}/read`, {}),
    },

    license: () => API.request("GET", "/api/license"),
    admin: {
      license: () => API.request("GET", "/api/admin/license"),
      installLicense: (text) => API.request("POST", "/api/admin/license", { text }),
      users: (search) => API.request("GET", "/api/admin/users" + query({ search })),
      createUser: (body) => API.request("POST", "/api/admin/users", body),
      updateUser: (u, body) => API.request("PUT", `/api/admin/users/${enc(u)}`, body),
      resetPassword: (u) => API.request("POST", `/api/admin/users/${enc(u)}/password`, {}),
      revokeSessions: (u) => API.request("POST", `/api/admin/users/${enc(u)}/sessions/revoke`, {}),
      unlock: (u) => API.request("POST", `/api/admin/users/${enc(u)}/unlock`, {}),
      unlockIp: (ip) => API.request("POST", "/api/admin/security/unlock-ip", { ip }),
      keys: (u) => API.request("GET", `/api/admin/users/${enc(u)}/keys`),
      createKey: (u, body) => API.request("POST", `/api/admin/users/${enc(u)}/keys`, body),
      revokeKey: (id) => API.request("DELETE", `/api/admin/keys/${id}`),
      groups: () => API.request("GET", "/api/admin/groups"),
      saveGroup: (n, body) => API.request("PUT", `/api/admin/groups/${enc(n)}`, body),
      deleteGroup: (n) => API.request("DELETE", `/api/admin/groups/${enc(n)}`),
      settings: () => API.request("GET", "/api/admin/settings"),
      saveSetting: (k, value) => API.request("PUT", `/api/admin/settings/${enc(k)}`, { value }),
      company: () => API.request("GET", "/api/admin/company"),
      saveCompany: (body) => API.request("PUT", "/api/admin/company", body),
      defaultAccounts: () => API.request("GET", "/api/admin/default-accounts"),
      saveDefaultAccount: (k, account) => API.request("PUT", `/api/admin/default-accounts/${enc(k)}`, { account }),
      remoteSystems: () => API.request("GET", "/api/admin/remote-systems"),
      saveRemoteSystem: (n, body) => API.request("PUT", `/api/admin/remote-systems/${enc(n)}`, body),
      limitProfiles: () => API.request("GET", "/api/admin/limit-profiles"),
      saveLimitProfile: (kind, target, limits) => API.request("PUT", `/api/admin/limit-profiles/${enc(kind)}/${enc(target)}`, { limits }),
      deleteLimitProfile: (kind, target) => API.request("DELETE", `/api/admin/limit-profiles/${enc(kind)}/${enc(target)}`),
      quota: (u) => API.request("GET", `/api/admin/quotas/${enc(u)}`),
      saveQuota: (u, body) => API.request("PUT", `/api/admin/quotas/${enc(u)}`, body),
      consumption: (days) => API.request("GET", `/api/admin/consumption?days=${days}`),
      monitor: () => API.request("GET", "/api/admin/monitor"),
      stopExecution: (id) => API.request("POST", `/api/admin/executions/${enc(id)}/stop`, {}),
      audit: (kind, filters) => API.request("GET", `/api/admin/audit/${kind}` + query(filters)),
      execution: (id) => API.request("GET", `/api/admin/audit/executions/${enc(id)}`),
      retention: () => API.request("GET", "/api/admin/retention"),
      obsHealth: () => API.request("GET", "/api/admin/observability/health"),
      obsCheck: () => API.request("POST", "/api/admin/observability/health/check", {}),
      obsSql: (filters) => API.request("GET", "/api/admin/observability/sql" + query(filters || {})),
      obsSqlDetail: (hash) => API.request("GET", `/api/admin/observability/sql/${enc(hash)}`),
      obsFlush: () => API.request("POST", "/api/admin/observability/sql/flush", {}),
      obsSamples: (hours) => API.request("GET", "/api/admin/observability/samples" + query({ hours })),
      advice: (status) => API.request("GET", "/api/admin/observability/advice" + query(status ? { status } : {})),
      adviceRun: () => API.request("POST", "/api/admin/observability/advice/run", {}),
      adviceDismiss: (id, days) => API.request("POST", `/api/admin/observability/advice/${id}/dismiss`, { days }),
      checks: (filters) => API.request("GET", "/api/admin/checks" + query(filters || {})),
      checksRun: (category) => API.request("POST", "/api/admin/checks/run", { category }),
      checksInventory: () => API.request("GET", "/api/admin/checks/inventory"),
      checksImport: (blob) => API.raw("POST", "/api/admin/checks/vulnerabilities", blob),
      transports: () => API.request("GET", "/api/admin/transports"),
      transport: (id) => API.request("GET", `/api/admin/transports/${id}`),
      transportKey: () => API.request("GET", "/api/admin/transports/key"),
      transportOrigins: () => API.request("GET", "/api/admin/transports/origins"),
      saveOrigin: (name, public_key) => API.request("PUT", `/api/admin/transports/origins/${encodeURIComponent(name)}`, { public_key }),
      deleteOrigin: (name) => API.request("DELETE", `/api/admin/transports/origins/${encodeURIComponent(name)}`),
      exportTransport: (body) => API.request("POST", "/api/admin/transports/export", body),
      receiveTransport: (blob) => API.raw("POST", "/api/admin/transports/receive", blob),
      importTransport: (id, body) => API.request("POST", `/api/admin/transports/${id}/import`, body, { accept: [409] }),
      revertTransport: (id) => API.request("POST", `/api/admin/transports/${id}/revert`, {}),
      refuseTransport: (id, reason) => API.request("POST", `/api/admin/transports/${id}/refuse`, { reason }),
      copies: () => API.request("GET", "/api/admin/datacopy"),
      copyExport: () => API.request("POST", "/api/admin/datacopy/export", {}),
      copyUpload: (blob) => API.raw("POST", "/api/admin/datacopy/upload", blob),
      copyImport: (id, body) => API.request("POST", `/api/admin/datacopy/${id}/import`, body),
      masking: () => API.request("GET", "/api/admin/datacopy/masking"),
      saveMasking: (body) => API.request("PUT", "/api/admin/datacopy/masking", body),
      instance: () => API.request("GET", "/api/admin/instance"),
      apiClients: () => API.request("GET", "/api/admin/api-clients"),
      createApiClient: (body) => API.request("POST", "/api/admin/api-clients", body),
      updateApiClient: (id, body) => API.request("PUT", `/api/admin/api-clients/${encodeURIComponent(id)}`, body),
      rotateApiSecret: (id) => API.request("POST", `/api/admin/api-clients/${encodeURIComponent(id)}/rotate-secret`, {}),
      dropOldApiSecret: (id) => API.request("POST", `/api/admin/api-clients/${encodeURIComponent(id)}/drop-old-secret`, {}),
      apiSigningSecret: (id) => API.request("POST", `/api/admin/api-clients/${encodeURIComponent(id)}/signing-secret`, {}),
      apiCalls: (client) => API.request("GET", "/api/admin/api-calls" + query({ client })),
      rotateApiKeys: () => API.request("POST", "/api/admin/api-keys/rotate", {}),
      notices: (unread) => API.request("GET", "/api/admin/checks/notices" + query(unread ? { unread: 1 } : {})),
      noticeRead: (id) => API.request("POST", `/api/admin/checks/notices/${id}/read`, {}),
      connectors: () => API.request("GET", "/api/admin/connectors"),
      saveConnector: (name, body) => API.request("PUT", `/api/admin/connectors/${encodeURIComponent(name)}`, body),
      saveSecret: (name, key, value, expires_at) =>
        API.request("PUT", `/api/admin/connectors/${encodeURIComponent(name)}/secrets/${key}`, { value, expires_at: expires_at || null }),
      deleteSecret: (name, key) => API.request("DELETE", `/api/admin/connectors/${encodeURIComponent(name)}/secrets/${key}`),
      integrationStats: () => API.request("GET", "/api/admin/integrations/stats"),
      integrationMessages: (q) => API.request("GET", "/api/admin/integrations/messages" + query(q)),
      integrationAction: (kind, id, action) => API.request("POST", `/api/admin/integrations/${kind}/${id}/${action}`, {}),
      productUpdates: () => API.request("GET", "/api/admin/product-updates"),
      productUpdate: (name) => API.request("GET", `/api/admin/product-updates/${encodeURIComponent(name)}`),
      productUpdatesCheck: () => API.request("POST", "/api/admin/product-updates/check", {}),
      productUpdateAccept: (name, overwrite) =>
        API.request("POST", `/api/admin/product-updates/${encodeURIComponent(name)}/accept`, { overwrite: !!overwrite }),
      productUpdateDismiss: (name) => API.request("POST", `/api/admin/product-updates/${encodeURIComponent(name)}/dismiss`, {}),
      productUpdatesAcceptUnmodified: () => API.request("POST", "/api/admin/product-updates/accept-unmodified", {}),
      purge: () => API.request("POST", "/api/admin/retention/purge", {}),
    },
  };

  window.AnaApi = API;
  window.AnaApiError = ApiError;
})();
