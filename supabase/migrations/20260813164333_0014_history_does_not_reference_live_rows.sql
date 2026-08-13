-- ============================================================================
-- review_history.feature_id was a foreign key to features, ON DELETE SET NULL.
-- Two things wrong with that, both found by deleting a test structure.
--
-- 1. It breaks. Removing a structure cascades to features and then to
--    feature_values; the DELETE on feature_values fires the audit trigger,
--    which tries to write a history row referencing a feature the same
--    statement has already removed. The delete fails outright — so an ingest
--    could never retire a structure that had disappeared upstream.
--
-- 2. More importantly it was destroying the record. ON DELETE SET NULL means
--    that removing a feature quietly erased, from every historical row, WHICH
--    feature the history was about. An append-only log whose contents can be
--    altered by an unrelated delete is not append-only in any useful sense.
--
-- A log must outlive the thing it describes. The column stays and keeps the
-- id; it simply stops pretending to point at a row that still exists.
--
-- (review_history.actor was never a foreign key, for the same reason: deleting
-- an account must not rewrite what that account did.)
-- ============================================================================

alter table review_history drop constraint review_history_feature_id_fkey;

comment on column review_history.feature_id is
  'The feature this change was about. Deliberately NOT a foreign key: history outlives the rows it describes, and a cascade must never rewrite it. May reference a feature that no longer exists, which is the point.';

comment on column review_history.actor is
  'The account that made the change. Not a foreign key, for the same reason as feature_id: deleting a user must not rewrite what they did.';
