# 도메인 없는 사설 CA 배포

## 현재 준비 상태

- 확인된 서버 IP: `192.168.121.2` (IP 변경 시 새 IP SAN 인증서가 필요하므로 DHCP 예약 권장)
- 확인된 사내 인터페이스 대역: `192.168.121.0/24`
- WireGuard 인터페이스: `10.153.127.1/24`, 허용 대역: `10.153.127.0/24`.
- CA: 앱 내부에서만 신뢰. Windows·Android 기기의 전체 신뢰 저장소를 변경하지 않음.
- 서버 인증서: 위 IP의 SAN, serverAuth 용도, 기본 90일. CA 인증서는 10년.
- 운영 서버: 2026-10-01 HTTPS 전환 완료. ddeck·nginx 서비스 실행 및 부팅 자동 시작 확인. 외부 8000 포트 차단 확인.

서버 개인키는 인증서를 사용하는 서버에만, CA 개인키는 인증서를 발급하는 관리 환경에만 둡니다. **CA 개인키를 /etc/ddeck/tls 또는 앱으로 복사하지 마세요.** 현재 CA 개인키는 준비 작업을 위해 서버 사용자 홈의 0700 디렉터리/0600 파일에 있습니다. 이것은 오프라인 보관 상태가 아닙니다. 운영 전 접근이 통제된 오프라인 저장소로 이전하고 복구 가능성을 확인한 뒤 작업용 복사본을 제거하세요.

## 준비된 파일

- 공개 CA: `app/assets/company_ca.crt`
- Android 공개 CA 복사본: `app/android/app/src/main/res/raw/company_ca.crt`
- CA 개인키/공개 인증서: `~/.local/share/ddeck-security/private-ca/ca.key`, `ca.crt`
- 서버 개인키/인증서: `~/.local/share/ddeck-security/server-tls-192-168-121-2/server.key`, `server.crt`
- 연결 설정 서명키(별도 키): `~/.local/share/ddeck-security/connection-signing.key`
- HTTPS 연결 파일: `/tmp/ddeck-connection-private-ca.json` (가져오기 유효기간 2일; 만료 시 재발급)

개인키는 Git/앱/릴리즈에 넣지 않습니다. 앱에는 공개 인증서만 포함합니다. CA SHA256 지문:

`90c1e8c134c8cfb7b57bfb5df18d306b2d9133a4d3466c76a681e51680a19467`

앱 설치 파일은 기존 서명된 업데이트 경로로 배포합니다. 연결 JSON은 담당자가 직원에게 별도 전달합니다. CA 교체 시 새 CA를 포함한 앱을 먼저 배포하고, 전환을 확인한 뒤 서버 인증서를 교체합니다. 기존 CA로 서버 인증서만 갱신할 때는 앱을 다시 설치할 필요가 없습니다.

## 관리자 적용 순서

확정된 대역으로 유지보수 시간에 진행합니다. 기존 HTTP 앱은 서버 전환 후 연결되지 않으므로 새 앱 배포를 함께 준비합니다. 방화벽 접근 제한은 반드시 실제 사내망·VPN 기기에서 검사합니다. 아래는 현재 수동 실행 환경을 서비스로 전환하는 절차이며 실행 전 작업 중인 백업·복구가 없는지 확인합니다.

1. Google 안전 백업을 실행하고 성공을 확인합니다: `DEBUG=false backend/.venv/bin/python deploy/cloud_backup.py`
2. `sudo apt-get install nginx`로 nginx를 설치합니다. 기본 웹사이트는 업무 서버 설정과 분리하고 필요하지 않은 기본 사이트는 비활성화합니다.
3. `/etc/ddeck/tls`를 root 소유 0700으로 만들고 **server.crt와 server.key만** 각각 0644/0600으로 설치합니다.
4. `sudo backend/.venv/bin/python deploy/register_systemd.py --install --user d-ddeck-server`로 현재 경로를 등록합니다. 등록만으로 서버가 시작되지는 않습니다.
5. `deploy/configure_https.py --domain 192.168.121.2 --cidr 192.168.121.0/24 --cidr 10.153.127.0/24 --cert /etc/ddeck/tls/server.crt --key /etc/ddeck/tls/server.key --root "$PWD"`로 설정을 검토합니다. 실제 VPN 클라이언트에서 접속을 검증해야 합니다.
6. 기존 `backend/server.pid` 프로세스가 이 프로젝트 uvicorn임을 확인하고 종료한 뒤 위 명령을 sudo로 `--apply`하여 실행합니다. backend는 127.0.0.1:8000만 바인딩되고 nginx는 TLS 1.2/1.3과 대역 제한을 적용합니다.
7. `curl --cacert app/assets/company_ca.crt https://192.168.121.2/healthz`와 실제 앱 로그인·다운로드를 확인합니다. `-k`를 사용하지 않습니다.
8. 서버 PC 바깥에서 8000 직접 접속과 허용 대역 외 443 접속이 차단되는지 확인합니다. 공유기에서 API·DB 포트포워딩을 제거하고 VPN 진입 포트만 유지합니다. SSH 관리 경로는 보존합니다.
9. 정상 동작 확인 후 `sudo systemctl enable ddeck nginx`로 부팅 시 자동 시작을 설정합니다.

