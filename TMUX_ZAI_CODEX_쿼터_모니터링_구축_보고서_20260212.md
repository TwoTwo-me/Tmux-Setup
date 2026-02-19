# TMUX Z.AI/Codex 쿼터 모니터링 구축 보고서 (최신 반영판, 2026-02-13)

## TL;DR

- 부팅 시 `ttyd + tmux(web)`가 올라온 뒤 Z.AI 키를 자동 주입해 쿼터가 바로 보이도록 구성했다.
- Z.AI는 실시간 API(`quota/limit`) 기반, Codex는 `wham/usage` 기반(캐시 TTL 기본 60초)으로 표시한다.
- 상태바 렌더러를 **2계층**으로 분리했다.
  - 상단: 좌측 `경로 + git 세그먼트`, 우측 `CODEX | Z.AI` 쿼터
  - 하단: 좌측 `전체 윈도우 pane 목록`, 우측 시스템 통계
- 최신 변경사항(요청 반영): pane cross-window 클릭 이동, 클릭 직후 즉시 하이라이트 갱신, `prefix + g` pane 제목 변경 프롬프트, ttyd 서비스 attach 방식 개선.

---

## 1) 목표와 범위

이 문서는 아래를 **누구나 그대로 재현**할 수 있게 정리한다.

1. tmux-web 환경에서 Z.AI/Codex 쿼터 표시
2. 재부팅 후 자동 복구(키 주입 + 캐시 기반 폴링)
3. 상태바 2줄 UI(경로·git + pane·시스템 + 우측 quota)
4. 클릭 가능한 window/pane 이동 UX

---

## 2) 현재 동작 아키텍처

```text
systemd boot
  ├─ ttyd-tmux.service
  │   ├─ ExecStartPre: tmux session(web) 없으면 생성
  │   └─ ExecStart: ttyd -> tmux attach-session -t web
  │
  ├─ tmux-zai-key-bootstrap.service (oneshot)
  │   └─ tmux-boot-key-sync.sh
  │      └─ tmux-load-opencode-key.sh
  │         └─ tmux global env에 ZAI_API_KEY 주입
  │
  └─ tmux-codex-quota.sh
      ├─ chatgpt.com/backend-api/wham/usage 조회
      ├─ ~/.cache/tmux-codex-usage.json 캐시
      └─ status-format[0] 우측 segment 렌더링

tmux status (2 lines)
  line0: [path + git-segment] .................................... [CODEX quota | Z.AI quota]
  line1: [pane list(all windows, clickable)] ...................... [CPU/RAM/time]
```

---

## 3) 핵심 구성 파일

## 3.1 tmux UI/렌더러

- `/root/.tmux.conf`
  - `base-index 1`, `renumber-windows on`
  - `mouse on`
  - `status 2`, `status-interval 20`
  - `status-format[0]`:
    - 좌: `tmux-path-right.sh` + `tmux-git-segment.sh`
    - 우: `tmux-codex-quota.sh` + `tmux-zai-quota.sh` (순서 고정: Codex -> Z.AI)
  - `status-format[1]`:
    - 좌: `tmux-pane-list.sh` (전체 window pane 렌더링)
    - 우: `tmux-right-stats.sh 48`
  - `prefix + g`로 현재 pane 제목 변경 prompt 호출
  - `MouseDown1Status`는 `tmux-status-click.sh`로 위임해 pane/window click 라우팅 수행

## 3.2 Z.AI 키 로딩/복구

- `/root/.local/bin/tmux-load-opencode-key.sh`
  - 키 탐색 우선순위:
    1) 현재 env
    2) tmux global env
    3) `~/.local/share/opencode/auth.json`
    4) `pass show api/zai` (1초 timeout fallback)
  - `HOME` 미정 환경(systemd/job) fallback 처리
  - 실패해도 `exit 0`로 hook 에러 전파 차단

