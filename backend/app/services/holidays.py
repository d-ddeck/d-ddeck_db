"""한국 공휴일 (캘린더 표시용). 인터넷·외부 패키지 없이 계산한다. 구 서버 holidays.py 그대로.

- 양력 공휴일: 신정, 삼일절, 어린이날, 현충일, 광복절, 개천절, 한글날, 성탄절
- 음력 공휴일: 설날·추석(앞뒤 하루씩 연휴), 부처님오신날 — LUNAR 표(한국천문연구원 음양력 기준, 2024~2050)
- 대체공휴일: 설·추석 연휴가 일요일이나 다른 공휴일과 겹치면, 그 밖의 공휴일(신정·현충일 제외)은
  토·일요일이나 다른 공휴일과 겹치면 그 뒤 첫 평일 하루. 같은 날 여러 공휴일이 겹쳐도 대체공휴일은 하루.
- 그 밖의 날(임시공휴일·선거일·노동절·회사 휴무일 등): 설정 CALENDAR.extra_holidays 에 적는다.
    05-01:노동절, 07-17:제헌절, 2028-04-12:국회의원 선거      (MM-DD = 매년, YYYY-MM-DD = 그 해만)

2050년 이후에는 LUNAR 표에 줄을 더한다 (설날, 부처님오신날, 추석의 양력 날짜).
"""
from __future__ import annotations

import datetime

FIXED = [("01-01", "신정", False), ("03-01", "삼일절", True), ("05-05", "어린이날", True), ("06-06", "현충일", False),
         ("08-15", "광복절", True), ("10-03", "개천절", True), ("10-09", "한글날", True), ("12-25", "성탄절", True)]

LUNAR = {   # 연도: (설날, 부처님오신날, 추석)
    2024: ("02-10", "05-15", "09-17"), 2025: ("01-29", "05-05", "10-06"), 2026: ("02-17", "05-24", "09-25"),
    2027: ("02-07", "05-13", "09-15"), 2028: ("01-27", "05-02", "10-03"), 2029: ("02-13", "05-20", "09-22"),
    2030: ("02-03", "05-09", "09-12"), 2031: ("01-23", "05-28", "10-01"), 2032: ("02-11", "05-16", "09-19"),
    2033: ("01-31", "05-06", "09-08"), 2034: ("02-19", "05-25", "09-27"), 2035: ("02-08", "05-15", "09-16"),
    2036: ("01-28", "05-03", "10-04"), 2037: ("02-15", "05-22", "09-24"), 2038: ("02-04", "05-11", "09-13"),
    2039: ("01-24", "04-30", "10-02"), 2040: ("02-12", "05-18", "09-21"), 2041: ("02-01", "05-07", "09-10"),
    2042: ("01-22", "05-26", "09-28"), 2043: ("02-10", "05-16", "09-17"), 2044: ("01-30", "05-05", "10-05"),
    2045: ("02-17", "05-24", "09-25"), 2046: ("02-06", "05-13", "09-15"), 2047: ("01-26", "05-02", "10-04"),
    2048: ("02-14", "05-20", "09-22"), 2049: ("02-02", "05-09", "09-11"), 2050: ("01-23", "05-28", "09-30"),
}
ONE = datetime.timedelta(days=1)


def _d(year: int, md: str) -> datetime.date:
    return datetime.date(year, int(md[:2]), int(md[3:]))


def parse_extra(text: str | None) -> list[tuple[str, str]]:
    """'05-01:노동절, 2028-04-12:국회의원 선거' → [('05-01', '노동절'), ('2028-04-12', '국회의원 선거')]. 형식이 틀린 항목은 버림."""
    out: list[tuple[str, str]] = []
    for part in (text or "").split(","):
        key, _, name = part.strip().partition(":")
        key, name = key.strip(), name.strip()
        try:
            if len(key) == 5:
                _d(2024, key)                       # 02-29 도 받도록 윤년으로 검사
            elif len(key) == 10:
                datetime.date.fromisoformat(key)
            else:
                continue
        except ValueError:
            continue
        if name:
            out.append((key, name))
    return out


def korean_holidays(year: int, extra: str | None = "") -> dict[str, str]:
    """그 해의 공휴일 {'YYYY-MM-DD': '이름'}. 같은 날 여러 개면 ' · ' 로 이어 붙인다."""
    days: dict[datetime.date, list[str]] = {}
    groups: list[tuple[str, list[datetime.date], bool]] = []   # (이름, [날짜들], 토요일도 겹침으로 보는지)
    lunar = LUNAR.get(year)
    if lunar:
        for md, name in ((lunar[0], "설날"), (lunar[2], "추석")):
            mid = _d(year, md)
            block = [mid - ONE, mid, mid + ONE]
            for d, n in zip(block, (f"{name} 연휴", name, f"{name} 연휴")):
                days.setdefault(d, []).append(n)
            groups.append((name, block, False))
    singles = [(md, n, sub) for md, n, sub in FIXED] + ([(lunar[1], "부처님오신날", True)] if lunar else [])
    for md, name, sub in singles:
        d = _d(year, md)
        days.setdefault(d, []).append(name)
        if sub and not any(d in g[1] for g in groups):          # 연휴 안에 든 날은 그 연휴가 대표 (대체공휴일 하루만)
            groups.append((name, [d], True))
    subs: dict[datetime.date, str] = {}
    for name, block, sat in sorted(groups, key=lambda g: g[1][0]):
        if any(d.weekday() == 6 or (sat and d.weekday() == 5) or len(days[d]) > 1 for d in block):
            s = block[-1] + ONE
            while s.weekday() >= 5 or s in days or s in subs:
                s += ONE
            subs[s] = f"대체공휴일({name})"
    for d, n in subs.items():
        days.setdefault(d, []).append(n)
    for key, name in parse_extra(extra):
        try:
            d = _d(year, key) if len(key) == 5 else datetime.date.fromisoformat(key)
        except ValueError:                          # 평년의 02-29
            continue
        if d.year == year and name not in days.get(d, []):
            days.setdefault(d, []).append(name)
    return {d.isoformat(): " · ".join(n) for d, n in sorted(days.items())}
