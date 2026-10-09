-- P2 Enrichment pipeline: database setup (Supabase / Postgres)
-- Applied in this order. Requires the P1 schema (icp_companies, job_posts, dead_letter, runs) from gtm-icp-engine.
-- Note: later migrations replace some functions from earlier ones (create or replace); the final versions are what run.


-- ============================================================
-- 20261005154021  p2_identity_resolution
-- ============================================================
create extension if not exists fuzzystrmatch with schema extensions;
create extension if not exists unaccent with schema extensions;

-- ===== 1. Company name matching =====
create table if not exists legal_suffixes (suffix text primary key);
insert into legal_suffixes(suffix) values
 ('inc'),('incorporated'),('llc'),('llp'),('lp'),('ltd'),('limited'),('corp'),('corporation'),('co'),('company'),
 ('plc'),('gmbh'),('ag'),('sa'),('sas'),('sarl'),('srl'),('spa'),('bv'),('nv'),('pty'),('pvt'),('oy'),('ab'),('as'),('aps'),('kg'),('ug'),('se'),('ltda'),('the')
on conflict do nothing;

create or replace function normalize_company_name(n text) returns text
language sql stable set search_path = public, extensions as $$
  select nullif(btrim(regexp_replace(
    (select string_agg(w, ' ' order by i) from unnest(
        string_to_array(btrim(regexp_replace(regexp_replace(regexp_replace(
          lower(extensions.unaccent(coalesce(n,''))),
          '\([^)]*\)', ' ', 'g'),          -- drop anything in brackets
          '&', ' and ', 'g'),
          '[^a-z0-9]+', ' ', 'g')), ' ')
      ) with ordinality as t(w, i)
      where w <> '' and w not in (select suffix from legal_suffixes)),
    '\s+', ' ', 'g')), '')
$$;

create or replace function company_name_match(a text, b text)
returns table(norm_a text, norm_b text, distance int, similarity numeric, verdict text)
language sql stable set search_path = public, extensions as $$
  with n as (select normalize_company_name(a) na, normalize_company_name(b) nb),
  c as (select na, nb, replace(na,' ','') ca, replace(nb,' ','') cb from n),
  d as (select na, nb, ca, cb, extensions.levenshtein(left(ca,255), left(cb,255)) dist,
        greatest(length(ca), length(cb)) mx from c)
  select na, nb, dist,
    case when mx = 0 then 0 else round(1 - dist::numeric / mx, 2) end,
    case
      when ca is null or cb is null then 'no name'
      when ca = cb then 'same'
      when least(length(ca), length(cb)) < 5 then 'different'      -- short names: exact only
      when 1 - dist::numeric / mx >= 0.90 then 'same'
      when 1 - dist::numeric / mx >= 0.80 then 'review'
      else 'different' end
  from d
$$;

-- ===== 2. Domain identity =====
create table if not exists multi_part_suffixes (suffix text primary key);
insert into multi_part_suffixes(suffix) values
 ('co.uk'),('org.uk'),('ac.uk'),('gov.uk'),('com.au'),('net.au'),('org.au'),('com.br'),('net.br'),('org.br'),
 ('co.za'),('org.za'),('com.ng'),('org.ng'),('gov.ng'),('edu.ng'),('co.ke'),('com.gh'),('co.nz'),('co.in'),('co.jp'),
 ('com.mx'),('com.ar'),('com.co'),('com.sg'),('com.my'),('com.tr'),('com.cn'),('com.hk'),('co.il'),('com.eg'),('co.id'),('com.ph'),('com.pk')
on conflict do nothing;

create table if not exists free_email_domains (domain text primary key);
insert into free_email_domains(domain) values
 ('gmail.com'),('googlemail.com'),('yahoo.com'),('yahoo.co.uk'),('outlook.com'),('hotmail.com'),('live.com'),('msn.com'),
 ('icloud.com'),('me.com'),('aol.com'),('proton.me'),('protonmail.com'),('gmx.com'),('gmx.de'),('yandex.com'),('mail.com'),('zoho.com')
on conflict do nothing;

create or replace function domain_clean(d text) returns text
language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(d,''))),
    '^[a-z]+://', ''),          -- scheme
    '^[^@]*@', ''),             -- email -> domain
    '[/:?#].*$', ''),           -- path, port, query
    '^www\d*\.|\.$', '', 'g'), '')
$$;

create or replace function domain_root(d text) returns text
language sql stable set search_path = public as $$
  with p as (select string_to_array(domain_clean(d), '.') l)
  select case
    when l is null or cardinality(l) < 2 then domain_clean(d)
    when cardinality(l) >= 3 and (l[cardinality(l)-1] || '.' || l[cardinality(l)]) in (select suffix from multi_part_suffixes)
      then array_to_string(l[cardinality(l)-2:cardinality(l)], '.')
    else array_to_string(l[cardinality(l)-1:cardinality(l)], '.') end
  from p
$$;

create or replace function domain_brand(d text) returns text
language sql stable set search_path = public as $$ select split_part(domain_root(d), '.', 1) $$;

create or replace function domain_identity(a text, b text) returns text
language sql stable set search_path = public as $$
  select case
    when domain_root(a) is null or domain_root(b) is null then 'missing'
    when domain_root(a) in (select domain from free_email_domains)
      or domain_root(b) in (select domain from free_email_domains) then 'personal email - not a company'
    when domain_root(a) = domain_root(b) then 'same company'
    when domain_brand(a) = domain_brand(b) then 'same brand, different country - check name'
    else 'different' end
$$;

-- ===== 3. Title normalization (lookup tables, not AI) =====
create table if not exists title_function_map (
  priority int primary key, pattern text not null, job_function text not null, note text);
insert into title_function_map values
 (10, '(gtm|go[- ]to[- ]market).{0,30}engineer|engineer.{0,20}\mgtm\M', 'GTM Engineering', 'checked first: most specific'),
 (20, 'rev ?ops|revenue operations|\mrev/', 'Revenue Operations', null),
 (30, 'sales (and |& )?(marketing )?op(eration)?s', 'Sales Operations', null),
 (40, 'marketing op(eration)?s', 'Marketing Operations', null),
 (50, 'marketing automation', 'Marketing Automation', null),
 (60, 'growth op(eration)?s', 'Growth Operations', null),
 (70, '(salesforce|hubspot|crm|dynamics).{0,25}(developer|engineer|architect)|(developer|engineer|architect).{0,25}(salesforce|hubspot|crm)', 'CRM Development', null),
 (80, '(salesforce|hubspot|crm|gtm systems).{0,25}admin', 'CRM Administration', null),
 (90, '(salesforce|hubspot).{0,30}(specialist|consultant|expert|strateg|implementation)|(specialist|consultant|expert).{0,20}(salesforce|hubspot)', 'CRM Consulting', null),
 (100, '\mcrm\M|lifecycle', 'CRM & Lifecycle Marketing', null),
 (110, '\mgtm\M|go[- ]to[- ]market', 'GTM Strategy', 'catch-all for other GTM titles')
on conflict (priority) do nothing;

create table if not exists title_seniority_map (
  priority int primary key, pattern text not null, seniority text not null);
insert into title_seniority_map values
 (10, '\m(chief|cro|svp|evp|vp|vice president)\M', 'Executive'),
 (20, '\m(director|head)\M|teamf.hrung', 'Director'),
 (30, '\m(principal|staff|lead|leader|architect)\M', 'Lead'),
 (40, '\m(senior|sr|iii|s.nior)\M', 'Senior'),
 (50, '\m(manager|gerente)\M', 'Manager'),
 (60, '\m(junior|jr|associate|assistant|asystent|coordinator|intern|internship|entry level|working student|praktikum|pflichtpraktikum|stage|l1)\M', 'Junior')
on conflict (priority) do nothing;

create or replace function clean_title(t text) returns text
language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(t,''),
    '^[#\[(]?[A-Za-z]*\d+[\])]?\s*[-:]?\s*', ''),            -- leading job codes like "#130515 -" or "(0103)"
    '\((m|w|f|d)/(m|w|f|d)/(m|w|f|d)\)', '', 'gi'),           -- (m/w/d)
    '\s*[|]\s*.*$', ''),                                       -- "| Remote ..." tails
    '\s+', ' ', 'g'))
$$;

create or replace function normalize_title(t text)
returns table(clean text, job_function text, seniority text)
language sql stable set search_path = public as $$
  select clean_title(t),
    coalesce((select m.job_function from title_function_map m where clean_title(t) ~* m.pattern order by m.priority limit 1), 'Unmapped'),
    coalesce((select s.seniority from title_seniority_map s where clean_title(t) ~* s.pattern order by s.priority limit 1), 'Mid')
$$;

create or replace view job_titles_normalized with (security_invoker = true) as
  select p.source, p.source_job_id, p.company_name, p.title, n.clean, n.job_function, n.seniority,
         n.seniority in ('Junior','Mid','Senior','Manager') as in_my_range
  from job_posts p cross join lateral normalize_title(p.title) n;

-- ===== Identity resolution over real data =====
create or replace view company_duplicate_candidates with (security_invoker = true) as
  select a.company_key key_a, a.company_name name_a, a.domain domain_a,
         b.company_key key_b, b.company_name name_b, b.domain domain_b,
         m.similarity name_similarity, m.verdict name_verdict,
         domain_identity(a.domain, b.domain) domain_verdict,
         case
           when domain_identity(a.domain, b.domain) = 'same company' then 'merge'
           when m.verdict = 'same' and domain_identity(a.domain, b.domain) in ('missing','same brand, different country - check name') then 'merge'
           when m.verdict in ('same','review') or domain_identity(a.domain, b.domain) like 'same brand%' then 'review'
           else 'keep separate' end as decision
  from icp_companies a
  join icp_companies b on a.company_key < b.company_key
  cross join lateral company_name_match(a.company_name, b.company_name) m
  where m.verdict in ('same','review')
     or domain_root(a.domain) = domain_root(b.domain)
     or domain_brand(a.domain) = domain_brand(b.domain);

alter table legal_suffixes enable row level security;
alter table multi_part_suffixes enable row level security;
alter table free_email_domains enable row level security;
alter table title_function_map enable row level security;
alter table title_seniority_map enable row level security;

-- ============================================================
-- 20261005154049  p2_name_match_fixes
-- ============================================================
create or replace function normalize_company_name(n text) returns text
language sql stable set search_path = public, extensions as $$
  select nullif(btrim(regexp_replace(regexp_replace(
    (select string_agg(w, ' ' order by i) from unnest(
        string_to_array(btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
          lower(extensions.unaccent(coalesce(n,''))),
          '[.'']', '', 'g'),                -- S.A. -> sa, Inc. -> inc, O'Neil -> oneil
          '\([^)]*\)', ' ', 'g'),           -- drop anything in brackets
          '&', ' and ', 'g'),
          '[^a-z0-9]+', ' ', 'g')), ' ')
      ) with ordinality as t(w, i)
      where w <> '' and w not in (select suffix from legal_suffixes)),
    '(^and\s+|\s+and$)', '', 'g'),        -- "Zone & Co" -> "zone"
    '\s+', ' ', 'g')), '')
