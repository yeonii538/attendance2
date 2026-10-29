# 팀 출퇴근 기록 (Supabase + Vercel 판)

- 데이터베이스·로그인: Supabase / 화면 호스팅: Vercel / 코드 보관: GitHub
- 출퇴근 시각은 데이터베이스 서버의 시계로 기록됩니다. 브라우저는 표에 직접 접근하지 못하고 `api_*` 함수만 호출합니다.

## 설정 순서
1. Supabase > SQL Editor > New query 에 `supabase/schema.sql` 전체를 붙여 넣고 Run.
2. Supabase > Authentication 에서 이메일 인증 설정 확인(내부 팀용이면 "Confirm email" 끄기를 권장. 켜 두면 인증 메일 발송 한도 때문에 가입이 막힐 수 있음).
3. `config.js` 에 Project URL 과 anon(공개) 키만 입력. service_role·secret 키, DB 비밀번호는 넣지 마세요.
4. GitHub 저장소에 이 폴더의 파일을 올리고(루트에 index.html 이 보이게), Vercel 에서 Import.
5. 가장 먼저 가입한 사람이 관리자. 가입 코드는 Supabase > Table Editor > settings 의 `signup_code` 값(가입 후에는 앱의 "가입 코드 보기"). 
   가입 코드를 쓰려면 첫 가입도 코드가 필요하므로 위 값을 먼저 확인하세요.

## 한계
- 실제 Supabase 프로젝트에서는 아직 시험하지 못했습니다. 오류가 나면 메시지를 알려 주세요.
- 사내 IP 제한은 이 판에 없습니다. 계정을 빌려주는 행위는 막지 못합니다.
