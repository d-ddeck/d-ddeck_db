"""구 서버(CS_Record)의 서비스구분 · 세부분류를 그대로 되살린다 (2026-09-25).

왜 필요한가
  * 이관(migrate_from_legacy.py) 때 세부분류를 **이름만으로** 맞춰, '로봇팔 > 엔코더'와
    '전동 그리퍼 > 엔코더'처럼 이름이 같은 세부분류가 한 항목으로 합쳐졌다. 89개 중 30개
    남짓이 잘못된 서비스구분 아래로 들어갔고, 그 항목을 쓰는 원인 줄도 같이 틀렸다.
  * 관리 화면에서 기본 분류(설치·수리·…·기타)를 지울 때 구 서버의 '기타' 구분(이름이 같아
    합쳐져 있었다)과 그 세부분류가 함께 지워졌다.

무엇을 하나 (구 서버 cs.db 의 lists · record_causes 기준)
  1) 서비스구분 12개: 이름으로 찾아 삭제됐으면 되살리고 없으면 만들며 순서·사용 여부를 맞춘다.
  2) 세부분류 89개: (구분, 이름) 쌍으로 찾아 없으면 만들고, 순서·사용 여부를 맞춘다.
     이름만 같아 합쳐졌던 항목은 원래 구분(먼저 만들어진 쪽)에 그대로 둔다.
  3) 이관된 대응 기록의 원인 줄(legacy_no, seq)마다 구분·세부를 구 서버 값대로 다시 가리킨다.
     기록의 대표 구분·세부(첫 원인)도 같이.
  4) 그 뒤 아무 데서도 안 쓰는 '상위 없는' 기본 세부분류(전원 불량 …)는 삭제한다.
  5) 그룹 이름을 구 서버 용어(서비스구분 · 세부분류)로.

사용
  python scripts/fix_legacy_symptoms.py --source ../beforeserver            # 미리 보기
  python scripts/fix_legacy_symptoms.py --source ../beforeserver --apply    # 반영
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.core.database import SessionLocal
from app.core.security import now_utc
from app.models.admin import CodeGroup, CodeItem
from app.models.service import ServiceTicket, ServiceTicketCause
from scripts.migrate_from_legacy import code_for
from sqlalchemy import func, select

GROUP_NAMES = {"SERVICE_CATEGORY": "서비스구분", "SERVICE_SYMPTOM": "세부분류"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source", required=True, help="구 서버 백업 폴더 (cs.db 가 있는 곳)"
    )
    ap.add_argument(
        "--apply", action="store_true", help="실제로 반영한다 (없으면 미리 보기)"
    )
    args = ap.parse_args()
    src_path = Path(args.source).expanduser().resolve() / "cs.db"
    if not src_path.exists():
        sys.exit(f"cs.db 를 찾을 수 없습니다: {src_path}")
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)

    legacy_cats = src.execute(
        "SELECT value, sort, active FROM lists WHERE kind='category' ORDER BY sort, rowid"
    ).fetchall()
    legacy_details = src.execute(
        "SELECT parent, value, sort, active FROM lists WHERE kind='detail' ORDER BY sort, rowid"
    ).fetchall()
    legacy_causes = src.execute(
        "SELECT record_no, seq, category, detail FROM record_causes ORDER BY record_no, seq"
    ).fetchall()

    db = SessionLocal()
    report: list[str] = []
    try:
        cat_group = db.scalar(
            select(CodeGroup).where(CodeGroup.code == "SERVICE_CATEGORY")
        )
        sym_group = db.scalar(
            select(CodeGroup).where(CodeGroup.code == "SERVICE_SYMPTOM")
        )
        if cat_group is None or sym_group is None:
            sys.exit("SERVICE_CATEGORY / SERVICE_SYMPTOM 그룹이 없습니다.")

        # ---------------------------------------------------------------- 1) 서비스구분
        cats_all = db.scalars(
            select(CodeItem).where(CodeItem.group_id == cat_group.id)
        ).all()
        by_name: dict[str, CodeItem] = {}
        for it in sorted(
            cats_all, key=lambda i: (i.deleted_at is not None, i.sort_order)
        ):
            by_name.setdefault(it.name, it)  # 살아 있는 것 우선
        restored = created = 0
        for value, sort, active in legacy_cats:
            item = by_name.get(value)
            if item is None:
                item = CodeItem(
                    group_id=cat_group.id,
                    code=code_for(value),
                    name=value,
                    sort_order=sort,
                    is_active=bool(active),
                )
                db.add(item)
                by_name[value] = item
                created += 1
                report.append(f"  구분 생성: {value}")
            elif item.deleted_at is not None:
                stamp = item.deleted_at
                item.deleted_at = None
                kids = db.scalars(
                    select(CodeItem).where(
                        CodeItem.parent_id == item.id, CodeItem.deleted_at == stamp
                    )
                ).all()
                for k in kids:
                    k.deleted_at = None
                    k.is_active = True
                restored += 1
                report.append(
                    f"  구분 복구: {value} (함께 지워진 세부 {len(kids)}개도 복구)"
                )
            item.sort_order = sort
            item.is_active = bool(active)
        db.flush()
        cat_by_name = {v: by_name[v] for v, _, _ in legacy_cats}

        # ---------------------------------------------------------------- 2) 세부분류
        syms_all = db.scalars(
            select(CodeItem).where(CodeItem.group_id == sym_group.id)
        ).all()
        by_key: dict[tuple, CodeItem] = {}
        for it in sorted(
            syms_all, key=lambda i: (i.deleted_at is not None, i.sort_order)
        ):
            by_key.setdefault((it.parent_id, it.name), it)
        taken_codes = {it.code for it in syms_all}
        sym_created = sym_restored = 0
        detail_item: dict[str, CodeItem] = {}
        for parent_name, value, sort, active in legacy_details:
            parent = cat_by_name.get(parent_name)
            if parent is None:
                report.append(f"  !! 세부의 구분을 못 찾음: {value}")
                continue
            leaf = value.split(" > ", 1)[-1].strip()
            item = by_key.get((parent.id, leaf))
            if item is None:
                code = code_for(f"{parent_name}>{leaf}")
                n = 1
                while code in taken_codes:
                    n += 1
                    code = code_for(f"{parent_name}>{leaf}#{n}")
                taken_codes.add(code)
                item = CodeItem(
                    group_id=sym_group.id,
                    parent_id=parent.id,
                    code=code,
                    name=leaf,
                    sort_order=sort,
                    is_active=bool(active),
                )
                db.add(item)
                by_key[(parent.id, leaf)] = item
                sym_created += 1
                report.append(f"  세부 생성: {parent_name} > {leaf}")
            elif item.deleted_at is not None:
                item.deleted_at = None
                sym_restored += 1
                report.append(f"  세부 복구: {parent_name} > {leaf}")
            item.sort_order = sort
            item.is_active = bool(active)
            detail_item[value] = item
        db.flush()

        # ---------------------------------------------------------------- 3) 원인 줄 재연결
        tickets = {
            t.legacy_no: t
            for t in db.scalars(
                select(ServiceTicket).where(ServiceTicket.legacy_no.is_not(None))
            ).all()
        }
        causes = {
            (c.ticket_id, c.seq): c
            for c in db.scalars(select(ServiceTicketCause)).all()
        }
        fixed = missing = 0
        head_seq: dict = {}
        for rec_no, seq, category, detail in legacy_causes:
            ticket = tickets.get(rec_no)
            cause = causes.get((ticket.id, seq)) if ticket else None
            if cause is None:
                missing += 1
                continue
            new_cat = cat_by_name.get(category)
            new_sym = detail_item.get(detail) if detail else None
            changed = False
            if new_cat is not None and cause.category_id != new_cat.id:
                cause.category_id = new_cat.id
                changed = True
            if (new_sym.id if new_sym else None) != cause.symptom_id:
                cause.symptom_id = new_sym.id if new_sym else None
                changed = True
            fixed += changed
            if rec_no not in head_seq or seq < head_seq[rec_no][0]:
                head_seq[rec_no] = (seq, new_cat, new_sym)
        head_fixed = 0
        for rec_no, (_, new_cat, new_sym) in head_seq.items():
            t = tickets[rec_no]
            cat_id = new_cat.id if new_cat else None
            sym_id = new_sym.id if new_sym else None
            if t.category_id != cat_id or t.symptom_id != sym_id:
                t.category_id, t.symptom_id = cat_id, sym_id
                head_fixed += 1
        db.flush()

        # ---------------------------------------------------------------- 4) 상위 없는 기본 세부 정리
        orphans = db.scalars(
            select(CodeItem).where(
                CodeItem.group_id == sym_group.id,
                CodeItem.parent_id.is_(None),
                CodeItem.deleted_at.is_(None),
            )
        ).all()
        removed, kept = 0, []
        for o in orphans:
            used = (
                db.scalar(
                    select(func.count())
                    .select_from(ServiceTicketCause)
                    .where(ServiceTicketCause.symptom_id == o.id)
                )
                or 0
            ) + (
                db.scalar(
                    select(func.count())
                    .select_from(ServiceTicket)
                    .where(
                        ServiceTicket.symptom_id == o.id,
                        ServiceTicket.deleted_at.is_(None),
                    )
                )
                or 0
            )
            if used:
                kept.append(f"{o.name}({used})")
            else:
                o.deleted_at = now_utc()
                o.is_active = False
                removed += 1

        # ---------------------------------------------------------------- 5) 그룹 이름
        for g in (cat_group, sym_group):
            if g.name != GROUP_NAMES[g.code]:
                report.append(f"  그룹 이름: {g.name} → {GROUP_NAMES[g.code]}")
                g.name = GROUP_NAMES[g.code]
        db.flush()

        # ---------------------------------------------------------------- 검증
        mismatch = (
            db.execute(
                select(func.count())
                .select_from(ServiceTicketCause)
                .join(CodeItem, CodeItem.id == ServiceTicketCause.symptom_id)
                .where(
                    CodeItem.parent_id.is_not(None),
                    CodeItem.parent_id != ServiceTicketCause.category_id,
                )
            ).scalar()
            or 0
        )
        live_details = (
            db.scalar(
                select(func.count())
                .select_from(CodeItem)
                .where(CodeItem.group_id == sym_group.id, CodeItem.deleted_at.is_(None))
            )
            or 0
        )

        print("\n".join(report))
        print(
            f"\n서비스구분: 복구 {restored} · 생성 {created} (구 서버 {len(legacy_cats)}개)"
        )
        print(
            f"세부분류: 복구 {sym_restored} · 생성 {sym_created} → 살아 있는 세부 {live_details}개 (구 서버 {len(legacy_details)}개)"
        )
        print(
            f"원인 줄: 다시 가리킴 {fixed} / 구 서버 {len(legacy_causes)} (못 찾음 {missing}) · 기록 대표 분류 수정 {head_fixed}"
        )
        print(
            f"상위 없는 기본 세부: 삭제 {removed}"
            + (f" · 쓰여서 남김 {', '.join(kept)}" if kept else "")
        )
        print(f"검증: 세부의 구분 ≠ 원인의 구분 인 줄 {mismatch}개")
        if args.apply:
            db.commit()
            print("\n반영했습니다.")
        else:
            db.rollback()
            print("\n미리 보기입니다. 반영하려면 --apply 를 붙이세요.")
    finally:
        db.close()


if __name__ == "__main__":
    main()