$$;

create or replace function company_name_match(a text, b text)
returns table(norm_a text, norm_b text, distance int, similarity numeric, verdict text)
language sql stable set search_path = public, extensions as $$
  with n as (select normalize_company_name(a) na, normalize_company_name(b) nb),
  c as (select na, nb, replace(na,' ','') ca, replace(nb,' ','') cb from n),
  d as (select na, nb, ca, cb, extensions.levenshtein(left(ca,255), left(cb,255)) dist,
        greatest(length(ca), length(cb)) mx from c)
  select na, nb, dist,
    case when mx = 0 then 0 else round(1 - dist::numeric / mx, 2) end,
    case
      when ca is null or cb is null then 'no name'
      when ca = cb then 'same'
      when least(length(ca), length(cb)) < 5 then 'different'                 -- short names: exact only
      when 1 - dist::numeric / mx >= 0.90 then 'same'
      when 1 - dist::numeric / mx >= 0.75 then 'review'                       -- typos / swapped letters
      when (nb || ' ') like (na || ' %') or (na || ' ') like (nb || ' %') then 'review'  -- "Motive" vs "Motive Technologies"
      else 'different' end
  from d
$$;

-- ============================================================
-- 20261005154339  p2_match_candidates_blocking
-- ============================================================
create or replace function name_verdict(na text, nb text) returns text
language sql immutable set search_path = public, extensions as $$
  with c as (select replace(na,' ','') ca, replace(nb,' ','') cb),
  d as (select ca, cb, extensions.levenshtein(left(ca,255), left(cb,255)) dist, greatest(length(ca),length(cb)) mx from c)
  select case
      when ca is null or cb is null or mx = 0 then 'no name'
      when ca = cb then 'same'
      when least(length(ca), length(cb)) < 5 then 'different'
      when 1 - dist::numeric / mx >= 0.90 then 'same'
      when 1 - dist::numeric / mx >= 0.75 then 'review'
      when (nb || ' ') like (na || ' %') or (na || ' ') like (nb || ' %') then 'review'
      else 'different' end
  from d
$$;

create or replace view company_match_candidates with (security_invoker = true) as
  with c as (
    select company_key, company_name, domain,
           normalize_company_name(company_name) norm,
           domain_root(domain) droot, domain_brand(domain) dbrand
    from icp_companies),
  c2 as (select *, left(replace(norm,' ',''),3) block from c),
  pairs as (
    select a.company_key key_a, a.company_name name_a, a.domain domain_a,
           b.company_key key_b, b.company_name name_b, b.domain domain_b,
           a.norm norm_a, b.norm norm_b, a.droot ra, b.droot rb, a.dbrand ba, b.dbrand bb
    from c2 a join c2 b on a.company_key < b.company_key
     and (a.block = b.block or a.droot = b.droot or a.dbrand = b.dbrand)),
  scored as (
    select *, name_verdict(norm_a, norm_b) nv,
      case when ra is null or rb is null then 'missing'
           when ra = rb then 'same company'
           when ba = bb then 'same brand, different country - check name'
           else 'different' end dv
    from pairs)
  select key_a, name_a, domain_a, key_b, name_b, domain_b, nv name_verdict, dv domain_verdict,
    case
      when dv = 'same company' then 'merge'
      when nv = 'same' and dv in ('missing','same brand, different country - check name') then 'merge'
      when nv in ('same','review') or dv like 'same brand%' then 'review'
      else 'keep separate' end decision
  from scored
  where nv in ('same','review') or dv in ('same company','same brand, different country - check name');

comment on view company_duplicate_candidates is 'Superseded by company_match_candidates (all-pairs version, too slow). Safe to drop.';

-- ============================================================
-- 20261005154419  p2_title_fixes
-- ============================================================
create or replace function clean_title(t text) returns text
language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(t,''),
    '^\s*(#?[A-Za-z]*\d+[A-Za-z]*\s*[-:]|\(\d+\)|\[[^\]]*\]|:)\s*', ''),   -- job codes: "#130515 -", "V106C -", "TECH711:", "(0103)", "[EMF Engage]"
    '\((m|w|f|d)/(m|w|f|d)/(m|w|f|d)\)', '', 'gi'),                       -- (m/w/d)
    '\s*[|]\s*.*$', ''),                                                   -- "| Remote ..." tails
    '\s+', ' ', 'g'))
$$;
insert into title_function_map values (105, 'demand gen', 'Demand Generation', 'added after reviewing unmapped titles')
on conflict (priority) do nothing;

-- ============================================================
-- 20261006154015  p2_reliability_layer
-- ============================================================
create table if not exists role_address_prefixes (prefix text primary key);
insert into role_address_prefixes values
 ('info'),('sales'),('support'),('hello'),('contact'),('admin'),('office'),('team'),('careers'),('jobs'),('hr'),
 ('marketing'),('billing'),('accounts'),('help'),('enquiries'),('inquiries'),('noreply'),('no-reply'),('press'),('partners'),('founders')
on conflict do nothing;

create or replace function email_risk(email text, domain_is_catch_all boolean default null) returns text
language sql stable set search_path = public as $$
  select case
    when email is null or email !~* '^[a-z0-9._%+''-]+@[a-z0-9.-]+\.[a-z]{2,}$' then 'invalid'
    when domain_root(email) in (select domain from free_email_domains) then 'personal (not a work email)'
    when lower(split_part(email,'@',1)) in (select prefix from role_address_prefixes) then 'role address (risky)'
    when domain_is_catch_all then 'catch-all (risky)'
    when domain_is_catch_all is null then 'unverified'
    else 'ok' end
$$;

create table if not exists field_ttl (field text primary key, ttl_days int not null, why text);
insert into field_ttl values
 ('hiring_signal', 14, 'Job posts close fast; a 3-week-old post may be filled'),
 ('icp_score', 14, 'Depends on hiring signal and freshness, so it ages with them'),
 ('email_verification', 30, 'Mailboxes are deleted when people leave; re-verify before sending'),
 ('job_title', 90, 'People get promoted or change roles every few months'),
 ('email_address', 90, 'Follows the person; changes when they change jobs'),
 ('company_size', 180, 'Headcount moves slowly'),
 ('domain', 365, 'Companies rarely change their website')
on conflict (field) do nothing;

create or replace view icp_companies_freshness with (security_invoker = true) as
  select c.company_key, c.company_name,
    c.enriched_at, (now() - c.enriched_at) > make_interval(days => (select ttl_days from field_ttl where field='domain')) as domain_stale,
    c.scored_at,  (now() - c.scored_at)  > make_interval(days => (select ttl_days from field_ttl where field='icp_score')) as score_stale
  from icp_companies c;

create or replace function backoff_delay_ms(attempt int, base_ms int default 1000, cap_ms int default 60000) returns int
language sql volatile as $$
  select floor(random() * least(cap_ms, base_ms * power(2, greatest(attempt,0))))::int
$$;

create table if not exists provider_health (
  provider text primary key,
  state text not null default 'closed' check (state in ('closed','open','half_open')),
  consecutive_failures int not null default 0,
  failure_threshold int not null default 5,
  cooldown_seconds int not null default 300,
  opened_at timestamptz, last_error text, last_success_at timestamptz, last_failure_at timestamptz,
  total_calls int not null default 0, total_failures int not null default 0, total_skipped int not null default 0);
alter table provider_health enable row level security;
insert into provider_health(provider, failure_threshold, cooldown_seconds) values
 ('clearbit', 5, 300), ('hunter', 3, 3600), ('apollo', 3, 3600), ('website_scrape', 5, 300), ('supabase', 5, 60)
on conflict do nothing;

create or replace function provider_check(p text) returns text
language plpgsql set search_path = public as $$
declare h provider_health;
begin
  insert into provider_health(provider) values (p) on conflict do nothing;
  select * into h from provider_health where provider = p for update;
  if h.state = 'open' then
    if now() < h.opened_at + make_interval(secs => h.cooldown_seconds) then
      update provider_health set total_skipped = total_skipped + 1 where provider = p;
      return 'skip';
    end if;
    update provider_health set state = 'half_open' where provider = p;
  end if;
  return 'try';
end $$;

create or replace function provider_record(p text, ok boolean, err text default null) returns text
language plpgsql set search_path = public as $$
declare h provider_health;
begin
  insert into provider_health(provider) values (p) on conflict do nothing;
  select * into h from provider_health where provider = p for update;
  if ok then
    update provider_health set state='closed', consecutive_failures=0, opened_at=null,
      last_success_at=now(), total_calls=total_calls+1 where provider = p;
    return 'closed';
  end if;
  if h.state = 'half_open' or h.consecutive_failures + 1 >= h.failure_threshold then
    update provider_health set state='open', opened_at=now(), consecutive_failures=consecutive_failures+1,
      last_error=left(err,500), last_failure_at=now(), total_calls=total_calls+1, total_failures=total_failures+1 where provider = p;
    return 'open';
  end if;
  update provider_health set consecutive_failures=consecutive_failures+1, last_error=left(err,500),
    last_failure_at=now(), total_calls=total_calls+1, total_failures=total_failures+1 where provider = p;
  return 'closed';
end $$;

alter table dead_letter add column if not exists status text not null default 'new';
alter table dead_letter add column if not exists attempts int not null default 0;
alter table dead_letter add column if not exists max_attempts int not null default 5;
alter table dead_letter add column if not exists next_retry_at timestamptz not null default now();
alter table dead_letter add column if not exists provider text;
alter table dead_letter add column if not exists last_replay_error text;
alter table dead_letter add column if not exists resolved_at timestamptz;
alter table dead_letter add column if not exists resolution text;
do $$ begin
  alter table dead_letter add constraint dead_letter_status_chk
    check (status in ('new','retrying','resolved','gave_up','not_replayable'));
exception when duplicate_object then null; end $$;

create or replace view dead_letter_replay_queue with (security_invoker = true) as
  select id, node, provider, payload, attempts, max_attempts, created_at, last_replay_error
  from dead_letter
  where status in ('new','retrying') and next_retry_at <= now()
  order by created_at;

