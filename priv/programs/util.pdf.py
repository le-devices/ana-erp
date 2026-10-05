# ana:description Geração de PDF simples (texto, linhas, tabelas) sem dependências
# ana:kind library
"""Minimal PDF 1.4 writer: A4 pages, Helvetica (regular/bold) in WinAnsi, text, lines
and simple tables. Usage:

    from ana_lib.util.pdf import Pdf
    doc = Pdf(title="Fatura 12")
    doc.text(50, 790, "Fatura de serviços", size=16, bold=True)
    doc.table(50, 740, ["Descrição", "Valor"], [["Horas", "R$ 1.000,00"]], widths=[380, 120])
    data = doc.build()          # bytes
"""

A4 = (595, 842)


def _esc(s):
    raw = str(s).encode("cp1252", errors="replace")
    return raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


class Pdf:
    def __init__(self, title=""):
        self.title = title
        self.pages = []
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
        kids = []
        for ops in self.pages:
            stream = b"\n".join(ops)
            content = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
            kids.append(add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                            b"/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> >>"
                            % (pages_id, A4[0], A4[1], content, f1, f2)))
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
