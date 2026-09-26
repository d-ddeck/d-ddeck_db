# Android 릴리스 서명 준비

릴리스 빌드는 고정된 운영 키를 요구합니다. 설정이 없으면 실패하며 debug 키를 사용하지 않습니다. 1.0.6부터 고정 운영 키를 생성해 GitHub Actions Secrets에 등록했습니다. 이후 릴리즈는 같은 키를 사용합니다. 키 원본은 담당자 PC의 저장소 밖 사용자 전용 디렉터리에 보관하며, 조직의 암호화 백업은 별도로 보관해야 합니다.

## 키 생성 (담당자 PC에서 최초 한 번)

JDK의 keytool을 사용합니다. 저장소 밖의 안전한 경로에서 실행하고 비밀번호는 대화형 입력으로 지정합니다.

```bash
keytool -genkeypair -v -keystore /안전한/경로/ddeck-release.jks -alias ddeck-release -keyalg RSA -keysize 4096 -validity 10000
```

키 파일, 별칭, 비밀번호를 조직의 비밀 보관소와 별도 암호화 백업에 보관하세요. 이후 모든 버전은 동일한 키로 서명해야 기존 앱을 업데이트할 수 있습니다. 키와 비밀번호를 저장소·채팅·로그에 올리지 마세요.

## 로컬 빌드

`app/android/key.properties`를 생성합니다(버전 관리 제외). `storeFile`에는 절대 경로를 사용합니다. Windows에서는 `/` 구분자를 사용하세요.

```properties
storeFile=/안전한/경로/ddeck-release.jks
storePassword=직접입력
keyAlias=ddeck-release
keyPassword=직접입력
```

파일 접근 권한을 사용자 전용으로 설정한 뒤 `app`에서 `flutter build apk --release`를 실행합니다. 환경 변수 `DDECK_KEYSTORE_PATH`, `DDECK_KEYSTORE_PASSWORD`, `DDECK_KEY_ALIAS`, `DDECK_KEY_PASSWORD`가 있으면 파일보다 우선합니다.

## GitHub Actions

저장소 Settings → Secrets and variables → Actions에 다음 네 개를 등록합니다.

- `ANDROID_KEYSTORE_BASE64`: 키 파일의 Base64 문자열 (`base64 -w0 /안전한/경로/ddeck-release.jks` 결과를 비밀값 입력에만 사용)
- `ANDROID_KEYSTORE_PASSWORD`: 키 저장소 비밀번호
- `ANDROID_KEY_ALIAS`: `ddeck-release`
- `ANDROID_KEY_PASSWORD`: 개인 키 비밀번호

release workflow는 임시 디렉터리에 키를 복원하고 환경 변수로 비밀번호를 전달합니다. 키는 산출물에 포함하지 않습니다. `workflow_dispatch`로 먼저 시험 빌드하고 `apksigner verify --print-certs`로 인증서 지문을 확인해 보관한 뒤 태그 릴리스를 진행하세요. CI Secret 등록과 실제 서명 빌드는 운영 키 준비 후 담당자가 실행합니다.

## 최초 전환 공지

기존 debug 서명 APK에서 운영 서명 APK로는 덮어쓰기 업데이트가 불가능합니다. 먼저 서버 동기화와 로컬 임시본을 확인하고 VPN 설정을 안전하게 백업한 다음 기존 앱을 제거하고 새 APK를 설치해야 합니다. 이 최초 전환 이후에는 고정 운영 키로 업데이트합니다.
