-- ============================================================================
-- Who may start an ingest.
--
-- The Edge Functions sit behind verify_jwt, but the anon key is printed in the
-- published page, so JWT verification alone would let any visitor kick off a
-- statewide pull. These are quarterly jobs that walk 1.2M road segments; they
-- should not be startable by anyone who can view source.
--
-- So there is a second factor: a token the database owns. The functions compare
-- it against the x-ingest-token header. pg_cron reads it to schedule, and a
-- person can read it to run a load by hand. It is not a user credential and is
-- not tied to anyone's account — it only answers "is this request allowed to
-- start a job".
-- ============================================================================

create table ingest_secret (
  id       int primary key default 1 check (id = 1),
  token    text not null,
  rotated_at timestamptz not null default now()
);

alter table ingest_secret enable row level security;
-- No policy at all: RLS denies by default, so no client role can read it even
-- though the table sits in the API schema. Only the service role, which
-- bypasses RLS, and the functions using it.
revoke all on ingest_secret from anon, authenticated;

insert into ingest_secret (id, token)
values (1, encode(extensions.gen_random_bytes(24), 'hex'));

comment on table ingest_secret is
  'Shared secret for starting an ingest. Deliberately unreadable by any client role: RLS is on and there is no policy. Rotate by updating the row.';
