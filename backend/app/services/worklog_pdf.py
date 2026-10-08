"""One work log as an A4 PDF. Long text flows across pages instead of table cells."""

from io import BytesIO
from xml.sax.saxutils import escape

from PIL import Image as PillowImage
from PIL import ImageOps
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
    log: dict,
    attachments: list[str],
    printed_at: str,
    logo: bytes | None = None,
    images: dict[str, bytes] | None = None,
) -> bytes:
    """images: 업무 사진 첨부 id -> 파일 내용. 없는 사진은 건너뛴다."""
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
        ],
        colWidths=[24 * mm, 61 * mm, 24 * mm, 61 * mm],
    )
    info.setStyle(
        TableStyle(
            [
                ("GRID", (0, 0), (-1, -1), 0.4, colors.black),
                ("BACKGROUND", (0, 0), (0, -1), GREY),
                ("BACKGROUND", (2, 0), (2, -1), GREY),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )

    def section(name, flowables):
        # Only the heading is kept with the first line; the rest may break across
        # pages. Tables repeat their header row instead, so they are not held.
        rule = HRFlowable(width="100%", thickness=0.4, color=colors.black, spaceAfter=4)
        rule.keepWithNext = not isinstance(flowables[0], Table)
        return [p(name, heading), rule, *flowables]

    def lines(text):
        # One paragraph per line avoids blank lines after full-width lines.
        return [
            p(line) if line.strip() else Spacer(1, body.leading)
            for line in ((text or "").strip() or "-").split("\n")
        ]

    story = [heading_row(p("근무일지", title), logo), Spacer(1, 6 * mm), info]
    story.append(Spacer(1, 4 * mm))
    tasks = log.get("tasks") or []
    if tasks:
        story += section("오전 · 오후 업무", [period_chart(tasks, p)])
        story += section(
            "금일 업무 내용 요약",
            [p(f"{i}. {t['title']}") for i, t in enumerate(tasks, 1)],
        )
        story += section("금일 업무 내용 상세", [detail_chart(tasks, p)])
        photos = photo_blocks(tasks, images or {}, p, heading)
        if photos:
            story += section("업무 사진", photos)
    else:
        # 업무 목록이 생기기 전에 쓴 일지.
        if (log["morning"] or "").strip() or (log["afternoon"] or "").strip():
            story += section("오전 · 오후 업무", [legacy_period_chart(log, p)])
        story += section("금일 업무 내용 요약", lines(log["summary"]))
        story += section("금일 근무 내용 상세", lines(log["detail"]))
    if log["overtime_minutes"]:
        story += section(
            f"연장 근무 사유 ({hours_label(log['overtime_minutes'])})",
            lines(log["overtime_note"]),
        )
    story += section("예정 업무", lines(log["plan"]))
    story += section("필요/요청사항", lines(log["needs"]))
    story += section("첨부 파일", lines("\n".join(attachments)))

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
                ("BACKGROUND", (0, 0), (0, -1), GREY),
                ("BACKGROUND", (2, 0), (2, -1), GREY),
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
                    ("BACKGROUND", (0, 0), (-1, 0), GREY),
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


GREY = colors.Color(0.94, 0.94, 0.94)
PERIODS = (("AM", "오전"), ("PM", "오후"))


def _ruled(rows, widths, rule_after, extra=()):
    """머리글 한 줄 + 묶음 끝마다 가로줄. 칸을 합치지 않아 쪽을 넘겨도 깨지지 않는다."""
    table = LongTable(rows, colWidths=widths, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.4, colors.black),
                ("INNERGRID", (0, 0), (-1, 0), 0.4, colors.black),
                ("LINEBELOW", (0, 0), (-1, 0), 0.4, colors.black),
                ("BACKGROUND", (0, 0), (-1, 0), GREY),
                ("LINEAFTER", (0, 0), (-2, -1), 0.4, colors.black),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
                *[
                    ("LINEBELOW", (0, r), (-1, r), 0.4, colors.black)
                    for r in rule_after
                ],
                *extra,
            ]
        )
    )
    return table


