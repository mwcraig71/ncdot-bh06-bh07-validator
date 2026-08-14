-- ============================================================================
-- A milepoint cannot be judged without the route it is measured on.
--
-- The queue handed an approver one row per proposed field, each with the
-- published value of THAT field beside it. Which is exactly enough to see what
-- is changing and not nearly enough to see whether it is right: an inspector
-- who corrects only BH07 submits one row, and the route ID the new milepoint
-- has to fall inside is not in the queue at all. The approvals screen was
-- left saying "no BH06 on this feature, so the milepoint cannot be tested" on
-- the single most common submission there is.
--
-- So the queue now carries the feature's STANDING pair - its effective BH06
-- and BH07, reviewed value where one exists and NCDOT's published value
-- otherwise - beside whatever is being proposed. A BH07 proposal is then
-- testable against the route the feature actually has, which is the whole
-- question: 30.100 is not wrong in the abstract, it is wrong on I-85 in
-- Mecklenburg, which runs 0.000 to 21.155.
--
-- Proposals are deliberately not part of that pair. PROPOSED ranks below
-- PUBLISHED in the source precedence, so feature_resolved answers with what is
-- in force today - which is the thing a proposal has to be compared against.
-- ============================================================================

drop view proposal_queue;
create view proposal_queue
with (security_invoker = true) as
select fv.feature_id, fv.field, 'value'::text as kind,
       coalesce(fv.value_text, fv.value_num::text) as proposed_value,
       fv.reviewer_name as proposed_by, fv.recorded_at as proposed_at, fv.note,
       f.structure_number, f.designation, f.location_type, f.feature_name,
       s.county_name, s.division,
       coalesce(pub.value_text, pub.value_num::text) as published_value,
       fr.bh06 as current_bh06, fr.bh07 as current_bh07
from feature_values fv
join features f on f.id = fv.feature_id
join structures s on s.structure_number = f.structure_number
left join feature_resolved fr on fr.feature_id = fv.feature_id
left join feature_values pub
  on pub.feature_id = fv.feature_id and pub.field = fv.field and pub.source = 'PUBLISHED'
where fv.source = 'PROPOSED' and fv.withdrawn_at is null
union all
select f.id, null::snbi_field, 'removal'::text,
       'remove ' || f.designation, null::text, f.removal_requested_at, f.removal_reason,
       f.structure_number, f.designation, f.location_type, f.feature_name,
       s.county_name, s.division, null::text,
       fr.bh06, fr.bh07
from features f
join structures s on s.structure_number = f.structure_number
left join feature_resolved fr on fr.feature_id = f.id
where f.removal_requested_at is not null and f.withdrawn_at is null;

comment on view proposal_queue is
  'Everything waiting on an approver: proposed values, and requests to remove a feature altogether. Each row carries the published value of the field being changed AND the feature''s standing BH06/BH07 pair, so a proposed milepoint can be tested against the route it is measured on without a second query.';

grant select on proposal_queue to anon, authenticated;
