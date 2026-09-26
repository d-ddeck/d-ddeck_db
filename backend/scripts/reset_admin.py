"""Local administrator recovery. Preview by default; --apply prompts for a new password."""

import argparse
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sqlalchemy import select, update

from app.core.database import SessionLocal
from app.core.security import hash_password, now_utc, validate_password_strength
from app.models.enums import AuditAction, ModuleKey, Role, UserStatus
from app.models.user import Device, RefreshToken, User
from app.services import audit


def recover(db, user, password):
    if user.role not in (Role.ADMIN, Role.SUPERADMIN) or user.deleted_at is not None:
        raise ValueError("활성 관리자 계정만 복구할 수 있습니다.")
    problems = validate_password_strength(password)
    if problems:
        raise ValueError(" ".join(problems))
    user.password_hash = hash_password(password)
    user.failed_login_count = 0
    user.locked_until = None
    user.must_change_password = True
    user.status = UserStatus.APPROVED
    db.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now_utc())
    )
    db.execute(update(Device).where(Device.user_id == user.id).values(is_active=False))
    audit.record(
        db,
        action=AuditAction.UPDATE,
        module=ModuleKey.AUTH,
        entity_type="user",
        entity_id=user.id,
        summary="로컬 운영자 도구로 관리자 로그인 복구",
    )
    db.commit()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    with SessionLocal() as db:
        user = db.scalar(
            select(User).where(
                User.email == args.email,
                User.deleted_at.is_(None),
                User.role.in_([Role.ADMIN, Role.SUPERADMIN]),
            )
        )
        if user is None:
            raise SystemExit("관리자 계정을 찾을 수 없습니다.")
        print(f"복구 대상: {user.email} ({user.role.value})")
        if not args.apply:
            print(
                "미리보기입니다. 백업 후 --apply로 실행하면 비밀번호 입력을 요청합니다."
            )
            return
        password = getpass.getpass("새 임시 비밀번호: ")
        if password != getpass.getpass("다시 입력: "):
            raise SystemExit("비밀번호가 일치하지 않습니다.")
        recover(db, user, password)
        print(
            "복구 완료. 기존 세션은 종료됐으며 첫 로그인 때 비밀번호 변경이 필요합니다."
        )


if __name__ == "__main__":
    main()
