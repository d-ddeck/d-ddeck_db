"""Company quotation layout with embedded Korean font and multi-page item rows."""

from functools import lru_cache
from io import BytesIO
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    KeepTogether,
    LongTable,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


@lru_cache(maxsize=1)
def font_name():
    name = "DdeckNanum"
    pdfmetrics.registerFont(
        TTFont(
            name,
            str(
                Path(__file__).resolve().parents[1]
                / "assets/fonts/NanumGothic-Regular.ttf"
            ),
        )
    )
    return name


def render(snapshot: dict) -> bytes:
    buffer = BytesIO()
    font = font_name()
    style = ParagraphStyle(
        "body", fontName=font, fontSize=9, leading=14, wordWrap="CJK"
    )
    title_style = ParagraphStyle(
        "title", parent=style, fontSize=22, leading=30, alignment=TA_CENTER
    )

    def p(text):
        return Paragraph(escape(str(text)).replace("\n", "<br/>"), style)

    def table(rows, widths, header=False):
        t = Table(
            [[p(c) for c in row] for row in rows], colWidths=widths, hAlign="LEFT"
        )
        commands = [
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#8692a3")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 7),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
        ]
        if header:
            commands.extend([("SPAN", (0, 0), (1, 0)), ("SPAN", (2, 0), (3, 0))])
            commands.append(("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#edf1f7")))
        t.setStyle(TableStyle(commands))
        return t

    money = lambda n: f"{int(n):,}"
    supplier, recipient = snapshot["supplier"], snapshot["recipient"]
    story = [Paragraph("D.DDECK &nbsp; 견 적 서", title_style), Spacer(1, 16)]
    story += [
        table(
            [
                [
                    "문서번호",
                    snapshot["document_no"],
                    "견적일자",
                    snapshot["quote_date"],
                ],
                [
                    "입금계좌",
                    snapshot["bank_account"],
                    "유효기간",
                    snapshot["valid_until"],
                ],
            ],
            [55, 215, 55, 190],
        ),
        Spacer(1, 12),
    ]
    rows = [["공급자 정보", "", "수신자 정보", ""]]
    for label, key, recipient_label in [
        ("회사명", "company", "회사명"),
        ("대표자", "contact", "담당자"),
        ("주소", "address", "주소"),
        ("전화번호", "phone", "연락처"),
        ("E-mail", "email", "E-mail"),
    ]:
        rows.append([label, supplier[key], recipient_label, recipient[key]])
    story += [
        table(rows, [55, 202.5, 55, 202.5], True),
        Spacer(1, 12),
        p("공급합계금액: ₩ " + money(snapshot["subtotal"]) + " (부가세 별도)"),
        Spacer(1, 10),
    ]
    rows = [
        [
            p(x)
            for x in [
                "No.",
                "품목",
                "규격/사양",
                "수량",
                "단가(원)",
                "공급가액(원)",
                "비고",
            ]
        ]
    ]
    for i, item in enumerate(snapshot["items"], 1):
        rows.append(
            [
                p(v)
                for v in [
                    i,
                    item["name"],
                    item["specification"],
                    item["quantity"],
                    money(item["unit_price"]),
                    money(item["amount"]),
                    item["note"],
                ]
            ]
        )
    while len(rows) < 5:
        rows.append([p("") for _ in range(7)])
    items = LongTable(
        rows, colWidths=[25, 98, 108, 40, 73, 85, 86], repeatRows=1, hAlign="LEFT"
    )
    items.setStyle(
        TableStyle(
            [
                ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#8692a3")),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#edf1f7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("TOPPADDING", (0, 0), (-1, -1), 8),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
            ]
        )
    )
    story += [
        items,
        Spacer(1, 10),
        KeepTogether(
            [
                table(
                    [
                        ["공급가액", money(snapshot["subtotal"])],
                        ["부가세 (10%)", money(snapshot["vat"])],
                        ["합계금액", money(snapshot["total"])],
                    ],
                    [350, 165],
                ),
                Spacer(1, 12),
            ]
        ),
    ]
    story += [
        p("[ 안내사항 ]"),
        p(snapshot["notes"] or "-"),
        Spacer(1, 18),
        p("상기와 같이 견적서를 제출합니다."),
        p(f"{supplier['company']}  대표 {supplier['contact']} (인)"),
    ]

    def footer(canvas, doc):
        canvas.setFont(font, 8)
        canvas.drawString(40, 25, snapshot["document_no"])
        canvas.drawRightString(A4[0] - 40, 25, f"{doc.page} 페이지")

    SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=40,
        rightMargin=40,
        topMargin=36,
        bottomMargin=45,
        title=snapshot["document_no"],
        author=supplier["company"],
    ).build(story, onFirstPage=footer, onLaterPages=footer)
    return buffer.getvalue()