create or replace function replay_result(dl_id bigint, ok boolean, err text default null, row_data jsonb default null)
returns text language plpgsql set search_path = public as $$
declare d dead_letter; save_err text;
begin
  select * into d from dead_letter where id = dl_id for update;
  if d.id is null then return 'unknown id'; end if;
  if ok and row_data is not null then
    begin
      insert into icp_companies as t (company_key, company_name, company_slug, domain, domain_confidence, enriched_at, enrich_error)
      values (row_data->>'company_key', row_data->>'company_name', row_data->>'company_slug',
              row_data->>'domain', row_data->>'domain_confidence', now(), row_data->>'enrich_error')
      on conflict (company_key) do update set domain=excluded.domain, domain_confidence=excluded.domain_confidence,
        enriched_at=excluded.enriched_at, enrich_error=excluded.enrich_error;
    exception when unique_violation then
      ok := false; save_err := 'duplicate domain: ' || sqlerrm;
    end;
  end if;
  if ok then
    update dead_letter set status='resolved', attempts=attempts+1, resolved_at=now(), resolution='replayed successfully' where id=dl_id;
    return 'resolved';
  end if;
  if save_err is not null then
    update dead_letter set status='not_replayable', attempts=attempts+1, last_replay_error=left(save_err,500),
      resolution='data error, needs a human' where id=dl_id;
    return 'not_replayable';
  end if;
  if d.attempts + 1 >= d.max_attempts then
    update dead_letter set status='gave_up', attempts=attempts+1, last_replay_error=left(err,500),
      resolution='gave up after max attempts' where id=dl_id;
    return 'gave_up';
  end if;
  update dead_letter set status='retrying', attempts=attempts+1, last_replay_error=left(err,500),
    next_retry_at = now() + make_interval(secs => backoff_delay_ms(d.attempts + 1, 60000, 21600000) / 1000.0)
  where id=dl_id;
  return 'retrying';
end $$;

alter table role_address_prefixes enable row level security;
alter table field_ttl enable row level security;

-- ============================================================
-- 20261006154124  p2_replay_queue_and_tests
-- ============================================================
create or replace view dead_letter_replay_queue with (security_invoker = true) as
  select id, node, provider, payload, attempts, max_attempts, created_at, last_replay_error
  from dead_letter
  where status in ('new','retrying') and next_retry_at <= now()
    and provider is not null                     -- P1 history (no provider label) is left alone
    and provider not in ('himalayas_page')       -- blocked by bot protection: never replay
  order by created_at;

-- Self-cleaning test: does real work inside a savepoint, records what happened, then rolls it all back.
create or replace function test_reliability_layer()
returns table(test text, expected text, got text, pass boolean)
language plpgsql set search_path = public as $$
declare r record; s text; t text[] := '{}'; e text[] := '{}'; g text[] := '{}'; dl bigint; i int;
begin
  begin
    -- circuit breaker: threshold 3, cooldown 0s for the test
    insert into provider_health(provider, failure_threshold, cooldown_seconds) values ('zz_test', 3, 3600);
    s := provider_record('zz_test', false, 'timeout'); t := t||'1st failure'; e := e||'closed'::text; g := g||s;
    s := provider_record('zz_test', false, 'timeout'); t := t||'2nd failure'; e := e||'closed'::text; g := g||s;
    s := provider_record('zz_test', false, 'timeout'); t := t||'3rd failure trips breaker'; e := e||'open'::text; g := g||s;
    s := provider_check('zz_test'); t := t||'call while open is skipped'; e := e||'skip'::text; g := g||s;
    update provider_health set opened_at = now() - interval '2 hours' where provider='zz_test';
    s := provider_check('zz_test'); t := t||'after cooldown: one test call allowed'; e := e||'try'::text; g := g||s;
    select state into s from provider_health where provider='zz_test'; t := t||'state during test call'; e := e||'half_open'::text; g := g||s;
    s := provider_record('zz_test', false, 'still down'); t := t||'test call fails: reopen at once'; e := e||'open'::text; g := g||s;
    update provider_health set opened_at = now() - interval '2 hours' where provider='zz_test';
    perform provider_check('zz_test');
    s := provider_record('zz_test', true); t := t||'test call succeeds: close'; e := e||'closed'::text; g := g||s;

    -- email risk
    t := t||'role address'; e := e||'role address (risky)'::text; g := g||email_risk('sales@acme.com', false);
    t := t||'catch-all domain'; e := e||'catch-all (risky)'::text; g := g||email_risk('jane.doe@acme.com', true);
    t := t||'gmail'; e := e||'personal (not a work email)'::text; g := g||email_risk('jane@gmail.com');
    t := t||'verified person'; e := e||'ok'::text; g := g||email_risk('jane.doe@acme.com', false);
    t := t||'broken email'; e := e||'invalid'::text; g := g||email_risk('jane@@acme');

    -- dead-letter replay
    insert into dead_letter(node, error, payload, provider) values ('Find domain (Clearbit)','timeout',
      '{"company_key":"zz-test-co","company_name":"ZZ Test Co","company_slug":"zz-test-co"}', 'clearbit') returning id into dl;
    select count(*)::text into s from dead_letter_replay_queue where id = dl; t := t||'new failure appears in replay queue'; e := e||'1'::text; g := g||s;
    s := replay_result(dl, false, 'timeout again'); t := t||'replay fails: retry later'; e := e||'retrying'::text; g := g||s;
    select count(*)::text into s from dead_letter_replay_queue where id = dl; t := t||'waits for its backoff time'; e := e||'0'::text; g := g||s;
    update dead_letter set next_retry_at = now() where id = dl;
    s := replay_result(dl, true, null, '{"company_key":"zz-test-co","company_name":"ZZ Test Co","domain":"zztestco-example.com","domain_confidence":"high"}');
    t := t||'replay succeeds: resolved + saved'; e := e||'resolved'::text; g := g||s;
    select count(*)::text into s from icp_companies where company_key='zz-test-co'; t := t||'company row saved'; e := e||'1'::text; g := g||s;

    insert into dead_letter(node, error, payload, provider) values ('x','x','{}','clearbit') returning id into dl;
    for i in 1..5 loop s := replay_result(dl, false, 'down'); update dead_letter set next_retry_at = now() where id = dl; end loop;
    t := t||'5 failed replays: give up'; e := e||'gave_up'::text; g := g||s;

    insert into dead_letter(node, error, payload, provider) values ('x','x','{}','clearbit') returning id into dl;
    s := replay_result(dl, true, null, jsonb_build_object('company_key','zz-dupe','company_name','Motive','domain',
         (select domain from icp_companies where domain is not null limit 1),'domain_confidence','high'));
    t := t||'duplicate domain: data error, no retry'; e := e||'not_replayable'::text; g := g||s;

    raise exception 'rollback_test';
  exception when others then
    if sqlerrm <> 'rollback_test' then t := t||'ERROR'; e := e||''::text; g := g||sqlerrm; end if;
  end;
  return query select t[k], e[k], g[k], e[k] = g[k] from generate_subscripts(t,1) k;
end $$;

create or replace function test_backoff_distribution()
returns table(attempt int, ceiling_ms int, min_ms int, avg_ms int, max_ms int)
language sql volatile as $$
  select a, least(60000, 1000 * power(2,a))::int, min(d), avg(d)::int, max(d)
  from generate_series(0,7) a, lateral (select backoff_delay_ms(a) d from generate_series(1,1000)) x
  group by a order by a
$$;

-- ============================================================
-- 20261006154204  p2_fix_test_fn
-- ============================================================
create or replace function test_reliability_layer()
returns table(test text, expected text, got text, pass boolean)
language plpgsql set search_path = public as $$
declare s text; t text[] := '{}'; e text[] := '{}'; g text[] := '{}'; dl bigint; i int;
begin
  begin
    insert into provider_health(provider, failure_threshold, cooldown_seconds) values ('zz_test', 3, 3600);
    s := provider_record('zz_test', false, 'timeout'); t := array_append(t,'1st failure'); e := array_append(e,'closed'); g := array_append(g,s);
    s := provider_record('zz_test', false, 'timeout'); t := array_append(t,'2nd failure'); e := array_append(e,'closed'); g := array_append(g,s);
    s := provider_record('zz_test', false, 'timeout'); t := array_append(t,'3rd failure trips breaker'); e := array_append(e,'open'); g := array_append(g,s);
    s := provider_check('zz_test'); t := array_append(t,'call while open is skipped'); e := array_append(e,'skip'); g := array_append(g,s);
    update provider_health set opened_at = now() - interval '2 hours' where provider='zz_test';
    s := provider_check('zz_test'); t := array_append(t,'after cooldown: one test call allowed'); e := array_append(e,'try'); g := array_append(g,s);
    select state into s from provider_health where provider='zz_test'; t := array_append(t,'state during test call'); e := array_append(e,'half_open'); g := array_append(g,s);
    s := provider_record('zz_test', false, 'still down'); t := array_append(t,'test call fails: reopen at once'); e := array_append(e,'open'); g := array_append(g,s);
    update provider_health set opened_at = now() - interval '2 hours' where provider='zz_test';
    perform provider_check('zz_test');
    s := provider_record('zz_test', true); t := array_append(t,'test call succeeds: close'); e := array_append(e,'closed'); g := array_append(g,s);

    t := array_append(t,'role address'); e := array_append(e,'role address (risky)'); g := array_append(g,email_risk('sales@acme.com', false));
    t := array_append(t,'catch-all domain'); e := array_append(e,'catch-all (risky)'); g := array_append(g,email_risk('jane.doe@acme.com', true));
    t := array_append(t,'gmail'); e := array_append(e,'personal (not a work email)'); g := array_append(g,email_risk('jane@gmail.com'));
    t := array_append(t,'verified person'); e := array_append(e,'ok'); g := array_append(g,email_risk('jane.doe@acme.com', false));
    t := array_append(t,'broken email'); e := array_append(e,'invalid'); g := array_append(g,email_risk('jane@@acme'));

    insert into dead_letter(node, error, payload, provider) values ('Find domain (Clearbit)','timeout',
      '{"company_key":"zz-test-co","company_name":"ZZ Test Co","company_slug":"zz-test-co"}', 'clearbit') returning id into dl;
    select count(*)::text into s from dead_letter_replay_queue where id = dl; t := array_append(t,'new failure appears in replay queue'); e := array_append(e,'1'); g := array_append(g,s);
    s := replay_result(dl, false, 'timeout again'); t := array_append(t,'replay fails: retry later'); e := array_append(e,'retrying'); g := array_append(g,s);
    select count(*)::text into s from dead_letter_replay_queue where id = dl; t := array_append(t,'waits for its backoff time'); e := array_append(e,'0'); g := array_append(g,s);
    update dead_letter set next_retry_at = now() where id = dl;
    s := replay_result(dl, true, null, '{"company_key":"zz-test-co","company_name":"ZZ Test Co","domain":"zztestco-example.com","domain_confidence":"high"}');
    t := array_append(t,'replay succeeds: resolved'); e := array_append(e,'resolved'); g := array_append(g,s);
    select count(*)::text into s from icp_companies where company_key='zz-test-co'; t := array_append(t,'recovered company saved'); e := array_append(e,'1'); g := array_append(g,s);

    insert into dead_letter(node, error, payload, provider) values ('x','x','{}','clearbit') returning id into dl;
    for i in 1..5 loop s := replay_result(dl, false, 'down'); update dead_letter set next_retry_at = now() where id = dl; end loop;
    t := array_append(t,'5 failed replays: give up'); e := array_append(e,'gave_up'); g := array_append(g,s);

    insert into dead_letter(node, error, payload, provider) values ('x','x','{}','clearbit') returning id into dl;
    s := replay_result(dl, true, null, jsonb_build_object('company_key','zz-dupe','company_name','Motive','domain',
         (select domain from icp_companies where domain is not null limit 1),'domain_confidence','high'));
    t := array_append(t,'duplicate domain: data error, no retry'); e := array_append(e,'not_replayable'); g := array_append(g,s);

    raise exception 'rollback_test';
  exception when others then
    if sqlerrm <> 'rollback_test' then t := array_append(t,'ERROR'); e := array_append(e,''); g := array_append(g,sqlerrm); end if;
  end;
  return query select t[k], e[k], g[k], e[k] = g[k] from generate_subscripts(t,1) k;