- `/root/.local/bin/tmux-boot-key-sync.sh`
  - `web` 세션 생성 대기 후 로더 실행

- `/etc/systemd/system/tmux-zai-key-bootstrap.service`
  - `After/Wants=ttyd-tmux.service`
  - 부팅 시 oneshot 실행

## 3.3 Z.AI 쿼터 수집/표시

- `/root/.local/bin/tmux-zai-quota.sh`
  - API: `GET https://api.z.ai/api/monitor/usage/quota/limit`
  - 표시 항목:
    - `5h` (`TOKENS_LIMIT`, unit=3)
    - `7d` (`TOKENS_LIMIT`, unit=6)
    - `tools` (`TIME_LIMIT`, unit=5)
  - 각 항목: `남은 퍼센트 + 남은 시간`
  - 경고 배경 규칙:
    - `5h`: 남은 < 20%
    - `7d/tools`: 시간 경과 대비 사용률 초과 시

## 3.4 Codex 수집/표시

- `/root/.local/bin/tmux-codex-quota.sh`
  - API: `GET https://chatgpt.com/backend-api/wham/usage`
  - 인증 헤더:
    - `Authorization: Bearer <openai.access>`
    - `ChatGPT-Account-Id: <openai.accountId>` (존재 시)
  - 입력 소스: `~/.local/share/opencode/auth.json`
    - `.openai.access`
    - `.openai.accountId`
  - 표시 항목:
    - `5h` = `.rate_limit.primary_window`
    - `7d` = `.rate_limit.secondary_window`
    - `tools` = `.code_review_rate_limit.primary_window` 우선, 없으면 `additional_rate_limits` fallback
  - 캐시:
    - 파일: `~/.cache/tmux-codex-usage.json`
    - 기본 TTL: 60초 (`CODEX_QUOTA_CACHE_TTL_SEC`)
    - stale 임계: 1800초 (`CODEX_QUOTA_STALE_SEC`)
  - 실패 처리:
    - API 실패 시 캐시 fallback
    - stale 상태면 `stale Xm` suffix 표시

## 3.5 상태바 보조 스크립트

- `/root/.local/bin/tmux-path-right.sh`
  - 현재 경로를 항상 표시 (`HOME` 하위는 `~` 축약)
  - 상단 좌측 경로 폭 제한(현재 52)

- `/root/.local/bin/tmux-git-segment.sh`
  - git 내부일 때만 `repo:branch*` 세그먼트 출력
  - dirty 상태면 `*` suffix

- `/root/.local/bin/tmux-path-git.sh`
  - 레거시 포맷터(백업/호환 목적 유지)

- `/root/.local/bin/tmux-pane-list.sh`
  - 전체 window pane들을 나열 (`list-panes -a`)
  - 항목별 `#[range=user|%pane_id]` 부여(클릭 타겟)
  - 현재 보고 중 pane만 별도 배경색 강조

- `/root/.local/bin/tmux-status-click.sh`
  - 상태바 클릭 range(`%pane_id`, `@window_id`)를 해석
  - 다른 window pane 클릭 시 해당 window로 이동 후 pane 선택
  - 이동 직후 `refresh-client`로 하이라이트 즉시 반영

- `/root/.local/bin/tmux-right-stats.sh`
  - `tmux-sys-stats.sh` + 시간 문자열을 고정폭(우정렬) 렌더링

- `/root/.local/bin/tmux-sys-stats.sh`
  - `/proc/stat`, `/proc/meminfo` 기반 CPU/RAM 계산

---

## 4) 최신 변경 포인트 (이전 보고서 대비)

1. **ttyd 실행 모델 변경**
   - 기존: `tmux new -A -s web` 중심
   - 최신: `ExecStartPre`로 session 보장 + `attach-session -t web`로 접속 일원화

2. **상단 레이아웃 재설계**
   - 좌측: 경로 + git 세그먼트(`repo:branch*`)
   - 우측: Codex -> Z.AI quota 고정 순서

