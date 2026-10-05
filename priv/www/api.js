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

  const enc = encodeURIComponent;
  const query = (params) => {
    const q = Object.entries(params || {}).filter(([, v]) => v !== undefined && v !== null && v !== "")
      .map(([k, v]) => `${enc(k)}=${enc(v)}`).join("&");
    return q ? "?" + q : "";
  };

  const API = {
    onExpired: () => {},
    onPasswordRequired: () => {},
    get authenticated() { return !!token; },

    async request(method, path, body, options = {}) {
      const headers = { "Accept": "application/json" };
      if (token) headers["Authorization"] = "Bearer " + token;
      if (body !== undefined) headers["Content-Type"] = "application/json";
      const resp = await fetch(path, {
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

    admin: {
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
