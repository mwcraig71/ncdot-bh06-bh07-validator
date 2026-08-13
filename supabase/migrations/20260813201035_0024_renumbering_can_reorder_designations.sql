-- ============================================================================
-- Renumbering has to be able to swap two designations.
--
-- Moving a carried feature from H04 to H02 means H02 is briefly occupied twice,
-- and a unique constraint checked row by row refuses the statement halfway
-- through - so renumber_features() could apply the crosswalk order only when
-- the order happened not to need a swap, which is exactly when it was not
-- needed. Found by giving it 590819's own numbering, where the second carried
-- roadway is numbered after three roadways beneath it.
--
-- The constraint is right and stays; it just has to hold at the end of the
-- statement rather than in the middle of it.
-- ============================================================================

alter table features drop constraint features_structure_number_designation_key;
alter table features add constraint features_structure_number_designation_key
  unique (structure_number, designation) deferrable initially immediate;

comment on constraint features_structure_number_designation_key on features is
  'Deferrable so a renumbering can pass through a state where two features share a designation. Initially immediate, so every other write is checked as strictly as before.';

create or replace function renumber_features(p_structure text)
returns table (feature_id uuid, old_designation text, new_designation text)
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  set constraints features_structure_number_designation_key deferred;
  return query
  with ordered as (
    select f.id,
           f.designation as was,
           row_number() over (
             order by case when f.location_type = 'C' then 0 else 1 end,
                      case when f.is_primary then 0 else 1 end,
                      f.created_at,
                      f.id
           )::int as seq
    from features f
    where f.structure_number = p_structure
      and f.withdrawn_at is null
  ),
  moved as (
    update features f
       set feature_seq = o.seq,
           designation = snbi_designation(o.seq)
      from ordered o
     where f.id = o.id
       and (f.feature_seq is distinct from o.seq or f.designation is distinct from snbi_designation(o.seq))
    returning f.id, o.was, f.designation
  )
  select * from moved;
end $$;

comment on function renumber_features(text) is
  'Applies the crosswalk numbering to one structure: carried features first, then the primary below feature, then the remaining below features. Returns only the rows that actually moved, so a caller can report a renumbering rather than guess at one. Defers the designation uniqueness constraint for the duration, because reordering necessarily passes through a collision.';