end $$;

-- ============================================================
-- 20261007154702  p2_benchmark_and_enrichment_results
-- ============================================================
-- The SAME 200 accounts are used for the Apollo-only baseline and later for the waterfall,
-- so before/after numbers compare like with like.
create table if not exists p2_benchmark_accounts (
  company_key text primary key references icp_companies(company_key),
  company_name text not null,
  domain text not null,
  picked_at timestamptz not null default now());
alter table p2_benchmark_accounts enable row level security;

insert into p2_benchmark_accounts(company_key, company_name, domain)
select company_key, company_name, domain from icp_companies
where domain is not null and domain_confidence = 'high'
order by icp_score desc nulls last, company_key
limit 200
on conflict do nothing;

-- One row per (account, provider, run): what each source returned
create table if not exists enrichment_results (
  id bigserial primary key,
  run_label text not null,             -- e.g. 'apollo_baseline', 'waterfall_v1'
  company_key text not null,
  provider text not null,              -- cache | website | hunter | apollo | pattern
  matched boolean not null,
  employee_count int,
  industry text,
  linkedin_url text,
  phone text,
  hq_country text,
  founded_year int,
  contact_name text,
  contact_title text,
  contact_email text,
  email_risk text,
  credits_used numeric not null default 0,
  raw jsonb,
  error text,
  created_at timestamptz not null default now(),
  unique (run_label, company_key, provider));
alter table enrichment_results enable row level security;

-- Coverage per run: what share of the 200 got each field
create or replace view enrichment_coverage with (security_invoker = true) as
  with per_account as (
    select r.run_label, b.company_key,
      bool_or(r.matched) matched,
      bool_or(r.employee_count is not null) has_size,
      bool_or(r.industry is not null) has_industry,
      bool_or(r.linkedin_url is not null) has_linkedin,
      bool_or(r.phone is not null) has_phone,
      bool_or(r.contact_email is not null) has_email,
      sum(r.credits_used) credits
    from p2_benchmark_accounts b
    join enrichment_results r on r.company_key = b.company_key
    group by r.run_label, b.company_key)
  select run_label,
    count(*) accounts_attempted,
    round(avg(matched::int), 3) match_rate,
    round(avg(has_size::int), 3) size_coverage,
    round(avg(has_industry::int), 3) industry_coverage,
    round(avg(has_linkedin::int), 3) linkedin_coverage,
    round(avg(has_phone::int), 3) phone_coverage,
    round(avg(has_email::int), 3) email_coverage,
    round(avg((has_size and has_industry and has_linkedin)::int), 3) core_coverage,
    sum(credits) credits_used,
    round(sum(credits) / nullif(sum((has_size and has_industry and has_linkedin)::int), 0), 2) credits_per_covered_account
  from per_account group by run_label;

-- ============================================================
-- 20261007154946  p2_waterfall_support
-- ============================================================
create or replace view dead_letter_replay_queue with (security_invoker = true) as
  select id, node, provider, payload, attempts, max_attempts, created_at, last_replay_error
  from dead_letter
  where status in ('new','retrying') and next_retry_at <= now()
    and provider in ('clearbit','supabase')
  order by created_at;

create or replace function enrichment_results_set_email_risk() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.contact_email is not null and new.email_risk is null then
    new.email_risk := email_risk(new.contact_email, null);
  end if;
  return new;
end $$;
create trigger trg_enrichment_email_risk before insert or update on enrichment_results
  for each row execute function enrichment_results_set_email_risk();