def period_chart(tasks: list[dict], p) -> LongTable:
    """오전 묶음 아래 오후 묶음. 업무마다 한 줄: 구분 · 출장지 · 업무 제목."""
    rows = [[p("시간대"), p("구분"), p("출장지"), p("업무 제목")]]
    rule_after, shade = [], []
    for code, label in PERIODS:
        mine = [t for t in tasks if t["period"] == code] or [None]
        first = len(rows)
        for i, t in enumerate(mine):
            rows.append(
                [
                    p(label if i == 0 else ""),
                    p("-" if t is None else "출장" if t["kind"] == "TRIP" else "사무"),
                    p((t or {}).get("location") or "-"),
                    p("-" if t is None else t["title"]),
                ]
            )
        rule_after.append(len(rows) - 1)
        shade.append(("BACKGROUND", (0, first), (0, len(rows) - 1), GREY))
    return _ruled(rows, [20 * mm, 22 * mm, 40 * mm, 88 * mm], rule_after, shade)


def detail_chart(tasks: list[dict], p) -> LongTable:
    """업무마다 번호 · 업무(시간대 · 구분) · 상세 내용. 상세는 한 줄이 한 행."""
    rows = [[p("No"), p("업무"), p("상세 내용")]]
    rule_after = []
    for i, t in enumerate(tasks, 1):
        place = f"출장 · {t['location']}" if t["kind"] == "TRIP" else "사무"
        when = dict(PERIODS)[t["period"]]
        detail = ((t.get("detail") or "").strip() or "-").split("\n")
        # 업무 칸: 첫 행 제목, 둘째 행 시간대 · 구분. 상세가 한 줄이면 빈 행을 하나 둔다.
        labels = [t["title"], f"({when} · {place})"]
        for j in range(max(len(detail), 2)):
            rows.append(
                [
                    p(str(i) if j == 0 else ""),
                    p(labels[j] if j < 2 else ""),
                    p(detail[j] if j < len(detail) else ""),
                ]
            )
        rule_after.append(len(rows) - 1)
    return _ruled(rows, [12 * mm, 52 * mm, 106 * mm], rule_after)


def legacy_period_chart(log: dict, p) -> LongTable:
    """업무 목록 이전 일지의 오전 · 오후 글. 위아래로."""
    rows = [[p("시간대"), p("업무")]]
    rule_after = []
    for field, label in (("morning", "오전"), ("afternoon", "오후")):
        text = (log[field] or "").strip() or "-"
        for i, line in enumerate(text.split("\n")):
            rows.append([p(label if i == 0 else ""), p(line)])
        rule_after.append(len(rows) - 1)
    return _ruled(rows, [20 * mm, 150 * mm], rule_after)


PHOTO_W, PHOTO_H = 80 * mm, 60 * mm


def _photo(data: bytes) -> Image | None:
    """세로·가로를 바로잡고 줄여서 넣는다. 열 수 없는 파일이면 None."""
    try:
        with PillowImage.open(BytesIO(data)) as original:
            picture = ImageOps.exif_transpose(original).convert("RGB")
            # 80mm 칸에 약 500dpi. 고급 축소로 줄여 경계가 깨지지 않게 한다.
            picture.thumbnail((1600, 1600), PillowImage.Resampling.LANCZOS)
            output = BytesIO()
            picture.save(output, format="JPEG", quality=90)
    except (OSError, ValueError):
        return None
    output.seek(0)
    image = Image(output)
    scale = min(PHOTO_W / image.imageWidth, PHOTO_H / image.imageHeight)
    image.drawWidth = image.imageWidth * scale
    image.drawHeight = image.imageHeight * scale
    return image


def photo_blocks(tasks: list[dict], images: dict[str, bytes], p, heading) -> list:
    """업무마다 사진을 두 장씩 나란히, 사진 아래에 코멘트."""
    blocks = []
    for number, task in enumerate(tasks, 1):
        cells = []
        for item in task.get("images") or []:
            picture = images.get(item["attachment_id"])
            image = _photo(picture) if picture else None
            if image is None:
                continue
            cells.append(
                [
                    image,
                    Spacer(1, 2 * mm),
                    p((item.get("comment") or "").strip() or "-"),
                ]
            )
        if not cells:
            continue
        if len(cells) % 2:
            cells.append("")
        grid = Table(
            [cells[i : i + 2] for i in range(0, len(cells), 2)],
            colWidths=[85 * mm, 85 * mm],
        )
        grid.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("ALIGN", (0, 0), (-1, -1), "CENTER"),
                    ("BOX", (0, 0), (-1, -1), 0.4, colors.black),
                    ("INNERGRID", (0, 0), (-1, -1), 0.4, colors.black),
                    ("TOPPADDING", (0, 0), (-1, -1), 4),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ]
            )
        )
        title = p(f"{number}. {task['title']}", heading)
        # 제목(keepWithNext)은 사진 표와 함께 넘어가고, 표는 사진 행 단위로 쪽을 나눈다.
        blocks += [title, grid]
    return blocks
