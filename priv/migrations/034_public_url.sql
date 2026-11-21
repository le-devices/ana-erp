-- 034 — Public address of the ERP, edited by an administrator (spec 037 follow-up).
-- Used in download links sent to customers; empty = the installer's ANA_PUBLIC_URL.
ALTER TABLE base.company ADD COLUMN public_url text
    CHECK (public_url ~ '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$');