3. **상태바 클릭 UX 강화**
   - `window_id(@...)`/`pane_id(%...)` range 기반 선택
   - 클릭 라우팅을 `tmux-status-click.sh`로 분리
   - cross-window pane 클릭 즉시 이동 + 즉시 하이라이트 반영

4. **하단 좌측 pane 목록 확장**
   - 현재 window만 보이던 pane 목록을 전체 window 대상으로 확장
   - pane 식별 포맷 `window.pane:title`로 통일

5. **pane 제목 운영 기능 추가**
   - `prefix + g` -> 현재 pane title 입력 프롬프트

6. **healthcheck는 PASS지만 경고 1개가 정상일 수 있음**
   - 스크립트가 `status-format[1]`에 `tmux-zai-quota.sh` 존재를 검사하는데
   - 현재 설계는 Z.AI가 `status-format[0]`에 있으므로 WARN이 뜰 수 있음

---

## 5) 재현 절차

## 5.1 서비스 상태 확인

```bash
systemctl is-enabled ttyd-tmux.service tmux-zai-key-bootstrap.service
systemctl is-active ttyd-tmux.service
systemctl show -p Result --value tmux-zai-key-bootstrap.service
```

기대값: `enabled`, `active`, `success`

## 5.2 tmux 옵션 확인

```bash
tmux show-options -g | grep -E '^base-index|^renumber-windows|^status |^status-format\[[0-9]+\]|^status-position'
tmux list-keys -T prefix | grep 'bind-key -T prefix g '
tmux list-keys -T root | grep MouseDown1Status
```

핵심 기대값:

- `base-index 1`
- `renumber-windows on`
- `status 2`
- `status-format[0]`, `status-format[1]`

## 5.3 출력 확인

```bash
/root/.local/bin/tmux-zai-quota.sh
/root/.local/bin/tmux-codex-quota.sh
/root/.local/bin/tmux-zai-healthcheck.sh
```

---

## 6) 운영 점검 명령어

```bash
# tmux 키 환경
tmux show-environment -g ZAI_API_KEY

# 부팅 키 주입
systemctl status tmux-zai-key-bootstrap.service --no-pager
journalctl -u tmux-zai-key-bootstrap.service -b --no-pager

# codex quota 캐시/인증 상태
ls -l /root/.cache/tmux-codex-usage.json
jq -r '.openai.expires // empty' /root/.local/share/opencode/auth.json
/root/.opencode/bin/opencode auth list

# window/pane 스냅샷
tmux list-windows -a -F '#S:#I:#W'
tmux list-panes -a -F '#S:#I.#P #{pane_id} #{pane_current_command}'
```

---

## 7) 현재 운영 스냅샷 (작성 시점)

- 서비스
  - `ttyd-tmux.service`: enabled/active
  - `tmux-zai-key-bootstrap.service`: enabled, last result success
- 세션/윈도우
  - `web:1:opencode`, `web:2:bash`
- pane
  - `web:1.0 %0 opencode`
  - `web:1.1 %1 bash`
  - `web:2.0 %2 bash`

---

## 8) 한계와 주의사항

1. Codex quota는 `wham/usage` 응답 스키마에 의존하므로, 상위 서비스 스키마 변경 시 파서 수정이 필요할 수 있음
2. 경로/Pane 표시 길이는 터미널 폭에 영향을 받으며, 경로는 상단에서 tail-truncate(현재 52) 적용
3. Z.AI `unit` 의미는 일부 공식 문서 + 구현 관찰 기반 해석
4. Codex access token 만료 시 자동 refresh를 이 스크립트에서 직접 수행하지 않으므로 재로그인이 필요할 수 있음

---

## 9) 외부 출처

### tmux

- tmux man page (`status`, `status-format[]`, `base-index`, `renumber-windows`, status line 구조)
  - https://man7.org/linux/man-pages/man1/tmux.1.html

