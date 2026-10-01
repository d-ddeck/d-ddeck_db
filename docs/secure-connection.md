# 업무 서버 연결 보안

## 적용 상태와 전환 순서

로그인 화면에는 서버 주소·포트와 VPN 엔드포인트를 표시하지 않습니다. 연결 확인은 성공 여부만 표시합니다. 관리 > 기능 설정 > 이 기기 연결 설정에서 관리자만 주소를 직접 변경할 수 있습니다.

로그인 전에는 관리자 서명이 있는 JSON 연결 파일만 가져올 수 있습니다. 파일은 앱에 포함된 공개키로 검증하고 발급 후 최대 7일 동안만 가져올 수 있습니다. 비밀번호·토큰은 포함하지 않습니다. 서명은 진위를 확인하며 주소를 암호화하지는 않습니다. 파일은 직원에게만 전달하세요. 설정 변경 전에 기존 서버 세션을 종료합니다.

새 앱의 API 통신은 HTTPS만 허용합니다. 서버 PC의 숫자 루프백 주소(127.0.0.1 또는 ::1)는 예외입니다. HTTP로 리디렉션하거나 인증서 검증을 생략하는 기능은 없습니다. Android는 플랫폼 설정에서도 평문 통신을 차단합니다. 기존 HTTP 원격 서버를 사용 중이라면 **서버 HTTPS 전환을 먼저 완료한 후 새 앱을 배포해야 합니다.**

사설 CA 방식과 서버 IP 192.168.121.69는 확정됐습니다. 서버 인증서와 앱 전용 CA 신뢰 설정을 준비했습니다. WireGuard 대역은 10.153.127.0/24로 확정됐으며 시스템 관리자 권한이 없어 운영 서버의 네트워크 설정은 아직 변경하지 않았습니다. 앱의 VPN 표시나 연결 여부만으로 접근 권한을 판단하지 않습니다. 서버 측에서 사내망·WireGuard 대역만 허용해야 합니다.

1. 회사 소유 도메인, DNS 관리업체, 사내망/VPN CIDR을 확정합니다.
2. 인증서를 발급하고 HTTPS 프록시를 준비합니다.
3. 사내·VPN DNS에서 도메인이 서버의 내부 주소로 해석되도록 설정합니다.
4. nginx는 443에서 허용 대역만 수락하고 업무 API는 127.0.0.1:8000에만 바인딩합니다. 라우터의 업무 API/DB 포트 포워딩은 제거하고 원격 접속에는 WireGuard UDP 포트만 엽니다. 관리 SSH 접근은 별도로 보존합니다.
5. 사내망과 실제 VPN 기기에서 인증서 검증, 로그인·다운로드를 확인하고 허용되지 않은 네트워크의 차단도 확인합니다.
6. 서명된 연결 파일과 새 앱을 직원에게 배포합니다. 기존 세션은 새 서버 주소로 전송하지 않습니다.

## 인증서 권장 방식

회사 도메인의 업무용 하위 도메인에 공인 CA 인증서를 발급하고 nginx에 fullchain과 개인키를 설치합니다. 클라이언트는 운영체제의 공인 CA 신뢰 체계를 사용하므로 직원 기기에 인증서 파일을 따로 설치할 필요가 없습니다.

Let's Encrypt DNS-01 인증은 업무 서버의 80/443을 인터넷에 공개하지 않고 도메인 소유권을 확인할 수 있습니다. DNS API 권한은 인증에 필요한 영역만 부여하고 가능하면 `_acme-challenge`를 별도 영역에 위임합니다. 공급자별 Certbot DNS 플러그인으로 갱신을 자동화하고 `certbot renew --dry-run`을 검증합니다. 갱신 성공 후 `nginx -t && systemctl reload nginx`를 실행하는 deploy hook을 사용합니다.

서버 개인키는 root 소유 0600으로 보관합니다. APK/설치 파일/설정 JSON/QR/GitHub/일반 공유 폴더에 개인키를 넣지 않습니다. 공개 인증서의 배포와 개인키의 배포는 다릅니다. 이 저장소의 연결 설정 서명키도 TLS 개인키와 별개의 키입니다.

공인 인증서는 인증서 투명성 로그에 도메인이 공개될 수 있습니다. 도메인 비공개를 보안 경계로 삼지 않습니다.

도메인을 확보하지 않는 경우 사설 CA로 서버 내부 IP를 SAN에 포함한 인증서를 발급할 수 있습니다. 이때 루트 CA **공개 인증서만** MDM 등 신뢰할 수 있는 관리 경로로 배포하고 지문을 별도 경로로 확인해야 합니다. CA 개인키는 오프라인으로 보관하고 서버에는 서버 개인키만 둡니다. Android는 사용자 설치 CA를 앱이 자동 신뢰한다고 가정하면 안 됩니다. 선택 시 앱에 신뢰할 회사 CA를 명시하고 실제 Flutter/Windows/Android에서 검증해야 합니다. 현재 빌드는 회사 CA 공개 인증서만 앱 자산과 Android trust anchor에 포함합니다. Dart API·업데이트 클라이언트는 별도 SecurityContext에서 회사 CA를 추가 신뢰합니다. 인증서 체인·유효기간·IP 일치 검증은 유지되며 인증서 오류 무시 기능은 없습니다. OS 전체에 CA를 설치할 필요가 없습니다.

## 서명된 연결 파일 발급

전용 연결 설정 서명키는 저장소 밖 `~/.local/share/ddeck-security/connection-signing.key`에 0600으로 준비되어 있습니다. 운영 시 관리용 보안 저장소/오프라인 매체로 옮기고 접근자를 제한하세요. 앱에는 공개키만 포함됩니다. 키 교체 시 새 공개키를 포함한 앱 배포가 필요합니다.

아래 예시 도메인은 실제 회사 도메인으로 바꿉니다. JSON 파일은 서명되어 있으며 주소나 만료일을 수정하면 가져오기가 거부됩니다.

```bash
backend/.venv/bin/python deploy/sign_connection_profile.py \
  --url https://work.example.com \
  --key "$HOME/.local/share/ddeck-security/connection-signing.key" \
  --days 2 --output /tmp/ddeck-connection.json
```

## HTTPS 설정 검토

`configure_https.py`는 기본적으로 설정 내용만 출력합니다. 실제 CIDR과 인증서 경로로 검토 후 `--apply`를 사용합니다. 적용 경로는 systemd의 ddeck 서비스 설치 환경을 전제로 하므로 현재 개발 폴더의 수동 uvicorn 서버에 바로 적용하지 않습니다.

```bash
python3 deploy/configure_https.py \
  --domain work.example.com --cidr 192.168.0.0/24 --cidr 10.8.0.0/24 \
  --cert /etc/letsencrypt/live/work.example.com/fullchain.pem \
  --key /etc/letsencrypt/live/work.example.com/privkey.pem
```

생성 설정은 허용 대역 외 접속을 거부하고 TLS 1.2/1.3을 사용합니다. 전체 인터넷 대역(0.0.0.0/0, ::/0)은 거부합니다. 적용 시 인증서 유효기간·도메인·개인키 권한·nginx 설정을 검사합니다.

참고: https://letsencrypt.org/docs/challenge-types/ 및 https://certbot.eff.org/instructions
