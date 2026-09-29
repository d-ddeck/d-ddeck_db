"""v1 router tree. One place to see every mounted module."""

from fastapi import APIRouter

from app.api.v1 import (
    admin,
    auth,
    board,
    calendar,
    drive_backup,
    files,
    inventory,
    quotations,
    service,
    store,
    updates,
    users,
    worklog,
)

api_router = APIRouter()
api_router.include_router(auth.router)  # 회원가입 / 로그인 / 세션 / 기기
api_router.include_router(users.router)  # 승인 대기열 / 권한 / 구성원
api_router.include_router(quotations.router)
api_router.include_router(service.router)  # 서비스(AS) + 자동 통계
api_router.include_router(inventory.router)  # 재고관리 + 위치 이력
api_router.include_router(store.router)  # 매장 + 매장별 보유 자산
api_router.include_router(worklog.router)  # 근무일지
api_router.include_router(board.router)  # 게시판
api_router.include_router(calendar.router)  # 캘린더 + 알림
api_router.include_router(admin.router)  # 관리기능 (설정/코드/감사/헬스)
api_router.include_router(files.router)  # 공통 첨부파일

api_router.include_router(updates.router)  # 서명된 클라이언트 업데이트

api_router.include_router(drive_backup.router)