### Z.AI Coding Plan/Usage

- Usage Query Plugin 문서
  - https://docs.z.ai/devpack/extension/usage-query-plugin
- Coding Plan Overview
  - https://docs.z.ai/devpack/overview
- FAQ (5시간/주간/MCP 정책)
  - https://docs.z.ai/devpack/faq
- 공식 플러그인 스크립트(usage endpoint 확인)
  - https://raw.githubusercontent.com/zai-org/zai-coding-plugins/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs
- OSS 구현 예시
  - https://raw.githubusercontent.com/openclaw/openclaw/main/src/infra/provider-usage.fetch.zai.ts
  - https://raw.githubusercontent.com/opgginc/opencode-bar/main/scripts/query-zai-coding-plan.sh

### OpenAI Codex/ChatGPT Usage

- OpenAI Codex auth docs
  - https://developers.openai.com/codex/auth
- OpenAI Codex pricing/limits docs
  - https://developers.openai.com/codex/pricing
- OpenAI Codex OSS (backend client usage path)
  - https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client.rs
- Community implementation (`wham/usage` 파싱)
  - https://raw.githubusercontent.com/openclaw/openclaw/main/src/infra/provider-usage.fetch.codex.ts
  - https://raw.githubusercontent.com/RooCodeInc/Roo-Code/main/src/integrations/openai-codex/rate-limits.ts

---

## 10) 다음 개선 제안

1. `tmux-zai-healthcheck.sh`의 Z.AI 라인 검사 위치를 `status-format[0]` 기준으로 업데이트
2. pane 라벨 축약(`0:oc`, `1:sh`) 옵션 추가
3. Codex quota 401 발생 시 `opencode auth login` 재인증 가이드 링크를 health 문구로 노출

---

## 11) 토큰/키 갱신 운영 자료 (추가)

## 11.1 인증 데이터 구조

- 경로: `/root/.local/share/opencode/auth.json`
- OpenAI(Codex) 관련 필드:
  - `.openai.access` (Bearer token)
  - `.openai.refresh` (refresh token)
  - `.openai.expires` (epoch ms)
  - `.openai.accountId` (workspace/account 헤더)
- Z.AI 관련 필드:
  - `."zai-coding-plan".key`

## 11.2 Codex 토큰 만료/갱신 런북

1. 만료/인증 실패 징후
   - `tmux-codex-quota.sh`가 `codex quota unavailable` 또는 `stale`만 지속 출력
   - `wham/usage` 호출이 401/403 응답

2. 점검 명령

```bash
# 만료 시각(epoch ms) 확인
jq -r '.openai.expires // empty' /root/.local/share/opencode/auth.json

# 현재 등록 provider 확인
/root/.opencode/bin/opencode auth list
```

3. 갱신 절차

```bash
# 필요 시 로그아웃 후 재로그인
/root/.opencode/bin/opencode auth logout
/root/.opencode/bin/opencode auth login openai

# 즉시 렌더 확인
/root/.local/bin/tmux-codex-quota.sh
```

4. 운영 파라미터(폴링/캐시)
   - `CODEX_QUOTA_CACHE_TTL_SEC` (기본 60)
   - `CODEX_QUOTA_STALE_SEC` (기본 1800)
   - `CODEX_QUOTA_TIMEOUT_SEC` (기본 8)

## 11.3 Z.AI 키 갱신/동기화 런북

1. 키 갱신 위치
   - `auth.json`의 `."zai-coding-plan".key` 갱신

2. tmux 반영

```bash
/root/.local/bin/tmux-load-opencode-key.sh
tmux show-environment -g ZAI_API_KEY
/root/.local/bin/tmux-zai-quota.sh
```

3. 재부팅 후 자동화
   - `tmux-zai-key-bootstrap.service`가 부팅 시 자동 주입
   - 수동 재적용이 필요하면 위 명령 재실행
