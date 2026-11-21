# ana:description Geração de PDF simples (texto, linhas, tabelas, logotipo JPEG, timbre da empresa) sem dependências
# ana:kind library
"""Minimal PDF 1.4 writer: A4 pages, Helvetica (regular/bold) in WinAnsi, text, lines
and simple tables. Usage:

    from ana_lib.util.pdf import Pdf
    doc = Pdf(title="Fatura 12")
    doc.text(50, 790, "Fatura de serviços", size=16, bold=True)
    doc.table(50, 740, ["Descrição", "Valor"], [["Horas", "R$ 1.000,00"]], widths=[380, 120])
    data = doc.build()          # bytes

Spec 009 (D11): `letterhead()` draws the company's logo and name (the customer's brand) and every page
ends with "Emitido com ANA ERP" (ANA's identity stays).
"""

import base64

A4 = (595, 842)
FOOTER = "Emitido com ANA ERP"


def jpeg_size(data):
    """(width, height, components) of a baseline or progressive JPEG; None when it is not one."""
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            return None
        marker, length = data[i + 1], int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big"), data[i + 9]
        i += 2 + length
    return None


def company():
    """The company for letterheads (one row)."""
    import ana
    return ana.sql_one("SELECT legal_name, display_name, tax_id, address, city, state, phone, email, logo "
                       "FROM base.company ORDER BY id LIMIT 1") or {}


def _esc(s):
    raw = str(s).encode("cp1252", errors="replace")
    return raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


class Pdf:
    def __init__(self, title=""):
        self.title = title
        self.pages = []
        self.images = []          # JPEG streams: (data, width, height, components)
        self.new_page()

    def new_page(self):
        self.pages.append([])
        return self

    def text(self, x, y, s, size=10, bold=False):
        font = "F2" if bold else "F1"
        self.pages[-1].append(b"BT /%s %d Tf %.2f %.2f Td (" % (font.encode(), size, x, y) + _esc(s) + b") Tj ET")
        return self

    def line(self, x1, y1, x2, y2, width=0.5):
        self.pages[-1].append(b"%.2f w %.2f %.2f m %.2f %.2f l S" % (width, x1, y1, x2, y2))
        return self

    def image_jpeg(self, data, x, y, max_w, max_h):
        """Draws a JPEG inside the box (x, y, max_w, max_h) keeping its proportion; returns the drawn width
        (0 when the data is not a JPEG)."""
        size = jpeg_size(data or b"")
        if not size or size[2] not in (1, 3):
            return 0
        w, h, comps = size
        scale = min(max_w / w, max_h / h)
        dw, dh = w * scale, h * scale
        self.images.append((data, w, h, comps))
        name = b"Im%d" % len(self.images)
        self.pages[-1].append(b"q %.2f 0 0 %.2f %.2f %.2f cm /%s Do Q" % (dw, dh, x, y + (max_h - dh), name))
        return dw

    def letterhead(self, c, lines=(), y=790):
        """The company's brand at the top-left: logo (if any) and name, then CNPJ and the given lines.
        Returns the x where the text starts (beside the logo)."""
        x = 50
        if c.get("logo"):
            try:
                drawn = self.image_jpeg(base64.b64decode(c["logo"]), 50, y - 34, 110, 44)
            except ValueError:
                drawn = 0
            x = 50 + (drawn + 10 if drawn else 0)
        self.text(x, y, c.get("display_name") or c.get("legal_name") or "", size=14, bold=True)
        yy = y - 14
        if c.get("display_name") and c.get("legal_name") and c["display_name"] != c["legal_name"]:
            self.text(x, yy, c["legal_name"], size=8)
            yy -= 11
        if c.get("tax_id"):
            self.text(x, yy, f"CNPJ {c['tax_id']}", size=9)
            yy -= 12
        for line in lines:
            if line:
                self.text(x, yy, line, size=8)
                yy -= 11
        return x

    def table(self, x, y, header, rows, widths, size=9, row_height=14, bottom=60):
        """Draws rows from (x, y) down; breaks pages; returns the y after the table."""
        def draw_row(cells, yy, bold=False):
            cx = x
            for c, w in zip(cells, widths):
                text = str(c if c is not None else "")
                limit = max(1, int(w / (size * 0.5)))
                self.text(cx + 2, yy, text if len(text) <= limit else text[:limit - 1] + "…", size=size, bold=bold)
                cx += w
        draw_row(header, y, bold=True)
        self.line(x, y - 4, x + sum(widths), y - 4)
        y -= row_height
        for r in rows:
            if y < bottom:
                self.new_page()
                y = A4[1] - 60
                draw_row(header, y, bold=True)
                self.line(x, y - 4, x + sum(widths), y - 4)
                y -= row_height
            draw_row(r, y)
            y -= row_height
        return y

    def build(self):
        objs = []

        def add(body):
            objs.append(body)
            return len(objs)

        catalog = add(None)
        pages_id = add(None)
        f1 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        f2 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        ims = []
        for data, w, h, comps in self.images:
            ims.append(add(b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /%s /BitsPerComponent 8 "
                           b"/Filter /DCTDecode /Length %d >>\nstream\n" % (w, h, b"DeviceRGB" if comps == 3 else b"DeviceGray", len(data))
                           + data + b"\nendstream"))
        xobjects = (b" /XObject << " + b" ".join(b"/Im%d %d 0 R" % (n, o) for n, o in enumerate(ims, start=1)) + b" >>") if ims else b""
        footer = b"BT /F1 7 Tf 50.00 28.00 Td (" + _esc(FOOTER) + b") Tj ET"
        kids = []
        for ops in self.pages:
            stream = b"\n".join(ops + [footer])
            content = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
            kids.append(add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                            b"/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >>%s >> >>"
                            % (pages_id, A4[0], A4[1], content, f1, f2, xobjects)))
        objs[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id
        objs[pages_id - 1] = (b"<< /Type /Pages /Count %d /Kids [" % len(kids)
                              + b" ".join(b"%d 0 R" % k for k in kids) + b"] >>")
        info = add(b"<< /Title (" + _esc(self.title) + b") /Producer (ANA ERP) >>")
        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for i, body in enumerate(objs, start=1):
            offsets.append(len(out))
            out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
        xref = len(out)
        out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
        for off in offsets:
            out += b"%010d 00000 n \n" % off
        out += b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            len(objs) + 1, catalog, info, xref)
        return bytes(out)
