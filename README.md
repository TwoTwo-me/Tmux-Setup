# Tmux-Setup

이 저장소의 목적은 **tmux + ttyd + Z.AI/Codex 쿼터 상태바 환경을 백업 상태 그대로 복구**하는 것입니다.  
사람이 읽고 이해할 수 있어야 하고, 동시에 AI Agent(Codex, OpenCode, Claude Code 등)에게 그대로 전달해도 실제 터미널에 적용 가능하도록 구성되어 있습니다.

## 1. 저장소 목적

- tmux 설정(`.tmux.conf`) 복구
- 상태바/클릭/쿼터 표시 스크립트 복구
- systemd 서비스(`ttyd-tmux`, `tmux-zai-key-bootstrap`) 복구
- (선택) 레거시 Codex poll timer 복구

복구 기준 스냅샷은 `tmux-backup/2026-02-13/` 입니다.

## 2. 디렉토리 구성

```text
tmux-backup/2026-02-13/
├─ home/tmux.conf
├─ bin/
│  ├─ tmux-codex-quota.sh
│  ├─ tmux-zai-quota.sh
│  ├─ tmux-load-opencode-key.sh
│  ├─ tmux-status-click.sh
│  └─ ... (총 16개)
└─ systemd/
   ├─ ttyd-tmux.service
   ├─ tmux-zai-key-bootstrap.service
   ├─ codex-quota-poll.service
   └─ codex-quota-poll.timer
```

참고 문서:
- `TMUX_세팅_백업_복구_가이드_20260213.md`
- `TMUX_ZAI_CODEX_쿼터_모니터링_구축_보고서_20260212.md`

## 3. 민감정보 정책

- 이 저장소에는 실제 API 키/토큰 값을 포함하지 않습니다.
- 인증 데이터는 아래 외부 파일에서 읽어옵니다.
  - `/root/.local/share/opencode/auth.json`
  - `/root/.codex/auth.json` (`codex login` 사용 시)
  - `pass` 저장소(`pass show api/zai`)
- 따라서 복구 후 인증이 안 되어 있으면 쿼터 영역은 `login needed` 또는 `set ZAI_API_KEY`로 표시될 수 있습니다.

## 4. 사람이 직접 복구하는 방법

루트 기준:

```bash
set -euo pipefail
cd /root/Tmux-Setup

install -d -m 755 /root/.local/bin
cp tmux-backup/2026-02-13/home/tmux.conf /root/.tmux.conf
cp tmux-backup/2026-02-13/bin/* /root/.local/bin/
chmod +x /root/.local/bin/tmux-*.sh /root/.local/bin/codex-quota-poll.sh /root/.local/bin/codex-quota-set

cp tmux-backup/2026-02-13/systemd/*.service /etc/systemd/system/
cp tmux-backup/2026-02-13/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

systemctl enable --now ttyd-tmux.service tmux-zai-key-bootstrap.service
# 선택: 레거시 poll timer
systemctl enable --now codex-quota-poll.timer

tmux source-file /root/.tmux.conf || true
```

## 5. AI Agent 실행 가이드

아래 절차를 **순서대로 실행**하도록 AI에게 지시하세요.

### 5.1 작업 원칙

- 멱등성: 이미 적용된 상태여도 재실행 가능해야 함
- 보안: 인증 파일 내용 출력/로그 노출 금지
- 검증: 적용 후 서비스/옵션 확인 명령까지 실행

### 5.2 설치 전 필수 질문 (반드시 먼저 질문)

AI는 설치를 시작하기 전에 아래 3가지를 **반드시 먼저 질문**하고 답변을 확정해야 합니다.

1. Codex 쿼터를 표시할까요? (`yes`/`no`)
2. (1이 `yes`인 경우만) Codex 인증정보를 어디서 읽을까요? (`codex-cli`/`opencode`)
3. Z.AI 쿼터를 표시할까요? (`yes`/`no`)

### 5.3 AI가 실행할 체크 + 적용 절차

