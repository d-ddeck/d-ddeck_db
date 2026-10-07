"""One work log as an A4 PDF. Long text flows across pages instead of table cells."""

from io import BytesIO
from xml.sax.saxutils import escape

from PIL import Image as PillowImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    HRFlowable,
    Image,
    LongTable,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

from app.services.quotation_pdf import font_name


def render(
    log: dict, attachments: list[str], printed_at: str, logo: bytes | None = None
) -> bytes:
    buffer = BytesIO()
    font = font_name()
    body = ParagraphStyle(
        "body", fontName=font, fontSize=10, leading=16, wordWrap="CJK"
    )
    title = ParagraphStyle(
        "title", parent=body, fontSize=20, leading=28, alignment=TA_CENTER
    )
    heading = ParagraphStyle(
        "heading",
        parent=body,
        fontSize=12,
        leading=18,
        spaceBefore=10,
        spaceAfter=4,
        keepWithNext=1,
    )

    def p(text, style=body):
        return Paragraph(escape(str(text)).replace("\n", "<br/>"), style)

    info = Table(
        [
            [
                p("일자"),
                p(log["work_date"]),
                p("근무 시간"),
                p(f"{log['work_start']} ~ {log['work_end']}"),
            ],
            [p("작성자"), p(log["author_name"]), p("직급"), p(log["position"] or "-")],
            [
                p("연장 근무"),
                p(duration(log["overtime_minutes"])),
                p("문서번호"),
                p(log["document_no"]),
            ],
        ],
        colWidths=[24 * mm, 61 * mm, 24 * mm, 61 * mm],
    )
    info.setStyle(
        TableStyle(
            [
                ("GRID", (0, 0), (-1, -1), 0.4, colors.black),
                ("BACKGROUND", (0, 0), (0, -1), colors.Color(0.94, 0.94, 0.94)),
                ("BACKGROUND", (2, 0), (2, -1), colors.Color(0.94, 0.94, 0.94)),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )

    story = [heading_row(p("근무일지", title), logo), Spacer(1, 6 * mm), info]
    story.append(Spacer(1, 4 * mm))
    if (log["morning"] or "").strip() or (log["afternoon"] or "").strip():
        story += [p("오전 · 오후 업무", heading), half_day_chart(log, p)]
    sections = [
        ("금일 업무 내용 요약", log["summary"]),
        ("금일 근무 내용 상세", log["detail"]),
    ]
    if log["overtime_minutes"]:
        sections.append(("연장 근무 사유", log["overtime_note"]))
    sections += [
        ("예정 업무", log["plan"]),
        ("필요/요청사항", log["needs"]),
        ("첨부 파일", "\n".join(attachments)),
    ]
    for name, text in sections:
        # Only the heading is kept with the first line; long text breaks across
        # pages. One paragraph per line avoids blank lines after full-width lines.
        rule = HRFlowable(width="100%", thickness=0.4, color=colors.black, spaceAfter=4)
        rule.keepWithNext = True
        story += [p(name, heading), rule]
        lines = ((text or "").strip() or "-").split("\n")
        story += [
            p(line) if line.strip() else Spacer(1, body.leading) for line in lines
        ]

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont(font, 8)
        canvas.setFillColor(colors.grey)
        canvas.drawString(20 * mm, 10 * mm, f"출력 {printed_at}")
        canvas.drawRightString(A4[0] - 20 * mm, 10 * mm, f"{doc.page}")
        canvas.restoreState()

    SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=20 * mm,
        rightMargin=20 * mm,
        topMargin=18 * mm,
        bottomMargin=18 * mm,
        title=f"{log['work_date']} 근무일지 - {log['author_name']}",
    ).build(story, onFirstPage=footer, onLaterPages=footer)
    return buffer.getvalue()


def hours_label(minutes: int) -> str:
    """150 -> "2시간 30분" """
    hours, rest = divmod(minutes, 60)
    parts = [f"{hours}시간" if hours else "", f"{rest}분" if rest or not hours else ""]
    return " ".join(part for part in parts if part)


def duration(minutes: int) -> str:
    return f"O ({hours_label(minutes)})" if minutes else "X"


def heading_row(title, logo: bytes | None):
    """Title centred with the company logo at the top right, as on quotations."""
    if not logo:
        return title
    # Composite transparent artwork on paper and embed in grayscale, like quotations.
    with PillowImage.open(BytesIO(logo)) as original:
        rgba = original.convert("RGBA")
        paper = PillowImage.new("RGBA", rgba.size, "white")
        paper.alpha_composite(rgba)
        output = BytesIO()
        paper.convert("L").save(output, format="PNG")
    output.seek(0)
    image = Image(output)
    scale = min(58 / image.imageWidth, 48 / image.imageHeight)
    image.drawWidth = image.imageWidth * scale
    image.drawHeight = image.imageHeight * scale
    image.hAlign = "RIGHT"
    row = Table([["", title, image]], colWidths=[40 * mm, 90 * mm, 40 * mm])
    row.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("ALIGN", (2, 0), (2, 0), "RIGHT"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    return row


def render_overtime(summary: dict, printed_at: str, logo: bytes | None = None) -> bytes:
    """A month of overtime: totals and the per-day reasons table."""
    buffer = BytesIO()
    font = font_name()
    body = ParagraphStyle("body", fontName=font, fontSize=9, leading=14, wordWrap="CJK")
    title = ParagraphStyle(
        "title", parent=body, fontSize=20, leading=28, alignment=TA_CENTER
    )
    heading = ParagraphStyle(
        "heading", parent=body, fontSize=12, leading=18, spaceBefore=10, spaceAfter=4
    )

    def p(text, style=body):
        return Paragraph(escape(str(text)).replace("\n", "<br/>"), style)

    items = summary["items"]
    period = f"{summary['year']}년 {summary['month']}월"
    grey = colors.Color(0.94, 0.94, 0.94)
    info = Table(
        [
            [p("대상 기간"), p(period), p("작성자"), p(summary["author_name"])],
            [
                p("총 연장근무"),
                p(
                    hours_label(summary["total_minutes"])
                    if summary["total_minutes"]
                    else "없음"
                ),
                p("직급 · 연장 일수"),
                p(f"{summary['position'] or '-'} · {len(items)}일"),
            ],
        ],
        colWidths=[24 * mm, 61 * mm, 28 * mm, 57 * mm],
    )
    info.setStyle(
        TableStyle(
            [
                ("GRID", (0, 0), (-1, -1), 0.4, colors.black),
                ("BACKGROUND", (0, 0), (0, -1), grey),
                ("BACKGROUND", (2, 0), (2, -1), grey),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story = [
        heading_row(p(f"연장근무 종합 · {period}", title), logo),
        Spacer(1, 6 * mm),
        info,
    ]
    if not items:
        story += [Spacer(1, 6 * mm), p("이 달에는 18:00 이후 연장 근무가 없습니다.")]
    else:
        rows = [[p("날짜"), p("근무시간"), p("연장 시간"), p("사유")]] + [
            [
                p(i["work_date"]),
                p(f"{i['work_start']} ~ {i['work_end']}"),
                p(hours_label(i["minutes"])),
                p((i["reason"] or "").strip() or "-"),
            ]
            for i in items
        ]
        table = LongTable(
            rows, colWidths=[24 * mm, 30 * mm, 26 * mm, 90 * mm], repeatRows=1
        )
        table.setStyle(
            TableStyle(
                [
                    ("GRID", (0, 0), (-1, -1), 0.4, colors.black),
                    ("BACKGROUND", (0, 0), (-1, 0), grey),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("TOPPADDING", (0, 0), (-1, -1), 5),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                ]
            )
        )
        story += [p("연장근무 내역", heading), table]

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont(font, 8)
        canvas.setFillColor(colors.grey)
        canvas.drawString(
            20 * mm,
            10 * mm,
            f"출력 {printed_at} · 정규 근무 09:00~18:00, 18:00 이후 근무 집계",
        )
        canvas.drawRightString(A4[0] - 20 * mm, 10 * mm, f"{doc.page}")
        canvas.restoreState()

    SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=20 * mm,
        rightMargin=20 * mm,
        topMargin=18 * mm,
        bottomMargin=18 * mm,
        title=f"연장근무 종합 {period} - {summary['author_name']}",
    ).build(story, onFirstPage=footer, onLaterPages=footer)
    return buffer.getvalue()


def half_day_chart(log: dict, p) -> LongTable:
    """오전·오후 업무를 나란히 놓은 표. 한 줄이 한 행이라 길어도 쪽을 넘길 수 있다."""
    morning = (log["morning"] or "").strip().split("\n")
    afternoon = (log["afternoon"] or "").strip().split("\n")
    count = max(len(morning), len(afternoon))
    rows = [[p("오전 업무"), p("오후 업무")]] + [
        [
            p(morning[i] if i < len(morning) else ""),
            p(afternoon[i] if i < len(afternoon) else ""),
        ]
        for i in range(count)
    ]
    table = LongTable(rows, colWidths=[85 * mm, 85 * mm], repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.4, colors.black),
                ("LINEAFTER", (0, 0), (0, -1), 0.4, colors.black),
                ("LINEBELOW", (0, 0), (-1, 0), 0.4, colors.black),
                ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0.94, 0.94, 0.94)),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table
