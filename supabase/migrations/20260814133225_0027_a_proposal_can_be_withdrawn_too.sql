-- ============================================================================
-- Withdrawal was a review concept, so the constraint said only a REVIEWED row
-- may carry withdrawn_at. A decided proposal is the same idea arriving from the
-- other end: approving one has to close it, rejecting one has to close it, and
-- neither may delete it, because "why is this not in the submittal" needs an
-- answer with a name and a date on it.
--
-- PUBLISHED and DERIVED still cannot be withdrawn. PUBLISHED is NCDOT's to
-- change and a derivation is replaced by re-deriving, so withdrawal would mean
-- nothing for either.
-- ============================================================================
alter table feature_values drop constraint feature_values_only_reviews_withdraw;
alter table feature_values add constraint feature_values_only_reviews_withdraw
  check (withdrawn_at is null or source in ('REVIEWED','PROPOSED'));

comment on constraint feature_values_only_reviews_withdraw on feature_values is
  'Only a reviewer''s correction or an inspector''s proposal can be withdrawn. A withdrawn row stays, with its author and its history, and resolution falls back to the next source down on its own.';