사설 CA는 공인 CA의 자동 갱신 서비스가 아닙니다. 만료 30일 전 알림/운영 점검을 설정하고 오프라인 CA 환경에서 새 서버 인증서를 발급한 뒤 검증하여 설치해야 합니다. 만료 알림은 아직 운영 예약에 등록하지 않았습니다.

```bash
# 오프라인 CA가 있는 관리 환경에서 실행; 새 폴더를 사용해 기존 인증서를 보존
python deploy/private_ca.py issue --ca-dir /보안매체/private-ca \
  --output /보안경로/server-renewal --ip 192.168.121.2 --days 90
openssl verify -CAfile app/assets/company_ca.crt -verify_ip 192.168.121.2 /보안경로/server-renewal/server.crt
```

서버에 새 파일을 설치하기 전 개인키 일치와 유효기간을 확인하고, `nginx -t` 성공 후 `systemctl reload nginx`를 실행합니다. CA 개인키 유출 시 해당 CA를 신뢰하는 앱 전체를 새 CA로 교체해야 합니다.

## 현재 PC용 자동 적용 명령

아래 명령은 Google 안전 백업 후 수동 서버를 systemd 서비스로 전환합니다. 기존 서비스/TLS 설정이 있으면 덮어쓰지 않고 중단합니다. 인증서·키 일치, nginx 문법과 HTTPS 응답을 확인하며, 전환 실패 시 원래 수동 서버 재실행을 시도합니다. 성공 시 backend는 루프백만 열고 새 앱은 `https://192.168.121.2`를 사용합니다. **기존 HTTP 원격 앱은 연결이 끊기므로 새 앱을 준비한 유지보수 시간에 실행하세요.**

```bash
cd "/home/d-ddeck-server/바탕화면/d-ddeck_db-1.0.15"
sudo backend/.venv/bin/python deploy/activate_private_https.py \
  --ip 192.168.121.2 --lan 192.168.121.0/24 --vpn 10.153.127.0/24 \
  --cert-dir /home/d-ddeck-server/.local/share/ddeck-security/server-tls-192-168-121-2 \
  --apply
```

`--apply`를 빼면 설정 검토만 수행합니다. 공유기의 WireGuard 라우팅·피어 AllowedIPs에는 `192.168.121.2/32`(서버만) 또는 필요한 서버망 대역을 포함해야 합니다. VPN에 연결한 실제 직원 기기에서 검증하고, 8000/DB 포트를 공유기에 포워딩하지 마세요. 2026-10-01: DHCP와 보조 수동 주소가 공존하던 설정을 수정하고 Netplan DHCP를 비활성화해 서버 PC를 `192.168.121.2/24` 고정 IP로 통일했습니다. 이전 `.69` 주소는 제거했습니다. 공유기에서도 해당 PC MAC에 이 주소를 예약해야 합니다.

## 2026-10-01 적용 결과

- Google 안전 백업 업로드·검증 완료, 업로드 임시 파일 삭제 확인.
- `https://192.168.121.2/healthz`: 회사 CA 검증을 포함해 HTTP 200 확인.
- backend: `127.0.0.1:8000`만 바인딩, LAN 주소의 8000 직접 접속 차단 확인.
- nginx: `192.168.121.0/24`와 `10.153.127.0/24` 허용, 나머지 거부 설정 적용.
- ddeck·nginx: 실행 중, 부팅 자동 시작 활성화.
- NetworkManager: manual / 192.168.121.2/24 / gateway 192.168.121.1 확인. Netplan `99-ddeck-server-ip.yaml`에 DHCP 비활성화 설정 저장.
- Linux 앱 빌드와 기본 연결 설정 갱신. 설치된 Windows·Android 앱은 새 서명 JSON을 가져와 연결 주소를 변경해야 함.
- 앱의 분할 터널 기본 대역을 새 회사망·VPN 대역으로 수정하고 관련 테스트 26개 통과. 이 클라이언트 코드 변경은 아직 새 Windows·Android 릴리즈로 배포하지 않았음. 실제 사외 VPN 기기의 접속 검증은 별도 필요.

이후 서버 재시작은 `sudo systemctl restart ddeck`을 사용합니다. 수동 uvicorn을 다시 외부 전체 주소에 실행하지 마세요. 안전 백업을 포함하려면 `bash deploy/restart-with-backup.sh`를 사용합니다.