```bash
set -euo pipefail
cd /root/Tmux-Setup

# 0) 사전 점검 (없으면 설치가 아니라 실패 원인만 보고)
command -v tmux >/dev/null
command -v systemctl >/dev/null
command -v jq >/dev/null || true
command -v curl >/dev/null || true

# A) 사용자 답변 입력 (반드시 5.2 질문에 대한 확정값 사용)
SHOW_CODEX="yes"              # yes | no
CODEX_AUTH_SOURCE="codex-cli" # codex-cli | opencode (SHOW_CODEX=yes 일 때만 의미 있음)
SHOW_ZAI="yes"                # yes | no

# 1) 파일 배치
install -d -m 755 /root/.local/bin
cp tmux-backup/2026-02-13/home/tmux.conf /root/.tmux.conf
cp tmux-backup/2026-02-13/bin/* /root/.local/bin/
chmod +x /root/.local/bin/tmux-*.sh /root/.local/bin/codex-quota-poll.sh /root/.local/bin/codex-quota-set /root/.local/bin/tmux-configure-quota-visibility.sh

# 2) systemd 배치
cp tmux-backup/2026-02-13/systemd/*.service /etc/systemd/system/
cp tmux-backup/2026-02-13/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

# 3) 기본 서비스 활성화
systemctl enable --now ttyd-tmux.service

# 4) 답변 기반 quota/auth/ZAI 설정 반영
if [[ "$SHOW_CODEX" == "yes" ]]; then
  /root/.local/bin/tmux-configure-quota-visibility.sh \
    --show-codex yes \
    --codex-auth-source "$CODEX_AUTH_SOURCE" \
    --show-zai "$SHOW_ZAI"
else
  /root/.local/bin/tmux-configure-quota-visibility.sh \
    --show-codex no \
    --show-zai "$SHOW_ZAI"
fi

# 5) 레거시 codex poll timer(선택)
if [[ "$SHOW_CODEX" == "yes" ]]; then
  systemctl enable --now codex-quota-poll.timer || true
else
  systemctl disable --now codex-quota-poll.timer || true
fi

# 6) tmux 반영
tmux source-file /root/.tmux.conf || true

# 7) 검증
systemctl is-active ttyd-tmux.service
systemctl is-enabled tmux-zai-key-bootstrap.service || true
tmux show-options -g | grep -E '^base-index|^renumber-windows|^status |^status-format\[[0-9]+\]|^mouse'
tmux show-options -gqv status-format[0]
tmux show-environment -g CODEX_AUTH_FILE || true
tmux list-keys -T root | grep MouseDown1Status
tmux list-keys -T prefix | grep 'bind-key -T prefix g '
```

### 5.4 실패 시 AI가 보고해야 할 항목

- 어떤 명령이 실패했는지
- 실패 원인(권한/패키지 누락/서비스 이름 충돌 등)
- 재시도에 필요한 최소 조치 1~2개

## 6. AI에게 전달할 프롬프트 템플릿

아래 텍스트를 AI Agent에 그대로 전달하면 됩니다.

```text
/root/Tmux-Setup/README.md를 기준으로 이 저장소의 tmux 백업을 현재 시스템에 적용해줘.
설치 시작 전에 README 5.2의 3가지 질문을 먼저 사용자에게 하고 답변을 확정한 뒤 진행해.
반드시 "5. AI Agent 실행 가이드" 절차대로 실행하고, 각 단계 결과를 요약해.
민감정보 값은 출력하지 말고, 마지막에 검증 명령 결과(성공/실패)만 보고해.
실패가 있으면 원인과 재시도 최소 조치를 제시해.
```

## 7. 운영 확인 명령

```bash
systemctl is-active ttyd-tmux.service tmux-zai-key-bootstrap.service
systemctl show -p Result --value tmux-zai-key-bootstrap.service
tmux show-environment -g ZAI_API_KEY
/root/.local/bin/tmux-zai-quota.sh
/root/.local/bin/tmux-codex-quota.sh
```
