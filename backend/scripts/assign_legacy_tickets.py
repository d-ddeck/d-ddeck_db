"""이관된 대응 기록의 담당자를 나중에 가입한 계정에 연결한다 (2026-10-08).

왜 필요한가
  구 서버 기록은 대응인원 이름만 있다. 이관 때 함께 옮긴 예전 계정이나 담당자 없음으로
  남은 기록은, 같은 사람이 새로 가입한 계정의 건수에 잡히지 않는다. 동명이인을 잘못 묶지
  않도록 앱은 이름으로 자동 연결하지 않으므로, 확인한 사람만 이 스크립트로 연결한다.

같은 사람으로 보는 이름
  '이름' 또는 '이름 + 띄어쓰기 + 직함'(예: '이재룡 주임'). '이재룡이'처럼 붙어 있으면 다른 사람.
  미리 보기에 묶인 이름을 모두 보여 준다.

무엇을 하나 (--name 으로 준 사람들, 한꺼번에)
  1) 같은 사람의 예전 계정(정지·삭제)이 담당자인 기록 -> 지금 계정.
  2) 담당자가 비어 있는 이관 기록(legacy_no 있음) 중 대응인원 어디든 그 사람이 있는 기록
     -> 지금 계정. 준 사람 둘 이상이 한 기록에 있으면 대응인원 순서상 앞사람.
  다른 사람이 담당자인 기록, 앱에서 만든 기록, 대응인원 코드는 건드리지 않는다.
  다시 실행해도 결과가 같다.

사용 (서버 계정으로, DB 백업 후)
  cd /opt/ddeck/backend
  sudo -u ddeck env DEBUG=false .venv/bin/python scripts/assign_legacy_tickets.py \\
      --name 서선재 --name 이재룡             # 미리 보기
  ... --apply                              # 반영
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sqlalchemy import func, or_, select

from app.core.database import SessionLocal
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import UserStatus
from app.models.service import ServiceTicket, ServiceTicketResponder
from app.models.user import User


def same_person(column, name):
    """'이재룡' 또는 '이재룡 주임'처럼 이름 뒤에 띄어 쓴 직함이 붙은 경우."""
    return or_(column == name, column.like(name.replace("%", "") + " %"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", action="append", required=True, help="연결할 사람 이름")
    ap.add_argument(
        "--account",
        action="append",
        default=[],
        metavar="이름=이메일",
        help="같은 사람의 활동 계정이 여럿일 때 지금 쓰는 계정을 지정한다. "
        "나머지 같은 사람 계정은 예전 계정으로 본다.",
    )
    ap.add_argument(
        "--apply", action="store_true", help="실제로 반영한다 (없으면 미리 보기)"
    )
    args = ap.parse_args()
    chosen = dict(a.split("=", 1) for a in args.account if "=" in a)
    db = SessionLocal()
    try:
        group = db.scalar(
            select(CodeGroup).where(CodeGroup.code == "SERVICE_RESPONDER")
        )
        if group is None:
            sys.exit("대응인원 코드 그룹(SERVICE_RESPONDER)이 없습니다.")

        people = {}  # name -> (current user, old account ids, responder code ids)
        skipped = {}
        for name in dict.fromkeys(args.name):
            print(f"\n[{name}]")
            # 지금 계정도 '이재룡 주임'처럼 직함을 붙여 가입했을 수 있다.
            users = db.scalars(
                select(User).where(
                    same_person(User.full_name, name),
                    User.status == UserStatus.APPROVED,
                    User.deleted_at.is_(None),
                )
            ).all()
            if name in chosen:
                users = [u for u in users if u.email == chosen[name]]
            if len(users) != 1:
                found = ", ".join(f"{u.full_name} · {u.email}" for u in users) or "없음"
                skipped[name] = (
                    f"활동 중인 계정이 정확히 1개여야 하는데 {len(users)}개입니다 ({found})."
                    " --account 이름=이메일 로 지금 계정을 지정하세요."
                )
                print(f"  건너뜀: {skipped[name]}")
                continue
            user = users[0]
            others = db.scalars(
                select(User).where(
                    same_person(User.full_name, name), User.id != user.id
                )
            ).all()
            old = [
                u
                for u in others
                if name in chosen
                or u.deleted_at is not None
                or u.status != UserStatus.APPROVED
            ]
            codes = db.scalars(
                select(CodeItem).where(
                    CodeItem.group_id == group.id, same_person(CodeItem.name, name)
                )
            ).all()
            print(f"  계정: {user.full_name} · {user.email}")
            names = sorted({c.name for c in codes})
            print(f"  같은 사람으로 본 대응인원 이름: {', '.join(names) or '-'}")
            for u in old:
                state = "삭제" if u.deleted_at else u.status.value
                print(f"  예전 계정: {u.full_name} · {u.email} ({state})")
            for u in others:
                if u not in old:
                    print(
                        f"  활동 중인 비슷한 이름 계정 (옮기지 않음): {u.full_name} · {u.email}"
                    )
            people[name] = (user, {u.id for u in old}, {c.id for c in codes})

        # 기록마다 준 사람 중 대응인원 순서상 가장 앞사람과 그 자리.
        owner_of_code = {
            code: name for name, (_, _, codes) in people.items() for code in codes
        }
        first_person: dict = {}
        position: dict = {}
        if owner_of_code:
            rows = db.execute(
                select(
                    ServiceTicketResponder.ticket_id,
                    ServiceTicketResponder.seq,
                    ServiceTicketResponder.responder_id,
                )
                .where(ServiceTicketResponder.responder_id.in_(owner_of_code))
                .order_by(ServiceTicketResponder.ticket_id, ServiceTicketResponder.seq)
            ).all()
            for ticket_id, seq, code in rows:
                if ticket_id not in first_person:
                    first_person[ticket_id] = owner_of_code[code]
                    position[ticket_id] = seq
        lowest_seq = dict(
            db.execute(
                select(
                    ServiceTicketResponder.ticket_id,
                    func.min(ServiceTicketResponder.seq),
                )
                .where(ServiceTicketResponder.ticket_id.in_(first_person))
                .group_by(ServiceTicketResponder.ticket_id)
            ).all()
        )

        old_owner = {
            account: name for name, (_, old, _) in people.items() for account in old
        }
        current = {user.id for user, _, _ in people.values()}
        tickets = db.scalars(
            select(ServiceTicket).where(
                ServiceTicket.deleted_at.is_(None),
                or_(
                    ServiceTicket.id.in_(first_person),
                    ServiceTicket.assignee_id.in_(old_owner),
                ),
            )
        ).all()
        stats = Counter()
        changes = []
        for ticket in tickets:
            if ticket.assignee_id in old_owner:
                name = old_owner[ticket.assignee_id]
                stats[name, "예전 계정에서 옮김"] += 1
            elif ticket.assignee_id in current:
                continue  # 이미 지금 계정
            elif ticket.assignee_id is not None:
                stats[first_person[ticket.id], "다른 담당자가 있어 그대로 둠"] += 1
                continue
            elif ticket.legacy_no is None:
                stats[
                    first_person[ticket.id], "앱에서 만든 미배정 기록이라 그대로 둠"
                ] += 1
                continue
            else:
                name = first_person[ticket.id]
                where = (
                    "첫 번째"
                    if position[ticket.id] == lowest_seq.get(ticket.id)
                    else "두 번째 이후"
                )
                stats[name, f"미배정 · {where} 대응인원 → 지정"] += 1
            changes.append((ticket, people[name][0].id))

        print("\n[결과]")
        for name, reason in skipped.items():
            print(f"  {name}: 건너뜀 - {reason}")
        for name, (user, _, _) in people.items():
            assigned = db.scalar(
                select(func.count(ServiceTicket.id)).where(
                    ServiceTicket.assignee_id == user.id,
                    ServiceTicket.deleted_at.is_(None),
                )
            )
            rows = [(k, v) for (n, k), v in sorted(stats.items()) if n == name]
            added = sum(v for k, v in rows if "그대로" not in k)
            print(f"  {name}: 현재 담당 {assigned}건")
            for kind, count in rows:
                print(f"    - {kind}: {count}건")
            print(f"    => 반영 후 담당 {assigned + added}건")
        if args.apply:
            for ticket, user_id in changes:
                ticket.assignee_id = user_id
            db.commit()
            print("\n반영했습니다.")
        else:
            db.rollback()
            print("\n미리 보기입니다. 반영하려면 --apply 를 붙이세요.")
    finally:
        db.close()


if __name__ == "__main__":
    main()