create or replace function waterfall_cache(p_company_key text) returns jsonb
language sql stable set search_path = public as $$
  with r as (select * from enrichment_results where company_key = p_company_key and matched),
  ttl as (select field, make_interval(days => ttl_days) iv from field_ttl)
  select jsonb_strip_nulls(jsonb_build_object(
    'employee_count', (select employee_count from r where employee_count is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'industry',       (select industry from r where industry is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'linkedin_url',   (select linkedin_url from r where linkedin_url is not null
                        and created_at > now() - (select iv from ttl where field='domain') order by created_at desc limit 1),
    'phone',          (select phone from r where phone is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'contact_email',  (select contact_email from r where contact_email is not null
                        and created_at > now() - (select iv from ttl where field='email_address') order by created_at desc limit 1),
    'contact_name',   (select contact_name from r where contact_email is not null
                        and created_at > now() - (select iv from ttl where field='email_address') order by created_at desc limit 1)
  ))
$$;

create or replace view waterfall_queue with (security_invoker = true) as
  select b.company_key, b.company_name, b.domain from p2_benchmark_accounts b order by b.company_key;

-- ============================================================
-- 20261007155057  p2_provider_budget
-- ============================================================
alter table provider_health add column if not exists monthly_budget int;        -- null = no cap
alter table provider_health add column if not exists used_this_month int not null default 0;
alter table provider_health add column if not exists budget_month date not null default date_trunc('month', now())::date;

update provider_health set monthly_budget = 25 where provider = 'hunter' and monthly_budget is null;

-- provider_check now also says 'skip' when the month's budget is used up
create or replace function provider_check(p text) returns text
language plpgsql set search_path = public as $$
declare h provider_health;
begin
  insert into provider_health(provider) values (p) on conflict do nothing;
  select * into h from provider_health where provider = p for update;
  if h.budget_month < date_trunc('month', now())::date then      -- new month: reset the budget
    update provider_health set used_this_month = 0, budget_month = date_trunc('month', now())::date where provider = p;
    h.used_this_month := 0;
  end if;
  if h.monthly_budget is not null and h.used_this_month >= h.monthly_budget then
    update provider_health set total_skipped = total_skipped + 1 where provider = p;
    return 'skip';
  end if;
  if h.state = 'open' then
    if now() < h.opened_at + make_interval(secs => h.cooldown_seconds) then
      update provider_health set total_skipped = total_skipped + 1 where provider = p;
      return 'skip';
    end if;
    update provider_health set state = 'half_open' where provider = p;
  end if;
  return 'try';
end $$;

-- Record the call; 'used' counts toward the monthly budget (every real call, success or not)
create or replace function provider_record(p text, ok boolean, err text default null, used int default 1) returns text
language plpgsql set search_path = public as $$
declare h provider_health;
begin
  insert into provider_health(provider) values (p) on conflict do nothing;
  select * into h from provider_health where provider = p for update;
  update provider_health set used_this_month = used_this_month + coalesce(used, 0) where provider = p;
  if ok then
    update provider_health set state='closed', consecutive_failures=0, opened_at=null,
      last_success_at=now(), total_calls=total_calls+1 where provider = p;
    return 'closed';
  end if;
  if h.state = 'half_open' or h.consecutive_failures + 1 >= h.failure_threshold then
    update provider_health set state='open', opened_at=now(), consecutive_failures=consecutive_failures+1,
      last_error=left(err,500), last_failure_at=now(), total_calls=total_calls+1, total_failures=total_failures+1 where provider = p;
    return 'open';
  end if;
  update provider_health set consecutive_failures=consecutive_failures+1, last_error=left(err,500),
    last_failure_at=now(), total_calls=total_calls+1, total_failures=total_failures+1 where provider = p;
  return 'closed';
end $$;

-- ============================================================
-- 20261007155123  p2_provider_record_fix_overload
-- ============================================================
alter function provider_record(text, boolean, text, integer) rename to provider_record_n;

-- The normal 3-argument version: one call = 1 unit of budget
create or replace function provider_record(p text, ok boolean, err text default null) returns text
language sql set search_path = public as $$ select provider_record_n(p, ok, err, 1) $$;

-- ============================================================
-- 20261007160224  p2_benchmark_ranked
-- ============================================================
-- Fixed order (best ICP score first), so "first 70" always means the same 70 companies
create or replace view p2_benchmark_ranked with (security_invoker = true) as
  select row_number() over (order by i.icp_score desc nulls last, b.company_key) as rank,
         b.company_key, b.company_name, b.domain
  from p2_benchmark_accounts b join icp_companies i using (company_key)
  order by 1;

create or replace view waterfall_queue with (security_invoker = true) as
  select company_key, company_name, domain from p2_benchmark_ranked order by rank;

-- ============================================================
-- 20261007162603  p2_waterfall_fair_comparison
-- ============================================================
-- Cache must not "see" the Apollo baseline or test rows, or the comparison would be unfair
create or replace function waterfall_cache(p_company_key text) returns jsonb
language sql stable set search_path = public as $$
  with r as (select * from enrichment_results where company_key = p_company_key and matched
             and run_label not in ('apollo_baseline','scaffold_test','waterfall_v1')),
  ttl as (select field, make_interval(days => ttl_days) iv from field_ttl)
  select jsonb_strip_nulls(jsonb_build_object(
    'employee_count', (select employee_count from r where employee_count is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'industry',       (select industry from r where industry is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'linkedin_url',   (select linkedin_url from r where linkedin_url is not null
                        and created_at > now() - (select iv from ttl where field='domain') order by created_at desc limit 1),
    'phone',          (select phone from r where phone is not null
                        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'contact_email',  (select contact_email from r where contact_email is not null
                        and created_at > now() - (select iv from ttl where field='email_address') order by created_at desc limit 1),
    'contact_name',   (select contact_name from r where contact_email is not null
                        and created_at > now() - (select iv from ttl where field='email_address') order by created_at desc limit 1)
  ))
$$;

-- Replays what Apollo answered in the baseline, in Apollo's own response shape (no credits spent again)
create or replace function apollo_replay(p_company_key text) returns jsonb
language sql stable set search_path = public as $$
  select coalesce((
    select jsonb_build_object('replayed', true, 'organization', jsonb_build_object(
      'estimated_num_employees', employee_count, 'industry', nullif(industry, ''),
      'linkedin_url', linkedin_url, 'phone', phone, 'name', raw->>'name'))
    from enrichment_results where run_label = 'apollo_baseline' and company_key = p_company_key and matched
  ), jsonb_build_object('replayed', true))
$$;

-- ============================================================
-- 20261007165044  p2_email_risk_tighten
-- ============================================================
insert into role_address_prefixes values
 ('privacy'),('pr'),('order'),('orders'),('service'),('services'),('techsupport'),('request'),('requests'),('legal'),
 ('media'),('hellopress'),('news'),('newsletter'),('events'),('donations'),('majorgifts'),('giving'),('feedback'),
 ('security'),('abuse'),('webmaster'),('privacypolicyupdates'),('compliance'),('finance'),('invoices'),('recruiting'),
 ('talent'),('win'),('assessoriaimprensa'),('imprensa'),('ola'),('kontakt'),('bonjour')
on conflict do nothing;

create or replace function email_risk(email text, domain_is_catch_all boolean default null) returns text
language sql stable set search_path = public as $$
  select case
    when email is null or email !~* '^[a-z0-9._%+''-]+@[a-z0-9.-]+\.[a-z]{2,}$' then 'invalid'
    -- scraping leftovers: url-encoded characters, escaped HTML, or random codes
    when split_part(email,'@',1) ~* '(%[0-9a-f]{2}|^u00[0-9a-f]{2})' or split_part(email,'@',1) ~* '^[0-9a-f]{16,}$' then 'invalid'
    when domain_root(email) in (select domain from free_email_domains) then 'personal (not a work email)'
    when lower(split_part(email,'@',1)) in (select prefix from role_address_prefixes) then 'role address (risky)'
    when domain_is_catch_all then 'catch-all (risky)'
    when domain_is_catch_all is null then 'unverified'
    else 'ok' end
$$;

-- ============================================================
-- 20261007165130  p2_coverage_person_email
-- ============================================================
create or replace view enrichment_coverage with (security_invoker = true) as
  with per_account as (
    select r.run_label, b.company_key,
      bool_or(r.matched) matched,
      bool_or(r.employee_count is not null) has_size,
      bool_or(r.industry is not null) has_industry,
      bool_or(r.linkedin_url is not null) has_linkedin,
      bool_or(r.phone is not null) has_phone,
      bool_or(r.contact_email is not null) has_email,
      sum(r.credits_used) credits,
      bool_or(r.email_risk in ('ok','unverified')) has_person_email
    from p2_benchmark_accounts b
    join enrichment_results r on r.company_key = b.company_key
    group by r.run_label, b.company_key)
  select run_label,
    count(*) accounts_attempted,
    round(avg(matched::int), 3) match_rate,
    round(avg(has_size::int), 3) size_coverage,
    round(avg(has_industry::int), 3) industry_coverage,
    round(avg(has_linkedin::int), 3) linkedin_coverage,
    round(avg(has_phone::int), 3) phone_coverage,
    round(avg(has_email::int), 3) email_coverage,
    round(avg((has_size and has_industry and has_linkedin)::int), 3) core_coverage,
    sum(credits) credits_used,
    round(sum(credits) / nullif(sum((has_size and has_industry and has_linkedin)::int), 0), 2) credits_per_covered_account,
    round(avg(has_person_email::int), 3) person_email_coverage
  from per_account group by run_label;

-- ============================================================
-- 20261008190916  p2_golden_record
-- ============================================================
-- ========== NORMALIZE: industry -> Salesforce standard Industry picklist ==========
create table if not exists industry_map (priority int primary key, pattern text not null, sf_industry text not null);
alter table industry_map enable row level security;
insert into industry_map values
 (10,'bank','Banking'),
 (20,'software|information technology|internet|computer|saas|data','Technology'),
 (30,'management consult|consult','Consulting'),
 (40,'financ|fintech|insurance|invest','Finance'),
 (50,'educat|e-learning|school|training','Education'),
 (60,'pharma|biotech','Biotechnology'),
 (70,'research|hospital|health|medical','Healthcare'),
 (80,'semiconductor|electronic','Electronics'),
 (90,'nonprofit|non-profit|philanthrop','Not For Profit'),
 (100,'telecom','Telecommunications'),
 (110,'marketing|advertis|media|publishing','Media'),
 (120,'engineering|industrial|mechanical','Engineering'),
 (130,'environmental','Environmental'),
 (140,'retail|consumer','Retail'),
 (150,'logistic|transport|shipping','Transportation'),
 (160,'staffing|recruit|human resources','Other')
on conflict do nothing;

create or replace function normalize_industry(raw text) returns text
language sql stable set search_path = public as $$
  select case when nullif(btrim(raw),'') is null then null else
    coalesce((select sf_industry from industry_map where raw ~* pattern order by priority limit 1), 'Other') end
$$;

create or replace function employee_band(n int) returns text language sql immutable as $$
  select case when n is null then null when n <= 10 then '1-10' when n <= 50 then '11-50' when n <= 200 then '51-200'
    when n <= 500 then '201-500' when n <= 1000 then '501-1000' when n <= 5000 then '1001-5000' else '5000+' end
$$;

create or replace function normalize_linkedin(u text) returns text language sql immutable as $$
  select case when u ~* 'linkedin\.com/company/([^/?#]+)'
    then 'https://www.linkedin.com/company/' || lower(substring(u from '(?i)linkedin\.com/company/([^/?#]+)')) end
$$;

create or replace function normalize_phone(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '[^0-9+]', '', 'g'), '')
$$;

-- ========== GOLDEN RECORD: one row per company = the truth ==========
create table if not exists account_enrichment (
  company_key text primary key references icp_companies(company_key),
  company_name text, domain text,
  employee_count int, employee_band text, industry_raw text, industry_sf text,
  linkedin_url text, phone text, contact_email text, email_risk text,
  field_sources jsonb not null default '{}',     -- which provider supplied each field
  field_updated_at jsonb not null default '{}',  -- when each field was found
  identity_check text,      -- confirmed | needs_review | unknown
  identity_note text,
  confidence int,           -- 0-100
  status text,              -- enriched | partial | unenriched
  unenriched_reason text,
  last_run_label text,
  enriched_at timestamptz,
  sf_last_synced jsonb not null default '{}',    -- values WE last wrote to Salesforce, per field
  sf_synced_at timestamptz);
alter table account_enrichment enable row level security;

-- ========== TIER 1 CACHE (with negative caching) ==========
-- Returns fresh known values AND whether a tier was already tried recently with no luck,
-- so we don't pay or scrape again for the same "no".
create or replace function cache_lookup(p_company_key text, p_run_label text) returns jsonb
language sql stable set search_path = public as $$
  with r as (select * from enrichment_results where company_key = p_company_key
             and run_label not in ('scaffold_test', p_run_label)),
  ttl as (select field, make_interval(days => ttl_days) iv from field_ttl)
  select jsonb_strip_nulls(jsonb_build_object(
    'employee_count', (select employee_count from r where matched and employee_count is not null
        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'industry', (select nullif(industry,'') from r where matched and nullif(industry,'') is not null
        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'linkedin_url', (select linkedin_url from r where matched and linkedin_url is not null
        and created_at > now() - (select iv from ttl where field='domain') order by created_at desc limit 1),
    'phone', (select phone from r where matched and phone is not null
        and created_at > now() - (select iv from ttl where field='company_size') order by created_at desc limit 1),
    'contact_email', (select contact_email from r where contact_email is not null and coalesce(email_risk,'') <> 'invalid'
        and created_at > now() - (select iv from ttl where field='email_address') order by created_at desc limit 1),
    -- negative cache: the tier already ran recently, so don't run it again yet
    'website_checked', (select true from r where provider='website' and created_at > now() - interval '30 days' limit 1),
    'apollo_checked',  (select true from r where provider='apollo' and error is distinct from 'Apollo not connected yet (node switched off)'
        and created_at > now() - (select iv from ttl where field='company_size') limit 1)
  ))
$$;

-- ========== WHAT TO ENRICH: never-enriched, retry-able, or stale ==========
create or replace view accounts_to_enrich with (security_invoker = true) as
  select c.company_key, c.company_name, c.domain
  from icp_companies c
  left join account_enrichment g using (company_key)
  where c.domain is not null and c.domain_confidence = 'high'
    and ( g.company_key is null
          or (g.status <> 'enriched' and g.enriched_at < now() - interval '7 days')
          or g.enriched_at < now() - interval '90 days')
  order by c.icp_score desc nulls last, c.company_key;

-- ============================================================
-- 20261008190945  p2_finalize_account
-- ============================================================
create or replace function finalize_account(p_run_label text, p_company_key text) returns jsonb
language plpgsql set search_path = public as $$
declare
  c icp_companies; ev record;
  v_size int; v_ind text; v_li text; v_phone text; v_email text; v_risk text;
  src jsonb := '{}'; upd jsonb := '{}';
  apollo_name text; nv text; li_slug text; name_c text;
  ident text := 'unknown'; note text := null; conf int := 0;
  st text; reason text; web_ok boolean;
begin
  select * into c from icp_companies where company_key = p_company_key;
  if c.company_key is null then return jsonb_build_object('error','unknown company'); end if;

  -- 1. MERGE: for each field, the most recent value any source found (all runs = cache + this run)
  select employee_count, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and employee_count is not null
    order by created_at desc limit 1;
  if found then v_size := ev.employee_count; src := src || jsonb_build_object('employee_count', ev.provider); upd := upd || jsonb_build_object('employee_count', ev.created_at); end if;

  select nullif(industry,'') ind, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and nullif(industry,'') is not null
    order by created_at desc limit 1;
  if found then v_ind := ev.ind; src := src || jsonb_build_object('industry', ev.provider); upd := upd || jsonb_build_object('industry', ev.created_at); end if;

  select linkedin_url, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and linkedin_url is not null
    order by created_at desc limit 1;
  if found then v_li := ev.linkedin_url; src := src || jsonb_build_object('linkedin_url', ev.provider); upd := upd || jsonb_build_object('linkedin_url', ev.created_at); end if;

  select phone, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and phone is not null
    order by created_at desc limit 1;
  if found then v_phone := ev.phone; src := src || jsonb_build_object('phone', ev.provider); upd := upd || jsonb_build_object('phone', ev.created_at); end if;

  -- best email: a person beats a shared inbox; junk is never used
  select contact_email, email_risk, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and contact_email is not null and coalesce(email_risk,'') <> 'invalid'
    order by case email_risk when 'ok' then 1 when 'unverified' then 2 when 'catch-all (risky)' then 3 else 4 end, created_at desc limit 1;
  if found then v_email := ev.contact_email; v_risk := ev.email_risk; src := src || jsonb_build_object('contact_email', ev.provider); upd := upd || jsonb_build_object('contact_email', ev.created_at); end if;

  -- 2. RESOLVE IDENTITY: is this data really about OUR company?
  select raw->>'name' into apollo_name from enrichment_results
    where company_key = p_company_key and provider = 'apollo' and matched and raw->>'name' is not null
    order by created_at desc limit 1;
  name_c := replace(coalesce(normalize_company_name(c.company_name),''), ' ', '');
  li_slug := regexp_replace(lower(coalesce(substring(v_li from '(?i)linkedin\.com/company/([^/?#]+)'),'')), '[^a-z0-9]', '', 'g');
  if apollo_name is not null then
    nv := name_verdict(normalize_company_name(c.company_name), normalize_company_name(apollo_name));
    if nv = 'same' then ident := 'confirmed';
    else ident := 'needs_review'; note := 'Apollo says "' || apollo_name || '" (' || nv || ' to our name)'; end if;
  elsif li_slug <> '' and name_c <> '' and (li_slug like '%' || name_c || '%' or name_c like '%' || li_slug || '%') then
    ident := 'confirmed'; note := 'LinkedIn page name matches';
  end if;

  -- 3. CONFIDENCE (0-100), every point explainable
  select bool_or(error is null) into web_ok from enrichment_results
    where company_key = p_company_key and provider = 'website' and run_label <> 'scaffold_test';
  conf := (case when c.domain_confidence = 'high' then 20 else 0 end)
        + (case ident when 'confirmed' then 30 when 'needs_review' then 5 else 0 end)
        + (case when li_slug <> '' and name_c <> '' and (li_slug like '%' || name_c || '%' or name_c like '%' || li_slug || '%') then 20 else 0 end)
        + (case when coalesce(web_ok,false) then 10 else 0 end)
        + (case when v_size is not null and v_ind is not null and v_li is not null then 20 else 0 end);
  conf := least(conf, 100);

  -- 4. STATUS + why
  if v_size is not null and v_ind is not null and v_li is not null then st := 'enriched';
  elsif coalesce(v_size::text, v_ind, v_li, v_phone, v_email) is not null then st := 'partial';
  else st := 'unenriched'; end if;
  if st <> 'enriched' then
    select string_agg(distinct provider || ': ' || coalesce(error, case when matched then 'found some fields' else 'no data' end), '; ')
      into reason from enrichment_results where company_key = p_company_key and run_label = p_run_label;
    reason := coalesce(reason, 'no tier returned data');
  end if;

  -- 5. NORMALIZE + SAVE the golden record (Supabase = truth)
  insert into account_enrichment as g (company_key, company_name, domain, employee_count, employee_band, industry_raw, industry_sf,
     linkedin_url, phone, contact_email, email_risk, field_sources, field_updated_at, identity_check, identity_note,
     confidence, status, unenriched_reason, last_run_label, enriched_at)
  values (c.company_key, c.company_name, c.domain, v_size, employee_band(v_size), v_ind, normalize_industry(v_ind),
     normalize_linkedin(v_li), normalize_phone(v_phone), lower(v_email), v_risk, src, upd, ident, note,
     conf, st, reason, p_run_label, now())
  on conflict (company_key) do update set company_name=excluded.company_name, domain=excluded.domain,
     employee_count=excluded.employee_count, employee_band=excluded.employee_band, industry_raw=excluded.industry_raw,
     industry_sf=excluded.industry_sf, linkedin_url=excluded.linkedin_url, phone=excluded.phone,
     contact_email=excluded.contact_email, email_risk=excluded.email_risk, field_sources=excluded.field_sources,
     field_updated_at=excluded.field_updated_at, identity_check=excluded.identity_check, identity_note=excluded.identity_note,
     confidence=excluded.confidence, status=excluded.status, unenriched_reason=excluded.unenriched_reason,
     last_run_label=excluded.last_run_label, enriched_at=excluded.enriched_at;

  return jsonb_build_object('company_key', p_company_key, 'status', st, 'confidence', conf, 'identity', ident);
end $$;

-- ============================================================
-- 20261008191002  p2_preview_fn
-- ============================================================
-- Dry run: shows what finalize_account WOULD write, then rolls back
create or replace function preview_finalize(keys text[]) returns jsonb
language plpgsql set search_path = public as $$
declare out jsonb;
begin
  begin
    perform finalize_account('preview', k) from unnest(keys) k;
    select jsonb_agg(to_jsonb(g) - 'sf_last_synced' - 'field_updated_at' - 'company_name' - 'domain' - 'last_run_label' - 'enriched_at' - 'sf_synced_at')
      into out from account_enrichment g where company_key = any(keys);
    raise exception 'rollback_preview';
  exception when others then
    if sqlerrm <> 'rollback_preview' then raise; end if;
  end;
  return out;
end $$;

-- ============================================================
-- 20261008191046  p2_finalize_account_v2
-- ============================================================
create or replace function finalize_account(p_run_label text, p_company_key text) returns jsonb
language plpgsql set search_path = public as $$
declare
  c icp_companies; ev record;
  v_size int; v_ind text; v_li text; v_phone text; v_email text; v_risk text;
  src jsonb := '{}'; upd jsonb := '{}';
  apollo_name text; nv text; li_slug text; name_c text;
  ident text := 'unknown'; note text := null; conf int := 0;
  st text; reason text; web_ok boolean;
begin
  select * into c from icp_companies where company_key = p_company_key;
  if c.company_key is null then return jsonb_build_object('error','unknown company'); end if;

  select employee_count, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and employee_count is not null
    order by created_at desc limit 1;
  if found then v_size := ev.employee_count; src := src || jsonb_build_object('employee_count', ev.provider); upd := upd || jsonb_build_object('employee_count', ev.created_at); end if;

  select nullif(industry,'') ind, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and nullif(industry,'') is not null
    order by created_at desc limit 1;
  if found then v_ind := ev.ind; src := src || jsonb_build_object('industry', ev.provider); upd := upd || jsonb_build_object('industry', ev.created_at); end if;

  select linkedin_url, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and linkedin_url is not null
    order by created_at desc limit 1;
  if found then v_li := ev.linkedin_url; src := src || jsonb_build_object('linkedin_url', ev.provider); upd := upd || jsonb_build_object('linkedin_url', ev.created_at); end if;

  select phone, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and matched and phone is not null
    order by created_at desc limit 1;
  if found then v_phone := ev.phone; src := src || jsonb_build_object('phone', ev.provider); upd := upd || jsonb_build_object('phone', ev.created_at); end if;

  select contact_email, email_risk, provider, created_at into ev from enrichment_results
    where company_key = p_company_key and run_label <> 'scaffold_test' and contact_email is not null and coalesce(email_risk,'') <> 'invalid'
    order by case email_risk when 'ok' then 1 when 'unverified' then 2 when 'catch-all (risky)' then 3 else 4 end, created_at desc limit 1;
  if found then v_email := ev.contact_email; v_risk := ev.email_risk; src := src || jsonb_build_object('contact_email', ev.provider); upd := upd || jsonb_build_object('contact_email', ev.created_at); end if;

  select raw->>'name' into apollo_name from enrichment_results
    where company_key = p_company_key and provider = 'apollo' and matched and raw->>'name' is not null
    order by created_at desc limit 1;
  name_c := replace(coalesce(normalize_company_name(c.company_name),''), ' ', '');
  li_slug := regexp_replace(lower(coalesce(substring(v_li from '(?i)linkedin\.com/company/([^/?#]+)'),'')), '[^a-z0-9]', '', 'g');
  if apollo_name is not null then
    nv := name_verdict(normalize_company_name(c.company_name), normalize_company_name(apollo_name));
    if nv = 'same' then ident := 'confirmed';
    else ident := 'needs_review'; note := 'Apollo says "' || apollo_name || '" (' || nv || ' to our name)'; end if;
  elsif li_slug <> '' and name_c <> '' and (li_slug like '%' || name_c || '%' or name_c like '%' || li_slug || '%') then
    ident := 'confirmed'; note := 'LinkedIn page name matches';
  end if;

  select bool_or(error is null) into web_ok from enrichment_results
    where company_key = p_company_key and provider = 'website' and run_label <> 'scaffold_test';
  conf := (case when c.domain_confidence = 'high' then 20 else 0 end)
        + (case ident when 'confirmed' then 30 when 'needs_review' then 5 else 0 end)
        + (case when li_slug <> '' and name_c <> '' and (li_slug like '%' || name_c || '%' or name_c like '%' || li_slug || '%') then 20 else 0 end)
        + (case when coalesce(web_ok,false) then 10 else 0 end)
        + (case when v_size is not null and v_ind is not null and v_li is not null then 20 else 0 end);
  conf := least(conf, 100);
  if ident = 'needs_review' then conf := least(conf, 50); end if;   -- doubtful identity can never look trustworthy

  if v_size is not null and v_ind is not null and v_li is not null then st := 'enriched';
  elsif coalesce(v_size::text, v_ind, v_li, v_phone, v_email) is not null then st := 'partial';
  else st := 'unenriched'; end if;
  if st <> 'enriched' then
    select string_agg(distinct provider || ': ' || coalesce(error, case when matched then 'found some fields' else 'no data' end), '; ')
      into reason from enrichment_results where company_key = p_company_key and run_label = p_run_label;
    reason := coalesce(reason, 'no tier returned data');
  end if;

  insert into account_enrichment as g (company_key, company_name, domain, employee_count, employee_band, industry_raw, industry_sf,
     linkedin_url, phone, contact_email, email_risk, field_sources, field_updated_at, identity_check, identity_note,
     confidence, status, unenriched_reason, last_run_label, enriched_at)
  values (c.company_key, c.company_name, c.domain, v_size, employee_band(v_size), v_ind, normalize_industry(v_ind),
     normalize_linkedin(v_li), normalize_phone(v_phone), lower(v_email), v_risk, src, upd, ident, note,
     conf, st, reason, p_run_label, now())
  on conflict (company_key) do update set company_name=excluded.company_name, domain=excluded.domain,
     employee_count=excluded.employee_count, employee_band=excluded.employee_band, industry_raw=excluded.industry_raw,
     industry_sf=excluded.industry_sf, linkedin_url=excluded.linkedin_url, phone=excluded.phone,
     contact_email=excluded.contact_email, email_risk=excluded.email_risk, field_sources=excluded.field_sources,
     field_updated_at=excluded.field_updated_at, identity_check=excluded.identity_check, identity_note=excluded.identity_note,
     confidence=excluded.confidence, status=excluded.status, unenriched_reason=excluded.unenriched_reason,
     last_run_label=excluded.last_run_label, enriched_at=excluded.enriched_at;

  return jsonb_build_object('company_key', p_company_key, 'status', st, 'confidence', conf, 'identity', ident);
end $$;

-- ============================================================
-- 20261008191141  p2_sf_sync_and_dq
-- ============================================================
create table if not exists sf_sync_log (
  id bigserial primary key, run_label text not null, company_key text, sf_id text, field text,
  sf_value text, our_value text, last_synced_value text,
  decision text not null,   -- update | human_value_kept | held_for_review | unchanged
  ok boolean, error text, created_at timestamptz not null default now());
alter table sf_sync_log enable row level security;

/* CONFLICT RULE (written down):
   1. Human-edited Salesforce fields WIN. A field counts as human-edited if its current Salesforce value
      is different from the value this pipeline last wrote there (or it had a value we never wrote).
      We never overwrite it; we log it as 'human_value_kept'.
   2. Machine vs machine: if Salesforce still holds OUR last value (or is empty), the more recent data wins:
      we update only when our value is newer than our last sync.
   3. Quality gate: accounts whose identity is doubtful ('needs_review') or confidence < 60 are not synced at all.
*/
create or replace function sf_sync_plan(p_run_label text, p_current jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare
  rec jsonb; g account_enrichment; sfid text; f text; ours text; cur text; last text; ts timestamptz;
  changes jsonb; records jsonb := '[]'; n_upd int := 0; n_human int := 0; n_held int := 0;
begin
  for rec in select * from jsonb_array_elements(p_current) loop
    sfid := rec->>'Id';
    select g2.* into g from account_enrichment g2 join icp_companies c using (company_key) where c.sf_account_id = sfid;
    if g.company_key is null then continue; end if;

    if g.identity_check = 'needs_review' or coalesce(g.confidence,0) < 60 then
      insert into sf_sync_log(run_label, company_key, sf_id, field, decision, our_value)
        values (p_run_label, g.company_key, sfid, '*', 'held_for_review', g.identity_note);
      n_held := n_held + 1; continue;
    end if;

    changes := '{}';
    foreach f in array array['NumberOfEmployees','Industry','Phone','Website'] loop
      ours := case f when 'NumberOfEmployees' then g.employee_count::text when 'Industry' then g.industry_sf
                     when 'Phone' then g.phone when 'Website' then 'https://' || g.domain end;
      cur  := nullif(rec->>f, '');
      last := g.sf_last_synced->>f;
      ts   := coalesce((g.field_updated_at->>(case f when 'NumberOfEmployees' then 'employee_count' when 'Industry' then 'industry'
                        when 'Phone' then 'phone' else 'x' end))::timestamptz, g.enriched_at);
      if ours is null then continue; end if;

      if (last is not null and cur is distinct from last) or (last is null and cur is not null and cur is distinct from ours) then
        insert into sf_sync_log(run_label, company_key, sf_id, field, sf_value, our_value, last_synced_value, decision)
          values (p_run_label, g.company_key, sfid, f, cur, ours, last, 'human_value_kept');
        n_human := n_human + 1;
      elsif cur is not distinct from ours then
        null;  -- already correct
      elsif g.sf_synced_at is null or ts > g.sf_synced_at then
        changes := changes || jsonb_build_object(f, case when f = 'NumberOfEmployees' then to_jsonb(ours::int) else to_jsonb(ours) end);
        insert into sf_sync_log(run_label, company_key, sf_id, field, sf_value, our_value, last_synced_value, decision)
          values (p_run_label, g.company_key, sfid, f, cur, ours, last, 'update');
      end if;
    end loop;

    if changes <> '{}' then
      records := records || jsonb_build_array(jsonb_build_object('attributes', jsonb_build_object('type','Account'), 'Id', sfid)
                 || changes || jsonb_build_object('Data_Last_Verified__c', current_date));
      n_upd := n_upd + 1;
    end if;
  end loop;
  return jsonb_build_object('records', records, 'accounts_to_update', n_upd, 'human_values_kept', n_human, 'held_for_review', n_held);
end $$;

-- After Salesforce answers: remember what we wrote (so we can recognise human edits next time)
create or replace function sf_sync_record(p_run_label text, p_records jsonb, p_results jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare i int; rec jsonb; res jsonb; ok_n int := 0; fail_n int := 0; written jsonb;
begin
  for i in 0 .. coalesce(jsonb_array_length(p_records),0) - 1 loop
    rec := p_records->i; res := p_results->i;
    if coalesce((res->>'success')::boolean, false) then
      select jsonb_object_agg(key, value #>> '{}') into written
        from jsonb_each(rec - 'attributes' - 'Id' - 'Data_Last_Verified__c');
      update account_enrichment g set sf_last_synced = g.sf_last_synced || written, sf_synced_at = now()
        from icp_companies c where c.company_key = g.company_key and c.sf_account_id = rec->>'Id';
      update sf_sync_log set ok = true where run_label = p_run_label and sf_id = rec->>'Id' and decision = 'update' and ok is null;
      ok_n := ok_n + 1;
    else
      update sf_sync_log set ok = false, error = left(coalesce(res->>'errors', 'no response'), 500)
        where run_label = p_run_label and sf_id = rec->>'Id' and decision = 'update' and ok is null;
      fail_n := fail_n + 1;
    end if;
  end loop;
  return jsonb_build_object('synced', ok_n, 'failed', fail_n);
end $$;

-- ========== DATA QUALITY REPORT: one row per run ==========
create table if not exists data_quality_reports (
  id bigserial primary key, run_label text unique, started_at timestamptz, finished_at timestamptz,
  accounts_processed int, enriched int, partial int, unenriched int, unenriched_reasons jsonb,
  size_coverage numeric, industry_coverage numeric, linkedin_coverage numeric, phone_coverage numeric,
  person_email_coverage numeric, any_email_coverage numeric,
  avg_confidence numeric, identity_confirmed int, identity_needs_review int,
  cache_hits int, tier_calls jsonb, credits_used numeric,
  sf_fields_updated int, sf_human_values_kept int, sf_held_for_review int, sf_failures int,
  created_at timestamptz not null default now());
alter table data_quality_reports enable row level security;

create or replace function write_dq_report(p_run_label text, p_started_at timestamptz) returns jsonb
language plpgsql set search_path = public as $$
declare r data_quality_reports;
begin
  insert into data_quality_reports as d (run_label, started_at, finished_at, accounts_processed, enriched, partial, unenriched,
    unenriched_reasons, size_coverage, industry_coverage, linkedin_coverage, phone_coverage, person_email_coverage, any_email_coverage,
    avg_confidence, identity_confirmed, identity_needs_review, cache_hits, tier_calls, credits_used,
    sf_fields_updated, sf_human_values_kept, sf_held_for_review, sf_failures)
  select p_run_label, p_started_at, now(), count(*),
    count(*) filter (where status='enriched'), count(*) filter (where status='partial'), count(*) filter (where status='unenriched'),
    (select jsonb_object_agg(coalesce(unenriched_reason,'?'), n) from (select unenriched_reason, count(*) n from account_enrichment
       where last_run_label = p_run_label and status = 'unenriched' group by 1) x),
    round(avg((employee_count is not null)::int),3), round(avg((industry_sf is not null)::int),3),
    round(avg((linkedin_url is not null)::int),3), round(avg((phone is not null)::int),3),
    round(avg((email_risk in ('ok','unverified'))::int),3), round(avg((contact_email is not null)::int),3),
    round(avg(confidence),1), count(*) filter (where identity_check='confirmed'), count(*) filter (where identity_check='needs_review'),
    (select count(*) from enrichment_results where run_label = p_run_label and provider='cache' and matched),
    (select jsonb_object_agg(provider, n) from (select provider, count(*) n from enrichment_results
       where run_label = p_run_label and provider <> 'cache' and coalesce(error,'') not like '%not connected%' group by 1) y),
    (select coalesce(sum(credits_used),0) from enrichment_results where run_label = p_run_label and provider <> 'apollo_replay'),
    (select count(*) from sf_sync_log where run_label = p_run_label and decision='update' and ok),
    (select count(*) from sf_sync_log where run_label = p_run_label and decision='human_value_kept'),
    (select count(*) from sf_sync_log where run_label = p_run_label and decision='held_for_review'),
    (select count(*) from sf_sync_log where run_label = p_run_label and decision='update' and ok is false)
  from account_enrichment where last_run_label = p_run_label
  on conflict (run_label) do update set finished_at = excluded.finished_at, accounts_processed = excluded.accounts_processed,
    enriched = excluded.enriched, partial = excluded.partial, unenriched = excluded.unenriched, unenriched_reasons = excluded.unenriched_reasons,
    size_coverage = excluded.size_coverage, industry_coverage = excluded.industry_coverage, linkedin_coverage = excluded.linkedin_coverage,
    phone_coverage = excluded.phone_coverage, person_email_coverage = excluded.person_email_coverage, any_email_coverage = excluded.any_email_coverage,
    avg_confidence = excluded.avg_confidence, identity_confirmed = excluded.identity_confirmed, identity_needs_review = excluded.identity_needs_review,
    cache_hits = excluded.cache_hits, tier_calls = excluded.tier_calls, credits_used = excluded.credits_used,
    sf_fields_updated = excluded.sf_fields_updated, sf_human_values_kept = excluded.sf_human_values_kept,
    sf_held_for_review = excluded.sf_held_for_review, sf_failures = excluded.sf_failures
  returning * into r;
  return to_jsonb(r);
end $$;

-- Accounts that live in Salesforce and have a golden record
create or replace view sf_sync_candidates with (security_invoker = true) as
  select c.sf_account_id, g.company_key from account_enrichment g join icp_companies c using (company_key)
  where c.sf_account_id is not null and c.sf_synced;

-- ============================================================
-- 20261008191212  p2_test_conflict_rule
-- ============================================================
create or replace function test_conflict_rule() returns table(scenario text, expected text, got text, pass boolean)
language plpgsql set search_path = public as $$
declare t text[] := '{}'; e text[] := '{}'; gt text[] := '{}'; plan jsonb; sid text; bid text; rec jsonb; d text;
begin
  begin
    perform finalize_account('ctest', 'canonical');
    perform finalize_account('ctest', 'boardwise');
    select sf_account_id into sid from icp_companies where company_key = 'canonical';
    select sf_account_id into bid from icp_companies where company_key = 'boardwise';

    -- A. First sync, Salesforce fields empty -> machine fills them
    plan := sf_sync_plan('ctA', jsonb_build_array(jsonb_build_object('Id', sid)));
    rec := plan->'records'->0;
    t := array_append(t, 'A: empty SF fields get filled'); e := array_append(e, '1800 / Technology');
    gt := array_append(gt, coalesce(rec->>'NumberOfEmployees','-') || ' / ' || coalesce(rec->>'Industry','-'));

    -- B. A person already typed a phone number we never wrote -> human wins
    plan := sf_sync_plan('ctB', jsonb_build_array(jsonb_build_object('Id', sid, 'Phone', '+44 999 HUMAN')));
    select decision into d from sf_sync_log where run_label='ctB' and field='Phone';
    t := array_append(t, 'B: human-typed phone is kept'); e := array_append(e, 'human_value_kept'); gt := array_append(gt, coalesce(d,'(none)'));
    t := array_append(t, 'B: phone not in update'); e := array_append(e, 'absent');
    gt := array_append(gt, case when plan->'records'->0 ? 'Phone' then 'present' else 'absent' end);

    -- simulate: we synced last week (wrote 1500 employees, Technology)
    update account_enrichment set sf_last_synced = '{"NumberOfEmployees":"1500","Industry":"Technology"}', sf_synced_at = now() - interval '7 days',
      field_updated_at = field_updated_at || jsonb_build_object('employee_count', now()) where company_key='canonical';

    -- C. SF still holds OUR old value, we have newer data -> newer machine data wins
    plan := sf_sync_plan('ctC', jsonb_build_array(jsonb_build_object('Id', sid, 'NumberOfEmployees', 1500, 'Industry', 'Technology')));
    t := array_append(t, 'C: our newer number replaces our older one'); e := array_append(e, '1800');
    gt := array_append(gt, coalesce(plan->'records'->0->>'NumberOfEmployees','(no update)'));

    -- D. A person changed the number we wrote -> human wins
    plan := sf_sync_plan('ctD', jsonb_build_array(jsonb_build_object('Id', sid, 'NumberOfEmployees', 2000, 'Industry', 'Technology')));
    select decision into d from sf_sync_log where run_label='ctD' and field='NumberOfEmployees';
    t := array_append(t, 'D: human-edited number is kept'); e := array_append(e, 'human_value_kept'); gt := array_append(gt, coalesce(d,'(none)'));

    -- E. Our data is OLDER than our last sync -> do not overwrite
    update account_enrichment set field_updated_at = field_updated_at || jsonb_build_object('employee_count', now() - interval '30 days') where company_key='canonical';
    plan := sf_sync_plan('ctE', jsonb_build_array(jsonb_build_object('Id', sid, 'NumberOfEmployees', 1500, 'Industry', 'Technology')));
    t := array_append(t, 'E: older machine data does not overwrite'); e := array_append(e, '(no update)');
    gt := array_append(gt, coalesce(plan->'records'->0->>'NumberOfEmployees','(no update)'));

    -- F. Doubtful identity (Boardwise -> a snowboarding shop) -> not synced at all
    plan := sf_sync_plan('ctF', jsonb_build_array(jsonb_build_object('Id', bid)));
    select decision into d from sf_sync_log where run_label='ctF' limit 1;
    t := array_append(t, 'F: wrong-company match is held back'); e := array_append(e, 'held_for_review'); gt := array_append(gt, coalesce(d,'(none)'));

    raise exception 'rollback_ct';
  exception when others then
    if sqlerrm <> 'rollback_ct' then t := array_append(t,'ERROR'); e := array_append(e,''); gt := array_append(gt, sqlerrm); end if;
  end;
  return query select t[k], e[k], gt[k], e[k] = gt[k] from generate_subscripts(t,1) k;
end $$;

-- ============================================================
-- 20261009192350  p2_identity_reviews
-- ============================================================
-- A person's verdict on a doubtful match. approve = same company; reject = the data (and our domain) point to a different company.
create table if not exists identity_reviews (
  company_key text primary key references icp_companies(company_key),
  decision text not null check (decision in ('approve','reject')),
  reviewed_domain text not null,          -- the domain the decision was about; a new domain re-opens the case
  note text, decided_by text not null default 'human', decided_at timestamptz not null default now());
alter table identity_reviews enable row level security;

insert into identity_reviews(company_key, decision, reviewed_domain, note, decided_by) values
 ('boardwise','reject','boardwise.co.uk','Apollo/domain = Boardwise Snowboarding (UK snowboard shop), not the recruiting firm. Needs the correct domain.','Omiwade'),
 ('pavago','reject','pavago.de','Apollo/domain = Pavago - Ihr Energieprofi (German energy firm), not the staffing company. Needs the correct domain.','Omiwade'),
 ('prove-partners','approve','provepartners.com','"PROVE" is the same company (provepartners.com); short brand name only.','Omiwade')
on conflict (company_key) do update set decision=excluded.decision, reviewed_domain=excluded.reviewed_domain, note=excluded.note,
  decided_by=excluded.decided_by, decided_at=now();

-- Rejected companies are not re-enriched until someone gives them a different domain
create or replace view accounts_to_enrich with (security_invoker = true) as
  select c.company_key, c.company_name, c.domain
  from icp_companies c
  left join account_enrichment g using (company_key)
  left join identity_reviews r on r.company_key = c.company_key and r.decision = 'reject' and r.reviewed_domain = c.domain
  where c.domain is not null and c.domain_confidence = 'high' and r.company_key is null
    and ( g.company_key is null
          or (g.status <> 'enriched' and g.enriched_at < now() - interval '7 days')
          or g.enriched_at < now() - interval '90 days')
  order by c.icp_score desc nulls last, c.company_key;

-- Wrap finalize_account: apply the human verdict on top of the machine's result
alter function finalize_account(text, text) rename to finalize_account_machine;

create or replace function finalize_account(p_run_label text, p_company_key text) returns jsonb
language plpgsql set search_path = public as $$
declare r identity_reviews; c icp_companies; out jsonb; g account_enrichment;
begin
  select * into c from icp_companies where company_key = p_company_key;
  select * into r from identity_reviews where company_key = p_company_key and reviewed_domain = c.domain;

  if r.decision = 'reject' then
    -- the evidence is about a different company: keep none of it
    insert into account_enrichment as a (company_key, company_name, domain, identity_check, identity_note, confidence, status,
       unenriched_reason, last_run_label, enriched_at)
    values (c.company_key, c.company_name, c.domain, 'rejected', r.note, 0, 'unenriched',
       'human rejected the match: domain ' || c.domain || ' belongs to a different company; needs the correct domain', p_run_label, now())
    on conflict (company_key) do update set employee_count=null, employee_band=null, industry_raw=null, industry_sf=null,
       linkedin_url=null, phone=null, contact_email=null, email_risk=null, field_sources='{}', field_updated_at='{}',
       identity_check='rejected', identity_note=excluded.identity_note, confidence=0, status='unenriched',
       unenriched_reason=excluded.unenriched_reason, last_run_label=excluded.last_run_label, enriched_at=excluded.enriched_at;
    return jsonb_build_object('company_key', p_company_key, 'status', 'unenriched', 'identity', 'rejected');
  end if;

  out := finalize_account_machine(p_run_label, p_company_key);

  if r.decision = 'approve' then
    select * into g from account_enrichment where company_key = p_company_key;
    update account_enrichment set identity_check = 'confirmed', identity_note = 'approved by ' || r.decided_by || ': ' || r.note,
      confidence = least(100, coalesce(g.confidence,0) + case when g.identity_check = 'needs_review' then 25 else 0 end
                   + case when g.identity_check = 'needs_review' and g.confidence = 50 then 25 else 0 end)
    where company_key = p_company_key;
    out := out || jsonb_build_object('identity', 'confirmed (human approved)');
  end if;
  return out;
end $$;

-- ============================================================
-- 20261009192407  p2_identity_reviews_conf
-- ============================================================
create or replace function finalize_account(p_run_label text, p_company_key text) returns jsonb
language plpgsql set search_path = public as $$
declare r identity_reviews; c icp_companies; out jsonb; g account_enrichment; li_slug text; name_c text; web_ok boolean; conf int;
begin
  select * into c from icp_companies where company_key = p_company_key;
  select * into r from identity_reviews where company_key = p_company_key and reviewed_domain = c.domain;

  if r.decision = 'reject' then
    insert into account_enrichment as a (company_key, company_name, domain, identity_check, identity_note, confidence, status,
       unenriched_reason, last_run_label, enriched_at)
    values (c.company_key, c.company_name, c.domain, 'rejected', r.note, 0, 'unenriched',
       'human rejected the match: domain ' || c.domain || ' belongs to a different company; needs the correct domain', p_run_label, now())
    on conflict (company_key) do update set employee_count=null, employee_band=null, industry_raw=null, industry_sf=null,
       linkedin_url=null, phone=null, contact_email=null, email_risk=null, field_sources='{}', field_updated_at='{}',
       identity_check='rejected', identity_note=excluded.identity_note, confidence=0, status='unenriched',
       unenriched_reason=excluded.unenriched_reason, last_run_label=excluded.last_run_label, enriched_at=excluded.enriched_at;
    return jsonb_build_object('company_key', p_company_key, 'status', 'unenriched', 'identity', 'rejected');
  end if;

  out := finalize_account_machine(p_run_label, p_company_key);

  if r.decision = 'approve' then
    select * into g from account_enrichment where company_key = p_company_key;
    -- same scoring as the machine, but with identity counted as confirmed (+30) and no review cap
    name_c := replace(coalesce(normalize_company_name(c.company_name),''), ' ', '');
    li_slug := regexp_replace(lower(coalesce(substring(g.linkedin_url from '(?i)linkedin\.com/company/([^/?#]+)'),'')), '[^a-z0-9]', '', 'g');
    select bool_or(error is null) into web_ok from enrichment_results
      where company_key = p_company_key and provider = 'website' and run_label <> 'scaffold_test';
    conf := (case when c.domain_confidence = 'high' then 20 else 0 end) + 30
          + (case when li_slug <> '' and name_c <> '' and (li_slug like '%' || name_c || '%' or name_c like '%' || li_slug || '%') then 20 else 0 end)
          + (case when coalesce(web_ok,false) then 10 else 0 end)
          + (case when g.status = 'enriched' then 20 else 0 end);
    update account_enrichment set identity_check = 'confirmed', identity_note = 'approved by ' || r.decided_by || ': ' || r.note,
      confidence = least(conf, 100) where company_key = p_company_key;
    out := out || jsonb_build_object('identity', 'confirmed (human approved)', 'confidence', least(conf,100));
  end if;
  return out;
end $$;